from __future__ import annotations

import tempfile
from pathlib import Path
import unittest

from murmurations.training.materialize_code import _files, _windows


class MaterializeCodeTests(unittest.TestCase):
    def test_files_are_sorted_by_repository_relative_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "z.py").write_text("z = 1\n", encoding="utf-8")
            (root / "a.py").write_text("a = 1\n", encoding="utf-8")
            (root / "nested").mkdir()
            (root / "nested" / "m.py").write_text("m = 1\n", encoding="utf-8")

            paths = [path.relative_to(root).as_posix() for path in _files(root)]

        self.assertEqual(paths, ["a.py", "nested/m.py", "z.py"])

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
