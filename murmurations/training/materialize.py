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


def _render_context(
    episode: dict[str, Any],
    event_index: int,
    *,
    max_context_chars: int,
    argument_text_override: str | None = None,
) -> str:
    event = episode["events"][event_index]
    repository = episode["repository"]
    task_limit = min(4000, max(256, max_context_chars // 3))
    grounding_limit = min(3000, max(256, max_context_chars // 4))
    query_limit = min(1000, max(128, max_context_chars // 12))
    header = [
        f"TASK: {_clip_middle(str(episode['task']), task_limit)}",
        (
            "REPOSITORY: "
            f"{repository['name']} commit={repository['commit']} "
            f"license={repository['license']} identity={repository['identity']}"
        ),
        (
            "RETRIEVAL_QUERY: "
            f"{_clip_middle(str(event['retrieval_query']), query_limit)}"
        ),
        "<CAPABILITY>",
    ]
    for name in event.get("candidates", []):
        header.append(f"<OPERATOR>{name}</OPERATOR>")
    header.extend(["</CAPABILITY>", "<STATE>"])

    prior = episode["events"][:event_index]
    order = {item["id"]: index for index, item in enumerate(prior)}
    by_id = {item["id"]: item for item in prior}
    parent_ids = list((event.get("frame") or {}).get("parents", []))
    selected: list[dict[str, Any]] = []
    selected_ids: set[str] = set()

    for parent_id in parent_ids:
        parent = by_id.get(parent_id)
        if parent is None:
            raise ValueError(f"materialization lost direct parent {parent_id}")
        if parent_id not in selected_ids:
            selected.append(parent)
            selected_ids.add(parent_id)

    frame = event.get("frame") or {}
    argument_text = (
        argument_text_override
        if argument_text_override is not None
        else frame.get("argument")
    )
    grounding_text = str(event.get("grounding") or "")
    if argument_text is not None:
        argument_text = str(argument_text)
        # Argument start/end supervision is a pointer into the raw context.
        # Never truncate or rewrite the current structured argument.
        fixed_tail = [f"OBSERVED_INPUT: {argument_text}"]
        if grounding_text and grounding_text != argument_text:
            fixed_tail.append(
                "SOURCE_GROUNDING: "
                + _clip_middle(grounding_text, min(1000, grounding_limit))
            )
    else:
        fixed_tail = [
            "OBSERVED_INPUT: "
            + _clip_middle(grounding_text, grounding_limit)
        ]
    fixed_tail.append("</STATE>")
    fixed_chars = len("\n".join(header + fixed_tail))
    budget = max(0, max_context_chars - fixed_chars)

    # Direct parents are mandatory pointer targets. Give them the available
    # state budget first and compact their payloads as needed; recent context
    # is strictly opportunistic.
    parent_summaries: dict[str, str] = {}
    if selected:
        separators = len(selected)
        parent_budget = max(0, budget - separators)
        per_parent_budget = parent_budget // len(selected)
        for item in selected:
            parent_summaries[item["id"]] = _summary(
                item,
                max_chars=per_parent_budget,
            )
    used = sum(len(parent_summaries[item["id"]]) + 1 for item in selected)

    recent: list[dict[str, Any]] = []
    for previous in reversed(prior):
        if previous["id"] in selected_ids:
            continue
        size = len(_summary(previous)) + 1
        if used + size > budget:
            continue
        recent.append(previous)
        selected_ids.add(previous["id"])
        used += size
    selected.extend(reversed(recent))
    selected.sort(key=lambda item: order[item["id"]])

    rendered_selected = [
        (
            parent_summaries[item["id"]]
            if item["id"] in parent_summaries
            else _summary(item)
        )
        for item in selected
    ]
    context = "\n".join(header + rendered_selected + fixed_tail)
    if len(context) > max_context_chars:
        raise ValueError("bounded context rendering exceeded max_context_chars")
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
