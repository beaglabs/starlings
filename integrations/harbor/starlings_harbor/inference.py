"""Shared frozen-model decision function for conditions A and B."""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
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


def history_text(history: list[dict[str, Any]]) -> str:
    """Return the same bounded observation history for conditions A and B."""
    selected: list[dict[str, Any]] = []
    for item in reversed(history[-8:]):
        normalized = dict(item)
        output = normalized.get("output")
        if isinstance(output, str) and len(output) > 6000:
            normalized["output"] = output[-6000:]
            normalized["output_prefix_truncated"] = True
        candidate = list(reversed([normalized, *selected]))
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


def _extract_content(payload: dict[str, Any]) -> str:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise RuntimeError("hosted inference response has no choices")
    message = choices[0].get("message", {})
    content = message.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and part.get("type") in {"text", "output_text"}
        )
    raise RuntimeError("hosted inference response content is not textual")


def _parse_decision(text: str) -> Decision:
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
        command = obj.get("command")
        if not isinstance(command, str) or not command.strip():
            raise RuntimeError("shell decision is missing a command")
        return Decision("shell", command)
    if kind == "final":
        answer = obj.get("answer")
        if not isinstance(answer, str):
            raise RuntimeError("final decision is missing an answer")
        return Decision("final", answer)
    raise RuntimeError(f"unknown model decision type: {kind!r}")


def decide(task: str, history: str, model: str) -> Decision:
    url = os.environ.get("HOSTED_INFERENCE_URL")
    token = os.environ.get("HOSTED_INFERENCE_TOKEN")
    if not url or not token:
        raise RuntimeError(
            "HOSTED_INFERENCE_URL and HOSTED_INFERENCE_TOKEN are required "
            "for conditions A and B"
        )

    body = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": "TASK:\n" + task + "\n\nHISTORY(JSON):\n" + history,
                },
            ],
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
            return _parse_decision(_extract_content(payload))
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code not in {404, 405}:
                detail = exc.read().decode("utf-8", errors="replace")
                raise RuntimeError(
                    f"hosted inference failed with HTTP {exc.code}: {detail[:1000]}"
                ) from exc

    raise RuntimeError(f"hosted inference endpoint was not found: {last_error}")
