from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from murmurations.training.environments.repositories import RepoCatalog
from murmurations.training.probe_repositories import (
    _append_checkpoint,
    _load_checkpoint,
)


class ProbeCheckpointTests(unittest.TestCase):
    def test_checkpoint_round_trip_is_commit_scoped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_dir = root / "repo"
            repo_dir.mkdir()
            catalog_path = root / "repos.jsonl"
            catalog_path.write_text(
                json.dumps(
                    {
                        "name": "example/repo",
                        "commit": "b" * 40,
                        "license": "MIT",
                        "language": "Python",
                        "path": str(repo_dir),
                    }
                ) + "\n",
                encoding="utf-8",
            )
            catalog = RepoCatalog.from_jsonl(catalog_path)
            checkpoint = root / "probe.checkpoint.jsonl"
            _append_checkpoint(
                checkpoint,
                {
                    "repository": "example/repo",
                    "commit": "b" * 40,
                    "passed": True,
                    "probe_signature": "v2:snapshot",
                    "probe_signature": "v2:snapshot",
                },
            )
            loaded = _load_checkpoint(checkpoint, catalog, probe_signature="v2:snapshot")
            self.assertIn(("example/repo", "b" * 40), loaded)

    def test_checkpoint_ignores_stale_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_dir = root / "repo"
            repo_dir.mkdir()
            catalog_path = root / "repos.jsonl"
            catalog_path.write_text(
                json.dumps(
                    {
                        "name": "example/repo",
                        "commit": "b" * 40,
                        "license": "MIT",
                        "language": "Python",
                        "path": str(repo_dir),
                    }
                ) + "\n",
                encoding="utf-8",
            )
            catalog = RepoCatalog.from_jsonl(catalog_path)
            checkpoint = root / "probe.checkpoint.jsonl"
            _append_checkpoint(
                checkpoint,
                {
                    "repository": "example/repo",
                    "commit": "a" * 40,
                    "passed": True,
                },
            )
            self.assertEqual(
                _load_checkpoint(checkpoint, catalog, probe_signature="v2:snapshot"),
                {},
            )


if __name__ == "__main__":
    unittest.main()
