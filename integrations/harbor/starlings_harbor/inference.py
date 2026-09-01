"""Shared model decision function for conditions A and B.

Hosted Harbor uses its inference proxy. Normal Harbor runs use LiteLLM with the
provider credentials already present in the Harbor process (for example
OPENAI_API_KEY or OPENROUTER_API_KEY).
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SYSTEM_PROMPT = """You are a terminal agent solving a benchmark task.
You may either run one shell command or finish with a final answer.
Use the terminal iteratively: inspect the environment, make the smallest useful
change, run verification, and recover from failures. Do not invent tool output.

Return exactly one JSON object and no surrounding prose:
{"type":"shell","command":"<one shell command>"}
or
{"type":"final","answer":"<final answer>"}.
"""


@dataclass(frozen=True)
class Decision:
    kind: str
    value: str
    input_tokens: int = 0
    output_tokens: int = 0
    cache_tokens: int = 0
    cost_usd: float = 0.0


def history_text(history: list[dict[str, Any]]) -> str:
    """Return the same bounded observation history for conditions A and B."""
    selected: list[dict[str, Any]] = []
    for item in reversed(history[-8:]):
        normalized = dict(item)
        output = normalized.get("output")
        if isinstance(output, str) and len(output) > 6000:
            normalized["output"] = output[-6000:]
            normalized["output_prefix_truncated"] = True
        candidate = [normalized, *selected]
        encoded = json.dumps(candidate, ensure_ascii=False, separators=(",", ":"))
        if len(encoded) > 24000 and selected:
            break
        selected.insert(0, normalized)
    return json.dumps(selected, ensure_ascii=False, separators=(",", ":"))


def _endpoint_candidates(base: str) -> list[str]:
    base = base.rstrip("/")
    if base.endswith("/chat/completions"):
        return [base]
    if base.endswith("/v1"):
        return [base + "/chat/completions"]
    return [base + "/chat/completions", base + "/v1/chat/completions"]


def _read(item: Any, key: str, default: Any = None) -> Any:
    if item is None:
        return default
    if isinstance(item, dict):
        return item.get(key, default)
    return getattr(item, key, default)


def _extract_content(payload: Any) -> str:
    choices = _read(payload, "choices")
    if not isinstance(choices, list) or not choices:
        raise RuntimeError("model response has no choices")
    message = _read(choices[0], "message", {})
    content = _read(message, "content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            str(_read(part, "text", ""))
            for part in content
            if _read(part, "type") in {"text", "output_text"}
        )
    raise RuntimeError("model response content is not textual")


def _coerce_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _usage(payload: Any) -> tuple[int, int, int, float]:
    usage = _read(payload, "usage")
    input_tokens = _coerce_int(
        _read(usage, "prompt_tokens", _read(usage, "input_tokens", 0))
    )
    output_tokens = _coerce_int(
        _read(usage, "completion_tokens", _read(usage, "output_tokens", 0))
    )
    details = _read(usage, "prompt_tokens_details")
    cache_tokens = _coerce_int(
        _read(details, "cached_tokens", _read(usage, "cache_read_input_tokens", 0))
    )

    cost = 0.0
    try:
        hidden = _read(payload, "_hidden_params", {})
        cost = float(_read(hidden, "response_cost", 0.0) or 0.0)
    except (TypeError, ValueError):
        cost = 0.0
    return input_tokens, output_tokens, cache_tokens, cost


def _record_usage(
    usage_log: str | os.PathLike[str] | None,
    *,
    input_tokens: int,
    output_tokens: int,
    cache_tokens: int,
    cost_usd: float,
) -> None:
    target = usage_log or os.environ.get("STARLINGS_HARBOR_USAGE_LOG")
    if not target:
        return
    path = Path(target)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(
            json.dumps(
                {
                    "input_tokens": input_tokens,
                    "output_tokens": output_tokens,
                    "cache_tokens": cache_tokens,
                    "cost_usd": cost_usd,
                },
                sort_keys=True,
            )
            + "\n"
        )


def _parse_decision(
    text: str,
    *,
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_tokens: int = 0,
    cost_usd: float = 0.0,
) -> Decision:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped)
        stripped = re.sub(r"\s*```$", "", stripped)

    try:
        obj = json.loads(stripped)
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start < 0 or end <= start:
            raise RuntimeError(f"model did not return a JSON decision: {text[:400]!r}")
        obj = json.loads(stripped[start : end + 1])

    kind = obj.get("type")
    if kind == "shell":
        value = obj.get("command")
        if not isinstance(value, str) or not value.strip():
            raise RuntimeError("shell decision is missing a command")
    elif kind == "final":
        value = obj.get("answer")
        if not isinstance(value, str):
            raise RuntimeError("final decision is missing an answer")
    else:
        raise RuntimeError(f"unknown model decision type: {kind!r}")

    return Decision(
        kind=kind,
        value=value,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_tokens=cache_tokens,
        cost_usd=cost_usd,
    )


def _messages(task: str, history: str) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": "TASK:\n" + task + "\n\nHISTORY(JSON):\n" + history,
        },
    ]


def _decide_hosted(task: str, history: str, model: str) -> Decision:
    url = os.environ.get("HOSTED_INFERENCE_URL")
    token = os.environ.get("HOSTED_INFERENCE_TOKEN")
    if not url or not token:
        raise RuntimeError("Hosted Harbor inference proxy is not configured")

    body = json.dumps(
        {
            "model": model,
            "messages": _messages(task, history),
            "temperature": 0,
            "max_tokens": 768,
            "stream": False,
        }
    ).encode("utf-8")

    last_error: Exception | None = None
    for endpoint in _endpoint_candidates(url):
        request = urllib.request.Request(
            endpoint,
            data=body,
            headers={
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                payload = json.loads(response.read().decode("utf-8"))
            input_tokens, output_tokens, cache_tokens, cost_usd = _usage(payload)
            return _parse_decision(
                _extract_content(payload),
                input_tokens=input_tokens,
                output_tokens=output_tokens,
                cache_tokens=cache_tokens,
                cost_usd=cost_usd,
            )
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code not in {404, 405}:
                detail = exc.read().decode("utf-8", errors="replace")
                raise RuntimeError(
                    f"hosted inference failed with HTTP {exc.code}: {detail[:1000]}"
                ) from exc

    raise RuntimeError(f"hosted inference endpoint was not found: {last_error}")


def _decide_litellm(task: str, history: str, model: str) -> Decision:
    try:
        import litellm
    except ImportError as exc:
        raise RuntimeError(
            "normal Harbor mode requires LiteLLM; install Harbor itself before "
            "running the Starlings external agents"
        ) from exc

    litellm.drop_params = True
    response = litellm.completion(
        model=model,
        messages=_messages(task, history),
        temperature=0,
        max_tokens=768,
        num_retries=3,
    )
    input_tokens, output_tokens, cache_tokens, cost_usd = _usage(response)
    if cost_usd == 0.0:
        try:
            cost_usd = float(litellm.completion_cost(completion_response=response))
        except Exception:
            pass
    return _parse_decision(
        _extract_content(response),
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cache_tokens=cache_tokens,
        cost_usd=cost_usd,
    )


def decide(
    task: str,
    history: str,
    model: str,
    usage_log: str | os.PathLike[str] | None = None,
) -> Decision:
    """Make one matched A/B decision using Hosted Harbor or normal Harbor."""
    if os.environ.get("HOSTED_INFERENCE_URL") and os.environ.get(
        "HOSTED_INFERENCE_TOKEN"
    ):
        decision = _decide_hosted(task, history, model)
    else:
        decision = _decide_litellm(task, history, model)

    _record_usage(
        usage_log,
        input_tokens=decision.input_tokens,
        output_tokens=decision.output_tokens,
        cache_tokens=decision.cache_tokens,
        cost_usd=decision.cost_usd,
    )
    return decision
