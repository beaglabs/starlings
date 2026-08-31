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
    )


def evaluate_replay(path: str | Path) -> dict[str, Any]:
    dag = MerkleDag()
    operations: Counter[str] = Counter()
    claimed_ids = 0
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            frame_record = row.get("frame", row)
            frame = _frame(frame_record)
            node = dag.add(frame)
            expected_id = row.get("id")
            if expected_id is not None:
                claimed_ids += 1
                if expected_id != node.id:
                    raise ValueError(
                        f"line {line_no}: claimed identity {expected_id} != canonical {node.id}"
                    )
            operations[frame.operation.name] += 1
    dag.verify()

    ancestor_edges = sum(len(node.frame.parents) for node in dag)
    return {
        "nodes": len(dag),
        "direct_parent_edges": ancestor_edges,
        "claimed_ids_verified": claimed_ids,
        "operations": dict(sorted(operations.items())),
        "parent_closure": True,
        "acyclic": True,
    }
