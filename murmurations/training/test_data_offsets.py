from __future__ import annotations

import unittest

from murmurations.training.data import _char_span_to_token_span


class DataOffsetTests(unittest.TestCase):
    def test_target_can_start_inside_leading_whitespace_token(self) -> None:
        context = "X search source for return"
        # A byte-level tokenizer may attach the preceding space to the first
        # token of the target. The pointer should still ground to that token.
        offsets = [(0, 1), (1, 8), (8, 15), (15, 19), (19, 26)]
        self.assertEqual(
            _char_span_to_token_span(
                context,
                offsets,
                "search source for return",
                "argument text",
            ),
            (1, 4),
        )

    def test_missing_target_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "not found in context"):
            _char_span_to_token_span(
                "alpha beta",
                [(0, 5), (5, 10)],
                "gamma",
                "argument text",
            )


if __name__ == "__main__":
    unittest.main()
