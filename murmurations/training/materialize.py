"""Materialize Merkle-DAG episodes into model training/evaluation windows."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from murmurations.utils.canonical import canonical_id


def _split_for_repo(repository_identity: str, eval_fraction: float) -> str:
    if not 0.0 <= eval_fraction < 1.0:
        raise ValueError("eval_fraction must be in [0, 1)")
    digest = canonical_id({"split": "murmurations-v1", "repo": repository_identity})
    bucket = int(digest[3:11], 16) / float(0xFFFFFFFF)
    return "eval" if bucket < eval_fraction else "train"


def _render_context(episode: dict[str, Any], event_index: int) -> str:
    event = episode["events"][event_index]
    repository = episode["repository"]
    lines = [
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
        lines.append(f"<OPERATOR>{name}</OPERATOR>")
    lines.extend(["</CAPABILITY>", "<STATE>"])
    for previous in episode["events"][:event_index]:
        frame = previous["frame"]
        summary = (
            f"{previous['id']} {frame['operation']} "
            f"operator={frame.get('operator_ref')} argument={frame.get('argument')}"
        )
        lines.append(summary)
        env = previous.get("environment") or {}
        output = env.get("output")
        if isinstance(output, str) and output:
            lines.append(f"RESULT[{previous['id']}]: {output[-4000:]}")
    lines.extend(
        [
            f"OBSERVED_INPUT: {event['grounding']}",
            "</STATE>",
        ]
    )
    return "\n".join(lines)


def materialize_episode(episode: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for index, event in enumerate(episode["events"]):
        frame = event["frame"]
        rows.append(
            {
                "context": _render_context(episode, index),
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
                    "episode_producer": episode["producer"],
                    "repository_identity": episode["repository"]["identity"],
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
) -> dict[str, int]:
    train_rows: list[dict[str, Any]] = []
    eval_rows: list[dict[str, Any]] = []
    with Path(episodes_path).open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            episode = json.loads(line)
            split = _split_for_repo(episode["repository"]["identity"], eval_fraction)
            target = eval_rows if split == "eval" else train_rows
            target.extend(materialize_episode(episode))

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
    args = parser.parse_args()
    counts = materialize_file(
        args.episodes,
        args.train_output,
        args.eval_output,
        eval_fraction=args.eval_fraction,
    )
    print(json.dumps(counts, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
