from __future__ import annotations

import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from murmurations.training.environments.mutations import Verification
from murmurations.training.environments.repositories import RepoCatalog
from murmurations.training.probe_repositories import (
    _append_checkpoint,
    _load_checkpoint,
    probe_repository_catalog,
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
                    "probe_signature": "v2:snapshot",
                },
            )
            self.assertEqual(
                _load_checkpoint(checkpoint, catalog, probe_signature="v2:snapshot"),
                {},
            )

    def test_probe_uses_bounded_concurrency(self) -> None:
        class Runner:
            def __init__(self) -> None:
                self.lock = threading.Lock()
                self.active = 0
                self.max_active = 0

            def provenance(self):
                return {
                    "snapshot": "murmurations-corpus-v1",
                    "snapshot_info": {"id": "snapshot-concurrent"},
                }

            def worker(self):
                return self

            def workspace(
                self,
                _root,
                record,
                *,
                plan_root=None,
                prepare_commands=None,
                sync_local_changes=True,
            ):
                runner = self

                class Workspace:
                    def __enter__(self):
                        with runner.lock:
                            runner.active += 1
                            runner.max_active = max(runner.max_active, runner.active)
                        return self

                    def __exit__(self, exc_type, exc, tb):
                        with runner.lock:
                            runner.active -= 1
                        return False

                    def verify(self, _root, argv, _timeout):
                        time.sleep(0.05)
                        return Verification(
                            True,
                            0,
                            "ok",
                            tuple(argv),
                            backend="daytona",
                            sandbox_id=f"sandbox-{record.name}",
                            sandbox_snapshot="murmurations-corpus-v1",
                        )

                return Workspace()

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rows = []
            for index in range(4):
                repo_dir = root / f"repo-{index}"
                repo_dir.mkdir()
                rows.append(
                    {
                        "name": f"example/repo-{index}",
                        "commit": f"{index + 1:040x}",
                        "license": "MIT",
                        "language": "Python",
                        "path": str(repo_dir),
                    }
                )
            catalog = root / "repos.jsonl"
            catalog.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            runner = Runner()
            with patch(
                "murmurations.training.probe_repositories.detect_test_command",
                return_value=["python3", "-m", "pytest", "-q"],
            ):
                report = probe_repository_catalog(
                    catalog,
                    report_path=root / "probe.json",
                    eligible_catalog_path=root / "eligible.jsonl",
                    sandbox_runner=runner,
                    concurrency=2,
                )

            self.assertEqual(report["completed"], 4)
            self.assertEqual(report["eligible"], 4)
            self.assertEqual(runner.max_active, 2)



if __name__ == "__main__":
    unittest.main()
