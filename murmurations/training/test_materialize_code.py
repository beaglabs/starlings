from __future__ import annotations

import unittest

from murmurations.training.materialize_code import _windows


class MaterializeCodeTests(unittest.TestCase):
    def test_windows_respect_utf8_byte_budget(self) -> None:
        text = ("def f():\n    return 'λ界🙂'\n" * 1000)
        windows = list(
            _windows(
                text,
                6000,
                max_chunk_bytes=3500,
            )
        )

        self.assertGreater(len(windows), 1)
        for prefix, continuation in windows:
            payload = prefix + continuation
            self.assertLessEqual(len(payload.encode("utf-8")), 3500)
            self.assertTrue(prefix)
            self.assertTrue(continuation)


if __name__ == "__main__":
    unittest.main()
