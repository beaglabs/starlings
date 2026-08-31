"""Deterministic Operator Retrieval (OR) for training and bootstrap inference.

OR exposes a bounded, locally relevant operator set. It does not execute
operators and it does not encode a workflow.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import re
from typing import Iterable, Mapping, Sequence

from murmurations.utils.canonical import canonical_id


_TOKEN_RE = re.compile(r"[A-Za-z0-9_.:/+-]+")


def _tokens(text: str) -> set[str]:
    return {token.lower() for token in _TOKEN_RE.findall(text)}


@dataclass(frozen=True)
class OperatorDescriptor:
    name: str
    description: str
    kind: str
    tags: tuple[str, ...] = ()
    requires: tuple[str, ...] = ()
    provides: tuple[str, ...] = ()
    cost_millis: int = 1
    metadata: Mapping[str, str | int | bool] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise ValueError("operator name cannot be empty")
        if not self.description.strip():
            raise ValueError("operator description cannot be empty")
        if self.cost_millis < 0:
            raise ValueError("cost_millis cannot be negative")

    @property
    def identity(self) -> str:
        return canonical_id(
            {
                "version": 1,
                "name": self.name,
                "description": self.description,
                "kind": self.kind,
                "tags": list(self.tags),
                "requires": list(self.requires),
                "provides": list(self.provides),
                "cost_millis": self.cost_millis,
                "metadata": dict(self.metadata),
            }
        )

    def render(self) -> str:
        fields = [
            f"<OPERATOR>{self.name}</OPERATOR>",
            f"kind={self.kind}",
            f"description={self.description}",
        ]
        if self.provides:
            fields.append("provides=" + ",".join(self.provides))
        if self.requires:
            fields.append("requires=" + ",".join(self.requires))
        return " | ".join(fields)


@dataclass(frozen=True)
class RetrievedOperator:
    descriptor: OperatorDescriptor
    score: int


class OperatorRegistry:
    def __init__(self, operators: Iterable[OperatorDescriptor] = ()) -> None:
        self._operators: dict[str, OperatorDescriptor] = {}
        for operator in operators:
            self.register(operator)

    def register(self, operator: OperatorDescriptor) -> None:
        existing = self._operators.get(operator.name)
        if existing is not None and existing != operator:
            raise ValueError(f"operator already registered with different descriptor: {operator.name}")
        self._operators[operator.name] = operator

    def descriptors(self) -> tuple[OperatorDescriptor, ...]:
        return tuple(self._operators[name] for name in sorted(self._operators))

    def get(self, name: str) -> OperatorDescriptor:
        try:
            return self._operators[name]
        except KeyError as exc:
            raise KeyError(f"unknown operator: {name}") from exc

    def retrieve(
        self,
        query: str,
        *,
        top_k: int = 7,
        available: Sequence[str] | None = None,
    ) -> list[RetrievedOperator]:
        if top_k <= 0:
            return []
        query_tokens = _tokens(query)
        available_set = None if available is None else set(available)
        ranked: list[RetrievedOperator] = []

        for operator in self._operators.values():
            if available_set is not None and any(req not in available_set for req in operator.requires):
                continue

            name_tokens = _tokens(operator.name)
            desc_tokens = _tokens(operator.description)
            tag_tokens = _tokens(" ".join(operator.tags))
            provide_tokens = _tokens(" ".join(operator.provides))
            score = 0
            score += 8 * len(query_tokens & name_tokens)
            score += 4 * len(query_tokens & provide_tokens)
            score += 3 * len(query_tokens & tag_tokens)
            score += 2 * len(query_tokens & desc_tokens)
            lowered = query.lower().strip()
            if lowered and lowered in operator.name.lower():
                score += 12
            if lowered and lowered in operator.description.lower():
                score += 6
            if score > 0:
                ranked.append(RetrievedOperator(operator, score))

        ranked.sort(
            key=lambda item: (
                -item.score,
                item.descriptor.cost_millis,
                item.descriptor.name,
            )
        )
        return ranked[:top_k]

    def render_retrieval(
        self,
        query: str,
        *,
        top_k: int = 7,
        available: Sequence[str] | None = None,
    ) -> str:
        hits = self.retrieve(query, top_k=top_k, available=available)
        return "\n".join(hit.descriptor.render() for hit in hits)
