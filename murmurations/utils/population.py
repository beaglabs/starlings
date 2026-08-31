"""Canonical carrier for P = (A, G, X, M, F, Π, C, Φ, J).

The meanings of the nine slots are deliberately not redefined here. Murmurations
only validates that the complete context exists and renders it deterministically
for model input. Starlings owns the formal semantics.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

import yaml

from .canonical import canonical_bytes

_KEYS = ("A", "G", "X", "M", "F", "Pi", "C", "Phi", "J")
_ALIASES = {"Π": "Pi", "Φ": "Phi"}


@dataclass(frozen=True)
class PopulationContext:
    A: Any
    G: Any
    X: Any
    M: Any
    F: Any
    Pi: Any
    C: Any
    Phi: Any
    J: Any

    @classmethod
    def from_mapping(cls, source: Mapping[str, Any]) -> "PopulationContext":
        normalized = dict(source)
        for alias, name in _ALIASES.items():
            if alias in normalized:
                if name in normalized:
                    raise ValueError(f"both {alias!r} and {name!r} were supplied")
                normalized[name] = normalized.pop(alias)
        missing = [key for key in _KEYS if key not in normalized]
        if missing:
            raise ValueError(f"population context missing slots: {missing}")
        return cls(**{key: normalized[key] for key in _KEYS})

    @classmethod
    def load_yaml(cls, path: str | Path) -> "PopulationContext":
        with Path(path).open("r", encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        if not isinstance(data, Mapping):
            raise TypeError("population YAML must contain a mapping")
        return cls.from_mapping(data)

    def record(self) -> dict[str, Any]:
        return {key: getattr(self, key) for key in _KEYS}

    def render(self) -> str:
        payload = canonical_bytes(self.record()).decode("utf-8")
        return f"<POPULATION>{payload}</POPULATION>"
