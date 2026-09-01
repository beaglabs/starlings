"""Optional LLM semantic annotation for imported execution trajectories.

The annotator is deliberately downstream of deterministic import. It may improve
retrieval queries and attach non-authoritative semantic labels, but it never
changes source commands, observations, ActionFrames, event identities, or
resolved status. No chain-of-thought is requested or stored.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import time
from typing import Any
import urllib.error
import urllib.request

from murmurations.training.import_swe_smith import import_operator_registry


_ALLOWED_INTENTS = {
    "localization",
    "inspection",
    "hypothesis",
    "repair",
    "verification",
    "documentation",
    "metadata",
    "other",
}
_ALLOWED_ARGUMENT_KINDS = {
    "NONE",
    "TEXT",
    "VARIABLE",
    "INVARIANT",
    "CLAIM",
    "EVIDENCE",
    "AGENT",
    "CAPABILITY",
    "ARTIFACT",
    "ACTION",
    "SYMBOL",
    "SCALAR",
    "OPERATOR",
}


def _request_json(
    *,
    base_url: str,
    model: str,
    api_key: str | None,
    prompt: str,
    timeout_seconds: int,
    request_retries: int,
) -> dict[str, Any]:
    if request_retries <= 0:
        raise ValueError("request_retries must be positive")
    url = base_url.rstrip("/") + "/chat/completions"
    payload = {
        "model": model,
        "temperature": 0.0,
        "max_tokens": 2400,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You label already-recorded software-agent execution traces. "
                    "Return JSON only. Do not invent commands, outputs, evidence, "
                    "success, failures, or hidden reasoning. Produce only concise "
                    "semantic labels for the supplied event IDs."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "response_format": {"type": "json_object"},
    }
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    last_error: Exception | None = None
    body: Any = None
    for attempt in range(request_retries):
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                body = json.loads(response.read().decode("utf-8"))
            break
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            last_error = exc
            if attempt + 1 < request_retries:
                time.sleep(min(4.0, 0.5 * (2**attempt)))
    else:
        assert last_error is not None
        raise RuntimeError(f"semantic annotation request failed: {last_error}") from last_error

    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"semantic annotation response is malformed: {body!r}") from exc
    if isinstance(content, list):
        content = "".join(
            str(item.get("text") or "")
            for item in content
            if isinstance(item, dict)
        )
    text = str(content).strip()
    if text.startswith("```"):
        first_newline = text.find("\n")
        text = text[first_newline + 1 :] if first_newline >= 0 else text
        if text.rstrip().endswith("```"):
            text = text.rstrip()[:-3].rstrip()
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(
            f"semantic annotator returned non-JSON content: {text[:1000]}"
        ) from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("semantic annotator must return a JSON object")
    return parsed


def _event_summary(event: dict[str, Any]) -> dict[str, Any]:
    frame = event.get("frame") or {}
    environment = event.get("environment") or {}
    return {
        "id": event.get("id"),
        "operation": frame.get("operation"),
        "argument_kind": frame.get("argument_kind"),
        "argument": str(frame.get("argument") or "")[-500:],
        "operator_ref": frame.get("operator_ref"),
        "retrieval_query": str(event.get("retrieval_query") or "")[-240:],
        "grounding": str(event.get("grounding") or "")[-500:],
        "tool_name": environment.get("tool_name"),
        "command": str(environment.get("command") or "")[-500:],
        "output": str(environment.get("output") or "")[-700:],
    }


def _annotation_prompt(
    episode: dict[str, Any],
    events: list[dict[str, Any]],
) -> str:
    return f"""Task:
{str(episode.get("task") or "")[-3000:]}

Events:
{json.dumps([_event_summary(event) for event in events], ensure_ascii=False)}

For each supplied event ID, optionally return:
- retrieval_query: a concise semantic retrieval intent, <= 180 chars.
- intent: one of localization, inspection, hypothesis, repair, verification,
  documentation, metadata, other.
- supporting_evidence: zero or more PRIOR event IDs whose operation is EVIDENCE.
- argument_kind_suggestion: an optional Murmurations argument-kind label.

Do not change or reinterpret the recorded command/output. Do not infer success
beyond the supplied trace. Do not provide explanations or reasoning.

Return exactly:
{{"events":[{{"id":"...","retrieval_query":"...","intent":"...",
"supporting_evidence":[],"argument_kind_suggestion":"ACTION"}}]}}
"""


def apply_annotation_payload(
    episode: dict[str, Any],
    payload: dict[str, Any],
    *,
    model: str,
) -> dict[str, int]:
    """Apply safe semantic annotations without changing identity-bearing frames."""

    raw_annotations = payload.get("events")
    if not isinstance(raw_annotations, list):
        return {"received": 0, "applied": 0, "query_updates": 0}

    events = episode.get("events") or []
    by_id = {
        str(event.get("id")): (index, event)
        for index, event in enumerate(events)
        if event.get("id")
    }
    registry = import_operator_registry()
    applied = 0
    query_updates = 0

    for raw in raw_annotations:
        if not isinstance(raw, dict):
            continue
        event_id = str(raw.get("id") or "")
        target = by_id.get(event_id)
        if target is None:
            continue
        index, event = target
        frame = event.get("frame") or {}

        intent = str(raw.get("intent") or "other").strip().lower()
        if intent not in _ALLOWED_INTENTS:
            intent = "other"

        evidence_ids: list[str] = []
        raw_evidence = raw.get("supporting_evidence")
        if isinstance(raw_evidence, list):
            for value in raw_evidence:
                candidate_id = str(value)
                candidate = by_id.get(candidate_id)
                if candidate is None:
                    continue
                candidate_index, candidate_event = candidate
                candidate_frame = candidate_event.get("frame") or {}
                if (
                    candidate_index < index
                    and candidate_frame.get("operation") == "EVIDENCE"
                    and candidate_id not in evidence_ids
                ):
                    evidence_ids.append(candidate_id)

        argument_kind = str(raw.get("argument_kind_suggestion") or "").upper()
        if argument_kind not in _ALLOWED_ARGUMENT_KINDS:
            argument_kind = ""

        annotation = {
            "source": "llm-semantic-annotation-v1",
            "model": model,
            "intent": intent,
            "supporting_evidence": evidence_ids,
        }
        if argument_kind:
            annotation["argument_kind_suggestion"] = argument_kind
        event["semantic_annotation"] = annotation
        applied += 1

        query = " ".join(str(raw.get("retrieval_query") or "").split())
        if not query or len(query) > 180:
            continue
        operator_ref = frame.get("operator_ref")
        hits = registry.retrieve(query, top_k=7, available=("repo",))
        candidates = [hit.descriptor.name for hit in hits]
        if operator_ref is not None and operator_ref not in candidates:
            # Never replace a query with one that destroys its existing
            # operator-pointer supervision.
            continue
        event["retrieval_query"] = query
        event["candidates"] = candidates
        query_updates += 1

    return {
        "received": len(raw_annotations),
        "applied": applied,
        "query_updates": query_updates,
    }


def annotate_episode(
    episode: dict[str, Any],
    *,
    base_url: str,
    model: str,
    api_key: str | None,
    timeout_seconds: int,
    request_retries: int,
    batch_events: int = 32,
) -> dict[str, int]:
    if batch_events <= 0:
        raise ValueError("batch_events must be positive")
    totals = {"received": 0, "applied": 0, "query_updates": 0, "requests": 0}
    events = list(episode.get("events") or [])
    for offset in range(0, len(events), batch_events):
        batch = events[offset : offset + batch_events]
        payload = _request_json(
            base_url=base_url,
            model=model,
            api_key=api_key,
            prompt=_annotation_prompt(episode, batch),
            timeout_seconds=timeout_seconds,
            request_retries=request_retries,
        )
        report = apply_annotation_payload(episode, payload, model=model)
        totals["requests"] += 1
        for key in ("received", "applied", "query_updates"):
            totals[key] += report[key]
    return totals


def annotate_file(
    path: str | Path,
    *,
    base_url: str,
    model: str,
    api_key: str | None = None,
    timeout_seconds: int = 120,
    request_retries: int = 3,
    concurrency: int = 8,
    batch_events: int = 32,
) -> dict[str, Any]:
    source = Path(path)
    episodes = [
        json.loads(line)
        for line in source.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if not episodes:
        raise RuntimeError("semantic annotation input is empty")

    reports: list[dict[str, int] | None] = [None] * len(episodes)

    def work(index: int) -> tuple[int, dict[str, int]]:
        return (
            index,
            annotate_episode(
                episodes[index],
                base_url=base_url,
                model=model,
                api_key=api_key,
                timeout_seconds=timeout_seconds,
                request_retries=request_retries,
                batch_events=batch_events,
            ),
        )

    with ThreadPoolExecutor(max_workers=max(1, concurrency)) as executor:
        futures = [executor.submit(work, index) for index in range(len(episodes))]
        for future in as_completed(futures):
            index, report = future.result()
            reports[index] = report

    tmp = source.with_name(source.name + ".annotated.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        for episode in episodes:
            handle.write(json.dumps(episode, sort_keys=True) + "\n")
    tmp.replace(source)

    summary = {
        "enabled": True,
        "model": model,
        "base_url": base_url,
        "episodes": len(episodes),
        "requests": 0,
        "annotations_applied": 0,
        "retrieval_queries_updated": 0,
    }
    for report in reports:
        if report is None:
            continue
        summary["requests"] += report["requests"]
        summary["annotations_applied"] += report["applied"]
        summary["retrieval_queries_updated"] += report["query_updates"]
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--episodes", required=True)
    parser.add_argument(
        "--base-url",
        default=os.environ.get(
            "MURMURATIONS_ANNOTATOR_BASE_URL", "http://127.0.0.1:8000/v1"
        ),
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("MURMURATIONS_ANNOTATOR_MODEL"),
        required=os.environ.get("MURMURATIONS_ANNOTATOR_MODEL") is None,
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("MURMURATIONS_ANNOTATOR_API_KEY"),
    )
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--batch-events", type=int, default=32)
    parser.add_argument("--timeout-seconds", type=int, default=120)
    parser.add_argument("--request-retries", type=int, default=3)
    args = parser.parse_args()

    report = annotate_file(
        args.episodes,
        base_url=args.base_url,
        model=args.model,
        api_key=args.api_key,
        timeout_seconds=args.timeout_seconds,
        request_retries=args.request_retries,
        concurrency=args.concurrency,
        batch_events=args.batch_events,
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
