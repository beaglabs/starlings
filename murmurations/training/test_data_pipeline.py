from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from murmurations.training.data import (
    ProtocolCollator,
    ProtocolDataset,
    TokenBudgetBatchSampler,
)


class _Backend:
    def to_str(self) -> str:
        return "fake-byte-tokenizer-v1"


class _Tokenizer:
    def __init__(self) -> None:
        self.backend_tokenizer = _Backend()
        self.eos_token_id = 2
        self.pad_token_id = 0
        self.calls = 0

    def __call__(
        self,
        text: str,
        *,
        add_special_tokens: bool,
        return_offsets_mapping: bool,
    ) -> dict[str, object]:
        del add_special_tokens
        self.calls += 1
        return {
            "input_ids": [10 + (ord(char) % 200) for char in text],
            "offset_mapping": [
                (index, index + 1)
                for index in range(len(text))
            ] if return_offsets_mapping else None,
        }

    def encode(self, text: str, *, add_special_tokens: bool) -> list[int]:
        del add_special_tokens
        self.calls += 1
        if text == "<ACT>":
            return [999]
        return [10 + (ord(char) % 200) for char in text]


def _row(context: str, target: str = "") -> dict[str, object]:
    return {
        "context": context,
        "language_target": target,
        "operation": "NOOP",
        "argument": {
            "kind": "NONE",
            "text": None,
            "operator": None,
            "parents": [],
            "confidence_permille": 1000,
        },
    }


class ProtocolDataPipelineTests(unittest.TestCase):
    def test_pretokenized_cache_avoids_tokenization_on_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "rows.jsonl"
            source.write_text(
                json.dumps(_row("alpha", "beta")) + "\n"
                + json.dumps(_row("gamma", "delta")) + "\n",
                encoding="utf-8",
            )
            cache = root / "tokens.pt"

            first_tokenizer = _Tokenizer()
            first = ProtocolDataset(
                source,
                first_tokenizer,
                128,
                pretokenize=True,
                cache_path=cache,
            )
            self.assertEqual(len(first), 2)
            self.assertIsNotNone(first.lengths)
            self.assertGreater(first_tokenizer.calls, 0)
            calls_after_build = first_tokenizer.calls
            _ = first[0]
            self.assertEqual(first_tokenizer.calls, calls_after_build)
            self.assertTrue(cache.exists())

            second_tokenizer = _Tokenizer()
            second = ProtocolDataset(
                source,
                second_tokenizer,
                128,
                pretokenize=True,
                cache_path=cache,
            )
            self.assertEqual(len(second), 2)
            self.assertEqual(second_tokenizer.calls, 0)
            _ = second[1]
            self.assertEqual(second_tokenizer.calls, 0)
            self.assertEqual(first.lengths, second.lengths)

    def test_token_budget_batches_bound_padded_compute(self) -> None:
        lengths = [100, 110, 120, 800, 810, 820, 1600, 1700]
        sampler = TokenBudgetBatchSampler(
            lengths,
            max_tokens=2048,
            max_examples=8,
            bucket_size=len(lengths),
            shuffle=False,
        )

        flattened: list[int] = []
        for batch in sampler:
            flattened.extend(batch)
            padded_tokens = len(batch) * max(lengths[index] for index in batch)
            self.assertLessEqual(padded_tokens, 2048)

        self.assertEqual(sorted(flattened), list(range(len(lengths))))
        stats = sampler.stats()
        self.assertEqual(stats["examples"], len(lengths))
        self.assertLessEqual(stats["max_batch_examples"], 8)
        self.assertGreater(stats["padding_efficiency"], 0.9)

    def test_collator_reports_real_sequence_lengths(self) -> None:
        collator = ProtocolCollator(pad_token_id=0)
        rows = [
            {
                "input_ids": [1, 2, 3],
                "language_labels": [-100, 2, 3],
                "control_position": 0,
                "operation_label": 0,
                "argument_kind_label": 0,
                "argument_start_label": -100,
                "argument_end_label": -100,
                "operator_pointer_label": -100,
                "parent_pointer_labels": [-100, -100, -100, -100],
                "parent_count_label": 0,
                "confidence_target": 1.0,
                "confidence_mask": False,
            },
            {
                "input_ids": [4, 5],
                "language_labels": [-100, 5],
                "control_position": 0,
                "operation_label": 0,
                "argument_kind_label": 0,
                "argument_start_label": -100,
                "argument_end_label": -100,
                "operator_pointer_label": -100,
                "parent_pointer_labels": [-100, -100, -100, -100],
                "parent_count_label": 0,
                "confidence_target": 1.0,
                "confidence_mask": False,
            },
        ]

        batch = collator(rows)

        self.assertEqual(batch["input_ids"].shape, (2, 3))
        self.assertEqual(batch["sequence_lengths"].tolist(), [3, 2])


if __name__ == "__main__":
    unittest.main()
