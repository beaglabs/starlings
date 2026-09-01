"""JSONL trajectory and code-window dataset for protocol-native supervision."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Iterator, Sequence

import torch
from torch.utils.data import Dataset, Sampler

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


def _tokenizer_fingerprint(tokenizer: Any) -> str:
    backend = getattr(tokenizer, "backend_tokenizer", None)
    if backend is not None and hasattr(backend, "to_str"):
        payload = backend.to_str()
    else:
        payload = repr(tokenizer)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _source_fingerprint(paths: Sequence[Path]) -> list[dict[str, Any]]:
    return [
        {
            "path": str(path.resolve()),
            "size": path.stat().st_size,
            "mtime_ns": path.stat().st_mtime_ns,
        }
        for path in paths
    ]


class ProtocolDataset(Dataset[dict[str, Any]]):
    """Language/code + structured action supervision from one or more JSONL files."""

    def __init__(
        self,
        path: str | Path | Sequence[str | Path],
        tokenizer: Any,
        max_seq_len: int,
        *,
        pretokenize: bool = False,
        cache_path: str | Path | None = None,
    ) -> None:
        self.tokenizer = tokenizer
        self.max_seq_len = max_seq_len
        self.paths = [
            Path(path)
            if isinstance(path, (str, Path))
            else path
        ] if isinstance(path, (str, Path)) else [Path(item) for item in path]
        self.rows: list[dict[str, Any]] = []
        self.examples: list[dict[str, Any]] | None = None
        self.lengths: list[int] | None = None
        self.cache_path = Path(cache_path) if cache_path is not None else None

        if not self.paths:
            raise ValueError("dataset requires at least one path")
        for current in self.paths:
            if not current.exists():
                raise FileNotFoundError(current)

        cache_metadata = {
            "version": 1,
            "max_seq_len": self.max_seq_len,
            "tokenizer_sha256": _tokenizer_fingerprint(tokenizer),
            "sources": _source_fingerprint(self.paths),
        }

        if pretokenize and self.cache_path is not None and self.cache_path.exists():
            cached = torch.load(
                self.cache_path,
                map_location="cpu",
                weights_only=False,
            )
            if cached.get("metadata") == cache_metadata:
                self.examples = list(cached["examples"])
                self.lengths = [len(example["input_ids"]) for example in self.examples]
                print(
                    f"[data] loaded token cache {self.cache_path} "
                    f"examples={len(self.examples)}",
                    flush=True,
                )
                return

        for current in self.paths:
            with current.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if line:
                        self.rows.append(json.loads(line))
        if not self.rows:
            raise ValueError(f"dataset is empty: {self.paths}")

        if pretokenize:
            self.examples = []
            total = len(self.rows)
            for index, row in enumerate(self.rows):
                self.examples.append(self._encode_row(row))
                if (index + 1) % 10000 == 0:
                    print(
                        f"[data] pretokenized {index + 1}/{total}",
                        flush=True,
                    )
            self.lengths = [len(example["input_ids"]) for example in self.examples]
            self.rows.clear()
            if self.cache_path is not None:
                self.cache_path.parent.mkdir(parents=True, exist_ok=True)
                temporary = self.cache_path.with_suffix(self.cache_path.suffix + ".tmp")
                torch.save(
                    {
                        "metadata": cache_metadata,
                        "examples": self.examples,
                    },
                    temporary,
                )
                temporary.replace(self.cache_path)
                print(
                    f"[data] wrote token cache {self.cache_path} "
                    f"examples={len(self.examples)}",
                    flush=True,
                )

    def __len__(self) -> int:
        if self.examples is not None:
            return len(self.examples)
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

    def _encode_row(self, row: dict[str, Any]) -> dict[str, Any]:
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

    def __getitem__(self, index: int) -> dict[str, Any]:
        if self.examples is not None:
            return self.examples[index]
        return self._encode_row(self.rows[index])


class TokenBudgetBatchSampler(Sampler[list[int]]):
    """Length-aware batches bounded by actual padded-token compute.

    A candidate batch of N examples with maximum sequence length L consumes
    N * L transformer token positions after collation. Bounding that quantity
    avoids the pathological padding amplification seen with random fixed-size
    batches while still allowing many short examples to share one launch.
    """

    def __init__(
        self,
        lengths: Sequence[int],
        *,
        max_tokens: int,
        max_examples: int,
        bucket_size: int = 2048,
        shuffle: bool = True,
        seed: int = 17,
    ) -> None:
        if not lengths:
            raise ValueError("token-budget sampler requires non-empty lengths")
        if max_tokens <= 0:
            raise ValueError("max_tokens must be positive")
        if max_examples <= 0:
            raise ValueError("max_examples must be positive")
        if bucket_size <= 0:
            raise ValueError("bucket_size must be positive")
        if max(lengths) > max_tokens:
            raise ValueError(
                f"longest sequence {max(lengths)} exceeds token budget {max_tokens}"
            )

        self.lengths = [int(length) for length in lengths]
        self.max_tokens = int(max_tokens)
        self.max_examples = int(max_examples)
        self.bucket_size = int(bucket_size)
        self.shuffle = bool(shuffle)
        self.seed = int(seed)
        self.epoch = 0
        self._batches = self._build_batches()

    def _build_batches(self) -> list[list[int]]:
        indices = list(range(len(self.lengths)))
        if self.shuffle:
            generator = torch.Generator()
            generator.manual_seed(self.seed)
            permutation = torch.randperm(
                len(indices),
                generator=generator,
            ).tolist()
            indices = [indices[index] for index in permutation]

        batches: list[list[int]] = []
        for start in range(0, len(indices), self.bucket_size):
            bucket = indices[start : start + self.bucket_size]
            bucket.sort(key=lambda index: (self.lengths[index], index))

            current: list[int] = []
            current_max = 0
            for index in bucket:
                length = self.lengths[index]
                proposed_max = max(current_max, length)
                proposed_count = len(current) + 1
                padded_tokens = proposed_count * proposed_max

                if current and (
                    proposed_count > self.max_examples
                    or padded_tokens > self.max_tokens
                ):
                    batches.append(current)
                    current = []
                    current_max = 0

                current.append(index)
                current_max = max(current_max, length)

            if current:
                batches.append(current)

        if not batches:
            raise ValueError("token-budget sampler produced no batches")
        return batches

    def __iter__(self) -> Iterator[list[int]]:
        order = list(range(len(self._batches)))
        if self.shuffle:
            generator = torch.Generator()
            generator.manual_seed(self.seed + self.epoch + 1)
            permutation = torch.randperm(
                len(order),
                generator=generator,
            ).tolist()
            order = [order[index] for index in permutation]
        self.epoch += 1

        for batch_index in order:
            yield list(self._batches[batch_index])

    def __len__(self) -> int:
        return len(self._batches)

    def stats(self) -> dict[str, float | int]:
        real_tokens = 0
        padded_tokens = 0
        example_count = 0
        max_batch_examples = 0

        for batch in self._batches:
            lengths = [self.lengths[index] for index in batch]
            batch_examples = len(batch)
            real_tokens += sum(lengths)
            padded_tokens += max(lengths) * batch_examples
            example_count += batch_examples
            max_batch_examples = max(max_batch_examples, batch_examples)

        return {
            "batches": len(self._batches),
            "examples": example_count,
            "mean_batch_examples": example_count / len(self._batches),
            "max_batch_examples": max_batch_examples,
            "real_tokens": real_tokens,
            "padded_tokens": padded_tokens,
            "padding_efficiency": real_tokens / max(1, padded_tokens),
        }


class ProtocolCollator:
    def __init__(self, pad_token_id: int) -> None:
        self.pad_token_id = pad_token_id

    def __call__(self, rows: Sequence[dict[str, Any]]) -> dict[str, torch.Tensor]:
        max_len = max(len(row["input_ids"]) for row in rows)
        input_ids = []
        language_labels = []
        sequence_lengths = []
        for row in rows:
            sequence_length = len(row["input_ids"])
            sequence_lengths.append(sequence_length)
            padding = max_len - sequence_length
            input_ids.append(row["input_ids"] + [self.pad_token_id] * padding)
            language_labels.append(row["language_labels"] + [-100] * padding)

        return {
            "input_ids": torch.tensor(input_ids, dtype=torch.long),
            "language_labels": torch.tensor(language_labels, dtype=torch.long),
            "sequence_lengths": torch.tensor(sequence_lengths, dtype=torch.long),
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
