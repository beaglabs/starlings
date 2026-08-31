"""Native Murmurations/Starlings protocol vocabulary."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import Any, Mapping, Sequence

from .canonical import canonical_id


class Operation(IntEnum):
    NOOP = 0
    OBSERVE = 1
    QUERY = 2
    CLAIM = 3
    EVIDENCE = 4
    PROPOSE = 5
    ACCEPT = 6
    REJECT = 7
    CHALLENGE = 8
    RETRACT = 9
    DELEGATE = 10
    EXECUTE = 11


class ArgumentKind(IntEnum):
    NONE = 0
    TEXT = 1
    VARIABLE = 2
    INVARIANT = 3
    CLAIM = 4
    EVIDENCE = 5
    AGENT = 6
    CAPABILITY = 7
    ARTIFACT = 8
    ACTION = 9
    SYMBOL = 10
    SCALAR = 11
    OPERATOR = 12


def _validate_parent(value: str) -> None:
    if not value.startswith("b3:") or len(value) != 67:
        raise ValueError(f"invalid BLAKE3 reference: {value!r}")
    int(value[3:], 16)


@dataclass(frozen=True)
class ActionFrame:
    operation: Operation
    argument_kind: ArgumentKind = ArgumentKind.NONE
    argument: str | None = None
    parents: tuple[str, ...] = ()
    confidence_permille: int = 1000
    actor: str | None = None
    metadata: Mapping[str, Any] | None = None
    operator_ref: str | None = None

    def __post_init__(self) -> None:
        if not 0 <= self.confidence_permille <= 1000:
            raise ValueError("confidence_permille must be in [0, 1000]")
        if len(self.parents) > 4:
            raise ValueError("protocol v0 allows at most four direct parents")
        for parent in self.parents:
            _validate_parent(parent)
        if self.argument_kind is ArgumentKind.NONE and self.argument is not None:
            raise ValueError("NONE argument kind cannot carry an argument")
        if self.operator_ref is not None and not self.operator_ref.strip():
            raise ValueError("operator_ref cannot be empty")

    def record(self) -> dict[str, Any]:
        return {
            "version": 2,
            "operation": self.operation.name,
            "argument_kind": self.argument_kind.name,
            "argument": self.argument,
            "operator_ref": self.operator_ref,
            "parents": list(self.parents),
            "confidence_permille": self.confidence_permille,
            "actor": self.actor,
            "metadata": dict(self.metadata or {}),
        }

    @property
    def id(self) -> str:
        return canonical_id(self.record())


CONTROL_TOKENS: Sequence[str] = (
    "<ACT>",
    "<OBSERVE>",
    "<QUERY>",
    "<CLAIM>",
    "<EVIDENCE>",
    "<PROPOSE>",
    "<ACCEPT>",
    "<REJECT>",
    "<CHALLENGE>",
    "<RETRACT>",
    "<DELEGATE>",
    "<EXECUTE>",
    "<REF>",
    "<B3>",
    "<POPULATION>",
    "<STATE>",
    "<CAPABILITY>",
    "<OPERATOR>",
)
