"""JSONL trajectory and code-window dataset for protocol-native supervision."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Sequence

import torch
from torch.utils.data import Dataset

from murmurations.utils.protocol import ArgumentKind, Operation


def _char_span_to_token_span(
    context: str,
    offsets: Sequence[Sequence[int]],
    value: Any,
    label: str,
) -> tuple[int, int]:
    """Map an exact raw-context substring to token indices.

    Byte-level BPE tokenization is context-sensitive at whitespace boundaries,
    so independently encoding a pointer target and searching for its token IDs
    is not reliable. Offset mappings from the full context are authoritative.
    """

    text = str(value)
    char_start = context.find(text)
    if char_start < 0:
        raise ValueError(f"{label} not found in context: {value!r}")
    char_end = char_start + len(text)

    covered: list[int] = []
    for index, pair in enumerate(offsets):
        start, end = int(pair[0]), int(pair[1])
        if end <= start:
            continue
        if end > char_start and start < char_end:
            covered.append(index)

    if not covered:
        raise ValueError(
            f"{label} has no tokenizer-offset coverage in context: {value!r}"
        )

    first = covered[0]
    last = covered[-1]
    first_start = int(offsets[first][0])
    last_end = int(offsets[last][1])
    if first_start > char_start or last_end < char_end:
        raise ValueError(
            f"{label} is only partially covered by tokenizer offsets: {value!r}"
        )
    return first, last


class ProtocolDataset(Dataset[dict[str, Any]]):
    """Language/code + structured action supervision from one or more JSONL files."""

    def __init__(
        self,
        path: str | Path | Sequence[str | Path],
        tokenizer: Any,
        max_seq_len: int,
    ) -> None:
        self.tokenizer = tokenizer
        self.max_seq_len = max_seq_len
        self.rows: list[dict[str, Any]] = []
        paths = [path] if isinstance(path, (str, Path)) else list(path)
        for raw_path in paths:
            current = Path(raw_path)
            with current.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if line:
                        self.rows.append(json.loads(line))
        if not self.rows:
            raise ValueError(f"dataset is empty: {paths}")

    def __len__(self) -> int:
        return len(self.rows)

    def _context_encoding(self, context: str) -> tuple[list[int], list[tuple[int, int]]]:
        encoded = self.tokenizer(
            context,
            add_special_tokens=False,
            return_offsets_mapping=True,
        )
        context_ids = list(encoded["input_ids"])
        raw_offsets = encoded.get("offset_mapping")
        if raw_offsets is None:
            raise ValueError(
                "ProtocolDataset requires a fast tokenizer with offset mappings"
            )
        offsets = [(int(start), int(end)) for start, end in raw_offsets]
        if len(context_ids) != len(offsets):
            raise ValueError("tokenizer returned mismatched input_ids/offset_mapping")
        return context_ids, offsets

    def _pointer_label(
        self,
        context: str,
        offsets: Sequence[Sequence[int]],
        value: Any,
        label: str,
    ) -> int:
        if value is None:
            return -100
        return _char_span_to_token_span(context, offsets, value, label)[0]

    def __getitem__(self, index: int) -> dict[str, Any]:
        row = self.rows[index]
        context = str(row["context"])
        language_target = str(row.get("language_target", ""))
        context_ids, context_offsets = self._context_encoding(context)
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

        available_target_tokens = self.max_seq_len - len(control_ids) - 1
        if available_target_tokens < 0:
            raise ValueError(
                "structured context length "
                f"{len(control_ids)} exceeds max_seq_len={self.max_seq_len} "
                "before language target; pointer-bearing context must be rematerialized"
            )
        if len(target_ids) > available_target_tokens:
            target_ids = target_ids[:available_target_tokens]

        input_ids = control_ids + target_ids + [eos]
        language_labels = [-100] * len(control_ids) + target_ids + [eos]

        operation = Operation[str(row.get("operation", "NOOP")).upper()]
        argument = row.get("argument") or {}
        kind = ArgumentKind[str(argument.get("kind", "NONE")).upper()]
        argument_text = argument.get("text")
        start_label = end_label = -100
        if argument_text is not None:
            start_label, end_label = _char_span_to_token_span(
                context,
                context_offsets,
                argument_text,
                "argument text",
            )

        operator_ref = argument.get("operator", row.get("operator"))
        operator_pointer_label = self._pointer_label(
            context,
            context_offsets,
            operator_ref,
            "operator reference",
        )

        parents = list(argument.get("parents", []))
        if len(parents) > 4:
            raise ValueError("at most four direct parents are supported")
        parent_labels = [-100] * 4
        for parent_index, parent in enumerate(parents):
            parent_labels[parent_index] = self._pointer_label(
                context,
                context_offsets,
                parent,
                "parent reference",
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
