"""JSONL trajectory dataset for protocol-native supervision."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Sequence

import torch
from torch.utils.data import Dataset

from murmurations.utils.protocol import ArgumentKind, Operation


def _find_subsequence(haystack: Sequence[int], needle: Sequence[int]) -> tuple[int, int] | None:
    if not needle:
        return None
    for start in range(len(haystack) - len(needle) + 1):
        if list(haystack[start : start + len(needle)]) == list(needle):
            return start, start + len(needle) - 1
    return None


class ProtocolDataset(Dataset[dict[str, Any]]):
    """Trajectory JSONL with language + structured action supervision.

    Argument, operator, and parent labels are pointers into exact strings already
    present in context. The model never emits BLAKE3 identities or arbitrary
    tool names from the vocabulary when a retrieved operator is available.
    """

    def __init__(self, path: str | Path, tokenizer: Any, max_seq_len: int) -> None:
        self.tokenizer = tokenizer
        self.max_seq_len = max_seq_len
        self.rows: list[dict[str, Any]] = []
        with Path(path).open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    self.rows.append(json.loads(line))
        if not self.rows:
            raise ValueError(f"dataset is empty: {path}")

    def __len__(self) -> int:
        return len(self.rows)

    def _pointer_label(self, context_ids: Sequence[int], value: Any, label: str) -> int:
        if value is None:
            return -100
        encoded = self.tokenizer.encode(str(value), add_special_tokens=False)
        found = _find_subsequence(context_ids, encoded)
        if found is None:
            raise ValueError(f"{label} not found in context: {value!r}")
        return found[0]

    def __getitem__(self, index: int) -> dict[str, Any]:
        row = self.rows[index]
        context = str(row["context"])
        language_target = str(row.get("language_target", ""))
        context_ids = self.tokenizer.encode(context, add_special_tokens=False)
        act_ids = self.tokenizer.encode("<ACT>", add_special_tokens=False)
        if len(act_ids) != 1:
            raise ValueError("<ACT> must be a single special token")
        control_ids = context_ids + act_ids
        target_ids = self.tokenizer.encode(language_target, add_special_tokens=False)

        if not context_ids:
            raise ValueError("context must encode to at least one token")
        eos = self.tokenizer.eos_token_id
        if eos is None:
            raise ValueError("tokenizer must define eos_token_id")

        input_ids = control_ids + target_ids + [eos]
        language_labels = [-100] * len(control_ids) + target_ids + [eos]
        if len(input_ids) > self.max_seq_len:
            raise ValueError(
                f"example length {len(input_ids)} exceeds max_seq_len={self.max_seq_len}; "
                "pre-chunk trajectories so evidence references remain intact"
            )

        operation = Operation[str(row.get("operation", "NOOP")).upper()]
        argument = row.get("argument") or {}
        kind = ArgumentKind[str(argument.get("kind", "NONE")).upper()]
        argument_text = argument.get("text")
        start_label = end_label = -100
        if argument_text is not None:
            encoded = self.tokenizer.encode(str(argument_text), add_special_tokens=False)
            found = _find_subsequence(context_ids, encoded)
            if found is None:
                raise ValueError(f"argument text not found in context: {argument_text!r}")
            start_label, end_label = found

        operator_ref = argument.get("operator", row.get("operator"))
        operator_pointer_label = self._pointer_label(context_ids, operator_ref, "operator reference")

        parents = list(argument.get("parents", []))
        if len(parents) > 4:
            raise ValueError("at most four direct parents are supported")
        parent_labels = [-100] * 4
        for parent_index, parent in enumerate(parents):
            parent_labels[parent_index] = self._pointer_label(
                context_ids, parent, "parent reference"
            )

        confidence = int(argument.get("confidence_permille", 1000))
        if not 0 <= confidence <= 1000:
            raise ValueError("confidence_permille must be in [0, 1000]")

        return {
            "input_ids": input_ids,
            "language_labels": language_labels,
            "control_position": len(control_ids) - 1,
            "operation_label": int(operation),
            "argument_kind_label": int(kind),
            "argument_start_label": start_label,
            "argument_end_label": end_label,
            "operator_pointer_label": operator_pointer_label,
            "parent_pointer_labels": parent_labels,
            "parent_count_label": len(parents),
            "confidence_target": confidence / 1000.0,
            "confidence_mask": kind is not ArgumentKind.NONE or operator_ref is not None,
        }


class ProtocolCollator:
    def __init__(self, pad_token_id: int) -> None:
        self.pad_token_id = pad_token_id

    def __call__(self, rows: Sequence[dict[str, Any]]) -> dict[str, torch.Tensor]:
        max_len = max(len(row["input_ids"]) for row in rows)
        input_ids = []
        language_labels = []
        for row in rows:
            padding = max_len - len(row["input_ids"])
            input_ids.append(row["input_ids"] + [self.pad_token_id] * padding)
            language_labels.append(row["language_labels"] + [-100] * padding)

        return {
            "input_ids": torch.tensor(input_ids, dtype=torch.long),
            "language_labels": torch.tensor(language_labels, dtype=torch.long),
            "control_positions": torch.tensor([row["control_position"] for row in rows], dtype=torch.long),
            "operation_labels": torch.tensor([row["operation_label"] for row in rows], dtype=torch.long),
            "argument_kind_labels": torch.tensor([row["argument_kind_label"] for row in rows], dtype=torch.long),
            "argument_start_labels": torch.tensor([row["argument_start_label"] for row in rows], dtype=torch.long),
            "argument_end_labels": torch.tensor([row["argument_end_label"] for row in rows], dtype=torch.long),
            "operator_pointer_labels": torch.tensor([row["operator_pointer_label"] for row in rows], dtype=torch.long),
            "parent_pointer_labels": torch.tensor([row["parent_pointer_labels"] for row in rows], dtype=torch.long),
            "parent_count_labels": torch.tensor([row["parent_count_label"] for row in rows], dtype=torch.long),
            "confidence_targets": torch.tensor([row["confidence_target"] for row in rows], dtype=torch.float32),
            "confidence_mask": torch.tensor([row["confidence_mask"] for row in rows], dtype=torch.bool),
        }
