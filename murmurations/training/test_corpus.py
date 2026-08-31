from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from murmurations.training.corpus import validate_corpus_shard
from murmurations.training.environments.mutations import mutation_fingerprint
from murmurations.training.build_shard import _select_stratified
from murmurations.training.generate_trajectories import _schedule
from murmurations.training.environments.repositories import RepoCatalog, RepoRecord


class CorpusTests(unittest.TestCase):
    def test_balanced_schedule_requests_each_repository(self) -> None:
        catalog = RepoCatalog(
            [
                RepoRecord("a", "fixture-a", "MIT", path="."),
                RepoRecord("b", "fixture-b", "MIT", path="."),
            ]
        )
        scheduled = _schedule(
            catalog,
            episodes=None,
            episodes_per_repo=3,
            seed=17,
        )
        self.assertEqual([item[0].name for item in scheduled], ["a", "a", "a", "b", "b", "b"])
        self.assertEqual([item[2] for item in scheduled], [0, 1, 2, 0, 1, 2])

    def test_stratified_probe_spans_languages(self) -> None:
        catalog = RepoCatalog(
            [
                RepoRecord("py-a", "fixture-a", "MIT", path=".", language="Python"),
                RepoRecord("py-b", "fixture-b", "MIT", path=".", language="Python"),
                RepoRecord("rust-a", "fixture-c", "MIT", path=".", language="Rust"),
                RepoRecord("go-a", "fixture-d", "MIT", path=".", language="Go"),
            ]
        )
        selected = _select_stratified(catalog, 3)
        self.assertEqual(
            {record.language for record in selected},
            {"Go", "Python", "Rust"},
        )

    def test_remote_repository_requires_full_commit_sha(self) -> None:
        with self.assertRaisesRegex(ValueError, "40-hex"):
            RepoRecord(
                "remote",
                "main",
                "MIT",
                url="https://github.com/example/project.git",
            )

    def test_mutation_fingerprint_changes_with_location(self) -> None:
        one = mutation_fingerprint("src/a.py", 3, "eq_to_ne", "a == b", "a != b")
        two = mutation_fingerprint("src/a.py", 4, "eq_to_ne", "a == b", "a != b")
        self.assertNotEqual(one, two)

    def test_qa_rejects_repository_split_leakage(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            catalog = root / "catalog.jsonl"
            catalog.write_text(
                json.dumps(
                    {
                        "name": "fixture",
                        "commit": "fixture-v1",
                        "license": "MIT",
                        "language": "python",
                        "path": str(root),
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            repo = RepoCatalog.from_jsonl(catalog).records[0]
            episode_path = root / "episodes.jsonl"
            episode_path.write_text(
                json.dumps(
                    {
                        "repository": {
                            "name": repo.name,
                            "identity": repo.identity,
                            "language": repo.language,
                            "license": repo.license,
                        },
                        "mutation": {
                            "kind": "eq_to_ne",
                            "fingerprint": "b3:" + "01" * 32,
                        },
                        "events": [],
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            def write_rows(path: Path) -> None:
                path.write_text(
                    json.dumps(
                        {
                            "context": "x",
                            "language_target": "",
                            "operation": "NOOP",
                            "argument": {"kind": "NONE"},
                            "provenance": {
                                "repository_identity": repo.identity,
                                "repository": repo.name,
                            },
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )

            code_train = root / "code-train.jsonl"
            code_eval = root / "code-eval.jsonl"
            traj_train = root / "traj-train.jsonl"
            traj_eval = root / "traj-eval.jsonl"
            for path in (code_train, code_eval, traj_train, traj_eval):
                write_rows(path)

            report = validate_corpus_shard(
                catalog_path=catalog,
                episodes_path=episode_path,
                code_train_path=code_train,
                code_eval_path=code_eval,
                trajectory_train_path=traj_train,
                trajectory_eval_path=traj_eval,
                generation_report={"success_rate": 1.0},
                quality={
                    "min_catalog_repositories": 1,
                    "min_generation_success_rate": 0.0,
                    "min_dynamic_repositories": 1,
                    "min_unique_mutations": 1,
                    "min_code_rows": 1,
                    "min_trajectory_rows": 1,
                },
            )
            self.assertFalse(report["passed"])
            self.assertFalse(report["gates"]["no_split_leakage"])
            self.assertEqual(report["split_leakage"], [repo.identity])


if __name__ == "__main__":
    unittest.main()
