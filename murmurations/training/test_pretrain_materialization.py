from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from murmurations.training.materialize_code import materialize_repository_code


class PretrainMaterializationTests(unittest.TestCase):
    def test_repository_code_windows_are_provenance_labeled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            root.mkdir()
            (root / "module.py").write_text(
                ("def transform(value):\n    return value + 1\n\n" * 20),
                encoding="utf-8",
            )
            catalog = Path(tmp) / "repos.jsonl"
            catalog.write_text(
                json.dumps(
                    {
                        "name": "fixture",
                        "path": str(root),
                        "commit": "fixture-v1",
                        "license": "MIT",
                        "language": "python",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            train = Path(tmp) / "train.jsonl"
            evaluation = Path(tmp) / "eval.jsonl"
            counts = materialize_repository_code(
                catalog,
                train,
                evaluation,
                eval_fraction=0.0,
                chunk_chars=400,
            )
            self.assertGreater(counts["train_rows"], 0)
            row = json.loads(train.read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(row["operation"], "NOOP")
            self.assertEqual(row["argument"]["kind"], "NONE")
            self.assertEqual(row["provenance"]["source_type"], "repository_code")


if __name__ == "__main__":
    unittest.main()
