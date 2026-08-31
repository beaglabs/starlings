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


def _summary(event: dict[str, Any]) -> str:
    frame = event["frame"]
    argument = str(frame.get("argument") or "")[-800:]
    lines = [
        f"{event['id']} {frame['operation']} operator={frame.get('operator_ref')} argument={argument}"
    ]
    env = event.get("environment") or {}
    argv = env.get("argv")
    if isinstance(argv, list) and argv:
        lines.append(
            f"ARGV[{event['id']}]: "
            + json.dumps([str(item) for item in argv], separators=(",", ":"))
        )
    output = env.get("output")
    if isinstance(output, str) and output:
        lines.append(f"RESULT[{event['id']}]: {output[-1600:]}")
    return "\n".join(lines)


def _render_context(
    episode: dict[str, Any],
    event_index: int,
    *,
    max_context_chars: int,
) -> str:
    event = episode["events"][event_index]
    repository = episode["repository"]
    header = [
        f"TASK: {episode['task']}",
        (
            "REPOSITORY: "
            f"{repository['name']} commit={repository['commit']} "
            f"license={repository['license']} identity={repository['identity']}"
        ),
        f"RETRIEVAL_QUERY: {event['retrieval_query']}",
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

    fixed_tail = [
        f"OBSERVED_INPUT: {event['grounding'][-4000:]}",
        "</STATE>",
    ]
    fixed_chars = len("\n".join(header + fixed_tail))
    budget = max(0, max_context_chars - fixed_chars)
    used = sum(len(_summary(item)) + 1 for item in selected)

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

    context = "\n".join(header + [_summary(item) for item in selected] + fixed_tail)
    if len(context) > max_context_chars:
        # Keep the current grounding and direct-parent summaries; if even those
        # cannot fit, reject rather than create unsupervisable pointer labels.
        parent_text = "\n".join(_summary(by_id[parent_id]) for parent_id in parent_ids)
        compact = "\n".join(header + [parent_text] + fixed_tail)
        if len(compact) > max_context_chars:
            raise ValueError("direct-parent context exceeds max_context_chars")
        context = compact
    return context


def materialize_episode(
    episode: dict[str, Any],
    *,
    max_context_chars: int = 12000,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for index, event in enumerate(episode["events"]):
        frame = event["frame"]
        rows.append(
            {
                "context": _render_context(
                    episode, index, max_context_chars=max_context_chars
                ),
                "language_target": event.get("language_target", ""),
                "operation": frame["operation"],
                "argument": {
                    "kind": frame["argument_kind"],
                    "text": frame.get("argument"),
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
                materialize_episode(episode, max_context_chars=max_context_chars)
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
    args = parser.parse_args()
    counts = materialize_file(
        args.episodes,
        args.train_output,
        args.eval_output,
        eval_fraction=args.eval_fraction,
        max_context_chars=args.max_context_chars,
    )
    print(json.dumps(counts, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
