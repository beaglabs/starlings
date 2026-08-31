"""Evaluate whether dynamic Operator Retrieval exposed the chosen operator."""

from __future__ import annotations

import json
from pathlib import Path


def evaluate_operator_retrieval(episodes_path: str | Path) -> dict[str, float]:
    eligible = 0
    hits = 0
    reciprocal_rank = 0.0
    with Path(episodes_path).open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            episode = json.loads(line)
            for event in episode.get("events", []):
                expected = (event.get("frame") or {}).get("operator_ref")
                if expected is None:
                    continue
                eligible += 1
                candidates = list(event.get("candidates", []))
                if expected in candidates:
                    hits += 1
                    reciprocal_rank += 1.0 / (candidates.index(expected) + 1)

    return {
        "operator_events": float(eligible),
        "retrieval_recall_at_k": hits / max(1, eligible),
        "retrieval_mrr": reciprocal_rank / max(1, eligible),
    }
