"""Validate attributable/replayable action traces independently of model quality."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any

from murmurations.utils.dag import MerkleDag
from murmurations.utils.protocol import ActionFrame, ArgumentKind, Operation


def _frame(record: dict[str, Any]) -> ActionFrame:
    return ActionFrame(
        operation=Operation[record["operation"]],
        argument_kind=ArgumentKind[record.get("argument_kind", "NONE")],
        argument=record.get("argument"),
        parents=tuple(record.get("parents", [])),
        confidence_permille=int(record.get("confidence_permille", 1000)),
        actor=record.get("actor"),
        metadata=record.get("metadata") or {},
        operator_ref=record.get("operator_ref"),
    )


def evaluate_replay(path: str | Path) -> dict[str, Any]:
    operations: Counter[str] = Counter()
    operator_refs: Counter[str] = Counter()
    claimed_ids = 0
    total_nodes = 0
    total_edges = 0
    episode_count = 0
    flat_dag = MerkleDag()
    saw_flat = False

    def add_record(dag: MerkleDag, frame_record: dict[str, Any], expected_id: str | None, label: str) -> None:
        nonlocal claimed_ids
        frame = _frame(frame_record)
        node = dag.add(frame)
        if expected_id is not None:
            claimed_ids += 1
            if expected_id != node.id:
                raise ValueError(
                    f"{label}: claimed identity {expected_id} != canonical {node.id}"
                )
        operations[frame.operation.name] += 1
        if frame.operator_ref is not None:
            operator_refs[frame.operator_ref] += 1

    with Path(path).open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            events = row.get("events")
            if isinstance(events, list):
                episode_count += 1
                dag = MerkleDag()
                for event_index, event in enumerate(events):
                    add_record(
                        dag,
                        event["frame"],
                        event.get("id"),
                        f"line {line_no} event {event_index}",
                    )
                dag.verify()
                total_nodes += len(dag)
                total_edges += sum(len(node.frame.parents) for node in dag)
            else:
                saw_flat = True
                add_record(
                    flat_dag,
                    row.get("frame", row),
                    row.get("id"),
                    f"line {line_no}",
                )

    if saw_flat:
        flat_dag.verify()
        total_nodes += len(flat_dag)
        total_edges += sum(len(node.frame.parents) for node in flat_dag)

    return {
        "nodes": total_nodes,
        "direct_parent_edges": total_edges,
        "episodes": episode_count,
        "claimed_ids_verified": claimed_ids,
        "operations": dict(sorted(operations.items())),
        "operator_refs": dict(sorted(operator_refs.items())),
        "parent_closure": True,
        "acyclic": True,
    }
