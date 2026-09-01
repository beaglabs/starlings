from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from murmurations.training.environments.repositories import RepoCatalog
from murmurations.training.generate_trajectories import (
    _generation_signature,
    _load_journal,
)


class GenerationResumeTests(unittest.TestCase):
    def test_generation_journal_restores_exact_progress_and_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_root = root / "repo"
            repo_root.mkdir()
            catalog_path = root / "catalog.jsonl"
            catalog_path.write_text(
                json.dumps(
                    {
                        "name": "example/repo",
                        "commit": "fixture-v1",
                        "license": "MIT",
                        "language": "Python",
                        "path": str(repo_root),
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            catalog = RepoCatalog.from_jsonl(catalog_path)
            signature = _generation_signature(
                catalog,
                seed=17,
                max_attempts=48,
                generation_retries=4,
                enrichment_operators=(),
                max_enrichment_calls=0,
                mode={
                    "kind": "targets",
                    "max_requests_per_repo": 80,
                    "max_successes_per_repo": 50,
                    "burst_per_repo": 4,
                },
            )

            output = root / "episodes.jsonl"
            output.write_text(
                json.dumps(
                    {
                        "repository": {"name": "example/repo"},
                        "mutation": {
                            "path": "sample.py",
                            "line": 1,
                            "kind": "eq_to_ne",
                            "original_line": "a == b\n",
                            "mutated_line": "a != b\n",
                        },
                        "events": [
                            {
                                "frame": {"operator_ref": "type.check"},
                                "environment": {"argv": ["python3", "-m", "compileall"]},
                            }
                        ],
                        "generation": {
                            "signature": signature,
                            "repo_episode_index": 0,
                            "global_episode_index": 0,
                        },
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            failures = root / "failures.jsonl"
            failures.write_text(
                json.dumps(
                    {
                        "generation_signature": signature,
                        "repository": "example/repo",
                        "repo_episode_index": 1,
                        "global_episode_index": 1,
                        "error": "fixture failure",
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )

            (
                used,
                repo_stats,
                next_local,
                processed,
                next_global,
                metrics,
            ) = _load_journal(
                output,
                failures,
                signature=signature,
                catalog=catalog,
            )

            self.assertEqual(metrics["requested"], 2)
            self.assertEqual(metrics["written"], 1)
            self.assertEqual(metrics["failed"], 1)
            self.assertEqual(metrics["trajectory_rows"], 1)
            self.assertEqual(metrics["terminal_operator_events"], 1)
            self.assertEqual(metrics["terminal_operator_types"], {"type.check"})
            self.assertEqual(metrics["terminal_argv_events"], 1)
            self.assertEqual(metrics["dynamic_repositories"], {"example/repo"})
            self.assertEqual(repo_stats["example/repo"], {
                "requested": 2,
                "written": 1,
                "failed": 1,
            })
            self.assertEqual(next_local["example/repo"], 2)
            self.assertEqual(next_global, 2)
            self.assertEqual(processed, {("example/repo", 0), ("example/repo", 1)})
            self.assertEqual(len(used["example/repo"]), 1)

    def test_generation_journal_repairs_truncated_tail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_root = root / "repo"
            repo_root.mkdir()
            catalog_path = root / "catalog.jsonl"
            catalog_path.write_text(
                json.dumps(
                    {
                        "name": "example/repo",
                        "commit": "fixture-v1",
                        "license": "MIT",
                        "language": "Python",
                        "path": str(repo_root),
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            catalog = RepoCatalog.from_jsonl(catalog_path)
            signature = _generation_signature(
                catalog,
                seed=17,
                max_attempts=48,
                generation_retries=4,
                enrichment_operators=(),
                max_enrichment_calls=0,
                mode={"kind": "fixed", "episodes": None, "episodes_per_repo": 1},
            )
            output = root / "episodes.jsonl"
            output.write_text('{"partial":', encoding="utf-8")
            failures = root / "failures.jsonl"
            failures.write_text("", encoding="utf-8")

            _, _, _, processed, next_global, metrics = _load_journal(
                output,
                failures,
                signature=signature,
                catalog=catalog,
            )

            self.assertEqual(output.read_text(encoding="utf-8"), "")
            self.assertEqual(processed, set())
            self.assertEqual(next_global, 0)
            self.assertEqual(metrics["requested"], 0)


if __name__ == "__main__":
    unittest.main()
