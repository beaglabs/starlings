"""Small in-memory Merkle-DAG used by training and benchmark fixtures."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Iterator

from .protocol import ActionFrame


@dataclass(frozen=True)
class DagNode:
    id: str
    frame: ActionFrame


class MerkleDag:
    def __init__(self) -> None:
        self._nodes: dict[str, DagNode] = {}

    def add(self, frame: ActionFrame) -> DagNode:
        missing = [parent for parent in frame.parents if parent not in self._nodes]
        if missing:
            raise ValueError(f"parent closure violated; missing {missing}")
        node = DagNode(frame.id, frame)
        existing = self._nodes.get(node.id)
        if existing is not None and existing != node:
            raise ValueError("content identity collision")
        self._nodes[node.id] = node
        return node

    def get(self, node_id: str) -> DagNode:
        return self._nodes[node_id]

    def ancestors(self, node_id: str) -> set[str]:
        seen: set[str] = set()
        stack = list(self.get(node_id).frame.parents)
        while stack:
            parent = stack.pop()
            if parent in seen:
                continue
            seen.add(parent)
            stack.extend(self.get(parent).frame.parents)
        return seen

    def verify(self) -> None:
        for node_id, node in self._nodes.items():
            if node.id != node.frame.id:
                raise ValueError(f"identity mismatch for {node_id}")
            for parent in node.frame.parents:
                if parent not in self._nodes:
                    raise ValueError(f"missing parent {parent}")
        self._verify_acyclic()

    def _verify_acyclic(self) -> None:
        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(node_id: str) -> None:
            if node_id in visiting:
                raise ValueError("Merkle-DAG contains a cycle")
            if node_id in visited:
                return
            visiting.add(node_id)
            for parent in self.get(node_id).frame.parents:
                visit(parent)
            visiting.remove(node_id)
            visited.add(node_id)

        for node_id in self._nodes:
            visit(node_id)

    def __len__(self) -> int:
        return len(self._nodes)

    def __iter__(self) -> Iterator[DagNode]:
        return iter(self._nodes.values())
