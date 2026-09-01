"""Materialize Merkle-DAG episodes into bounded model training/evaluation windows."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from murmurations.utils.canonical import canonical_id


def split_for_repo(repository_identity: str, eval_fraction: float) -> str:
    if not 0.0 <= eval_fraction < 1.0:
        raise ValueError("eval_fraction must be in [0, 1)")
    digest = canonical_id({"split": "murmurations-v1", "repo": repository_identity})
    bucket = int(digest[3:11], 16) / float(0xFFFFFFFF)
    return "eval" if bucket < eval_fraction else "train"


def _clip_middle(value: str, limit: int) -> str:
    if limit <= 0:
        return ""
    if len(value) <= limit:
        return value
    marker = "...[truncated]..."
    if limit <= len(marker):
        return value[:limit]
    remaining = limit - len(marker)
    head = remaining // 2
    tail = remaining - head
    return value[:head] + marker + value[-tail:]


def _clip_utf8_tail(value: str, max_bytes: int) -> str:
    """Return an exact suffix that fits a UTF-8 byte budget."""

    if max_bytes <= 0:
        return ""
    encoded = value.encode("utf-8")
    if len(encoded) <= max_bytes:
        return value

    low = 0
    high = len(value)
    best = len(value)
    while low <= high:
        mid = (low + high) // 2
        suffix = value[mid:]
        if len(suffix.encode("utf-8")) <= max_bytes:
            best = mid
            high = mid - 1
        else:
            low = mid + 1
    return value[best:]


def _summary(event: dict[str, Any], *, max_chars: int | None = None) -> str:
    """Render a bounded event summary while keeping its pointer identity visible."""

    frame = event["frame"]
    argument = _clip_middle(str(frame.get("argument") or ""), 800)
    identity = (
        f"{event['id']} {frame['operation']} "
        f"operator={frame.get('operator_ref')} argument={argument}"
    )
    lines = [identity]
    env = event.get("environment") or {}

    argv = env.get("argv")
    if isinstance(argv, list) and argv:
        rendered_argv = json.dumps(
            [str(item) for item in argv],
            separators=(",", ":"),
        )
        lines.append(
            f"ARGV[{event['id']}]: {_clip_middle(rendered_argv, 1200)}"
        )

    tool_name = env.get("tool_name")
    tool_arguments = env.get("tool_arguments")
    if isinstance(tool_name, str) and tool_name:
        rendered_arguments = json.dumps(
            tool_arguments or {},
            sort_keys=True,
            separators=(",", ":"),
        )
        lines.append(
            f"TOOL[{event['id']}]: {tool_name} "
            + _clip_middle(rendered_arguments, 1600)
        )

    semantic_action = env.get("semantic_action")
    if isinstance(semantic_action, str) and semantic_action:
        lines.append(f"SEMANTIC_ACTION[{event['id']}]: {semantic_action}")

    command = env.get("command")
    if isinstance(command, str) and command:
        lines.append(
            f"COMMAND[{event['id']}]: {_clip_middle(command, 1200)}"
        )

    output = env.get("output")
    if isinstance(output, str) and output:
        lines.append(
            f"RESULT[{event['id']}]: {_clip_middle(output, 1600)}"
        )

    summary = "\n".join(lines)
    if max_chars is None or len(summary) <= max_chars:
        return summary

    # A direct parent only needs to remain unambiguously addressable for the
    # structured parent-pointer target. Never truncate the event id itself.
    minimum_identity = (
        f"{event['id']} {frame['operation']} operator={frame.get('operator_ref')}"
    )
    if max_chars < len(minimum_identity):
        raise ValueError(
            "max_context_chars cannot preserve direct-parent event identifier"
        )

    remaining = max_chars - len(minimum_identity)
    if remaining <= 1:
        return minimum_identity

    payload = "\n".join(lines[1:])
    if not payload:
        compact_argument = _clip_middle(argument, remaining - 1)
        return minimum_identity + "\n" + compact_argument

    return minimum_identity + "\n" + _clip_middle(payload, remaining - 1)


def _parent_identity(event: dict[str, Any]) -> str:
    frame = event["frame"]
    return (
        f"{event['id']} {frame['operation']} "
        f"operator={frame.get('operator_ref')}"
    )


def _render_context(
    episode: dict[str, Any],
    event_index: int,
    *,
    max_context_chars: int,
    argument_text_override: str | None = None,
) -> str:
    """Render context with structured pointer targets taking budget priority."""

    event = episode["events"][event_index]
    repository = episode["repository"]
    frame = event.get("frame") or {}
    prior = episode["events"][:event_index]
    order = {item["id"]: index for index, item in enumerate(prior)}
    by_id = {item["id"]: item for item in prior}

    parent_ids = list(frame.get("parents", []))
    parents: list[dict[str, Any]] = []
    seen_parent_ids: set[str] = set()
    for parent_id in parent_ids:
        parent = by_id.get(parent_id)
        if parent is None:
            raise ValueError(f"materialization lost direct parent {parent_id}")
        if parent_id not in seen_parent_ids:
            parents.append(parent)
            seen_parent_ids.add(parent_id)

    argument_text = (
        argument_text_override
        if argument_text_override is not None
        else frame.get("argument")
    )
    if argument_text is not None:
        argument_text = str(argument_text)

    operator_ref = frame.get("operator_ref")
    candidate_names = [
        str(name)
        for name in event.get("candidates", [])
        if isinstance(name, str) and name
    ]
    capability_lines: list[str] = []
    if operator_ref is not None:
        capability_lines.append(f"<OPERATOR>{operator_ref}</OPERATOR>")

    repository_line = (
        "REPOSITORY: "
        f"{repository['name']} commit={repository['commit']} "
        f"license={repository['license']} identity={repository['identity']}"
    )
    parent_lines = [_parent_identity(parent) for parent in parents]
    observed_line = (
        f"OBSERVED_INPUT: {argument_text}"
        if argument_text is not None
        else "OBSERVED_INPUT:"
    )

    def render(
        *,
        task_line: str | None = None,
        query_line: str | None = None,
        extra_capabilities: list[str] | None = None,
        rendered_parents: list[str] | None = None,
        recent_lines: list[str] | None = None,
        grounding_line: str | None = None,
    ) -> str:
        parts: list[str] = []
        if task_line:
            parts.append(task_line)
        parts.append(repository_line)
        if query_line:
            parts.append(query_line)
        parts.append("<CAPABILITY>")
        parts.extend(capability_lines)
        parts.extend(extra_capabilities or [])
        parts.extend(["</CAPABILITY>", "<STATE>"])
        parts.extend(rendered_parents if rendered_parents is not None else parent_lines)
        parts.extend(recent_lines or [])
        parts.append(observed_line)
        if grounding_line:
            parts.append(grounding_line)
        parts.append("</STATE>")
        return "\n".join(parts)

    # These fields are the irreducible supervision contract: exact current
    # argument span, every direct-parent id, the selected operator reference,
    # and repository identity. Optional prose/history may be dropped.
    context = render()
    if len(context) > max_context_chars:
        raise ValueError(
            "mandatory structured trajectory context exceeds max_context_chars"
        )

    remaining = max_context_chars - len(context)

    def optional_line(label: str, value: str, cap: int) -> str | None:
        nonlocal remaining
        if not value or remaining <= len(label) + 2:
            return None
        value_budget = min(cap, remaining - len(label) - 2)
        if value_budget <= 0:
            return None
        line = f"{label}{_clip_middle(value, value_budget)}"
        cost = len(line) + 1
        if cost > remaining:
            return None
        remaining -= cost
        return line

    # Enrich direct parents before adding free-form prose. Their payload is
    # more useful for structured next-action prediction than distant history.
    rendered_parents = list(parent_lines)
    if parents and remaining > 0:
        per_parent_extra = min(900, remaining // len(parents))
        for index, parent in enumerate(parents):
            target_size = len(parent_lines[index]) + per_parent_extra
            try:
                richer = _summary(parent, max_chars=target_size)
            except ValueError:
                continue
            extra = len(richer) - len(parent_lines[index])
            if extra > 0 and extra <= remaining:
                rendered_parents[index] = richer
                remaining -= extra

    task_line = optional_line("TASK: ", str(episode.get("task") or ""), 700)
    query_line = optional_line(
        "RETRIEVAL_QUERY: ",
        str(event.get("retrieval_query") or ""),
        400,
    )

    extra_capabilities: list[str] = []
    for name in candidate_names:
        if operator_ref is not None and name == str(operator_ref):
            continue
        line = f"<OPERATOR>{name}</OPERATOR>"
        cost = len(line) + 1
        if cost <= remaining:
            extra_capabilities.append(line)
            remaining -= cost

    grounding_text = str(event.get("grounding") or "")
    grounding_line = None
    if argument_text is None or grounding_text != argument_text:
        grounding_line = optional_line(
            "SOURCE_GROUNDING: ",
            grounding_text,
            400,
        )

    selected_ids = set(seen_parent_ids)
    recent_lines: list[str] = []
    for previous in reversed(prior):
        if previous["id"] in selected_ids:
            continue
        summary = _summary(previous)
        cost = len(summary) + 1
        if cost > remaining:
            continue
        recent_lines.append(summary)
        selected_ids.add(previous["id"])
        remaining -= cost
    recent_lines.reverse()

    context = render(
        task_line=task_line,
        query_line=query_line,
        extra_capabilities=extra_capabilities,
        rendered_parents=rendered_parents,
        recent_lines=recent_lines,
        grounding_line=grounding_line,
    )
    if len(context) > max_context_chars:
        raise ValueError("bounded context rendering exceeded max_context_chars")

    # Preserve chronological order among all selected prior events. Parent
    # enrichment above cannot disturb ids or pointer targets.
    if recent_lines and parents:
        selected = parents + [
            item
            for item in prior
            if item["id"] in selected_ids and item["id"] not in seen_parent_ids
        ]
        selected.sort(key=lambda item: order[item["id"]])

    return context


def _render_context_with_byte_budget(
    episode: dict[str, Any],
    event_index: int,
    *,
    max_context_chars: int,
    max_context_bytes: int,
    argument_text_override: str | None,
) -> str:
    if max_context_bytes <= 0:
        raise ValueError("max_context_bytes must be positive")

    char_limit = min(max_context_chars, max_context_bytes)
    while char_limit > 0:
        context = _render_context(
            episode,
            event_index,
            max_context_chars=char_limit,
            argument_text_override=argument_text_override,
        )
        encoded_size = len(context.encode("utf-8"))
        if encoded_size <= max_context_bytes:
            return context
        char_limit -= max(32, encoded_size - max_context_bytes)

    raise ValueError("structured trajectory context cannot fit byte budget")


def materialize_episode(
    episode: dict[str, Any],
    *,
    max_context_chars: int = 12000,
    max_example_bytes: int = 4000,
    max_argument_bytes: int = 1800,
    max_language_target_bytes: int = 1200,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for index, event in enumerate(episode["events"]):
        frame = event["frame"]
        raw_argument = frame.get("argument")
        training_argument = (
            _clip_utf8_tail(str(raw_argument), max_argument_bytes)
            if raw_argument is not None
            else None
        )
        raw_target = str(event.get("language_target", ""))
        target = _clip_utf8_tail(raw_target, max_language_target_bytes)

        target_bytes = len(target.encode("utf-8"))
        context_budget = max_example_bytes - target_bytes
        try:
            context = _render_context_with_byte_budget(
                episode,
                index,
                max_context_chars=max_context_chars,
                max_context_bytes=context_budget,
                argument_text_override=training_argument,
            )
        except ValueError:
            # Structured pointer targets take precedence over free-form
            # continuation text. Retry with no language-target reservation.
            target = ""
            context = _render_context_with_byte_budget(
                episode,
                index,
                max_context_chars=max_context_chars,
                max_context_bytes=max_example_bytes,
                argument_text_override=training_argument,
            )

        remaining_target_bytes = max(
            0,
            max_example_bytes - len(context.encode("utf-8")),
        )
        target = _clip_utf8_tail(target, remaining_target_bytes)

        rows.append(
            {
                "context": context,
                "language_target": target,
                "operation": frame["operation"],
                "argument": {
                    "kind": frame["argument_kind"],
                    "text": training_argument,
                    "operator": frame.get("operator_ref"),
                    "parents": frame.get("parents", []),
                    "confidence_permille": frame.get("confidence_permille", 1000),
                },
                "provenance": {
                    "source_type": "trajectory",
                    "episode_producer": episode["producer"],
                    "repository_identity": episode["repository"]["identity"],
                    "repository": episode["repository"]["name"],
                    "language": episode["repository"].get("language"),
                    "license": episode["repository"]["license"],
                    "commit": episode["repository"]["commit"],
                    "event_id": event["id"],
                },
            }
        )
    return rows


def materialize_file(
    episodes_path: str | Path,
    train_path: str | Path,
    eval_path: str | Path,
    *,
    eval_fraction: float = 0.1,
    max_context_chars: int = 12000,
    max_example_bytes: int = 4000,
) -> dict[str, int]:
    train_rows: list[dict[str, Any]] = []
    eval_rows: list[dict[str, Any]] = []
    with Path(episodes_path).open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            episode = json.loads(line)
            split = split_for_repo(episode["repository"]["identity"], eval_fraction)
            target = eval_rows if split == "eval" else train_rows
            target.extend(
                materialize_episode(
                    episode,
                    max_context_chars=max_context_chars,
                    max_example_bytes=max_example_bytes,
                )
            )

    for path, rows in ((Path(train_path), train_rows), (Path(eval_path), eval_rows)):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, sort_keys=True) + "\n")

    return {"train_rows": len(train_rows), "eval_rows": len(eval_rows)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--episodes", required=True)
    parser.add_argument("--train-output", required=True)
    parser.add_argument("--eval-output", required=True)
    parser.add_argument("--eval-fraction", type=float, default=0.1)
    parser.add_argument("--max-context-chars", type=int, default=12000)
    parser.add_argument("--max-example-bytes", type=int, default=4000)
    args = parser.parse_args()
    counts = materialize_file(
        args.episodes,
        args.train_output,
        args.eval_output,
        eval_fraction=args.eval_fraction,
        max_context_chars=args.max_context_chars,
        max_example_bytes=args.max_example_bytes,
    )
    print(json.dumps(counts, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
