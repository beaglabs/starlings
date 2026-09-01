from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from murmurations.training.environments.mutations import (
    MutationCandidate,
    Verification,
    infer_targeted_test_argv,
    partition_mutation_candidates,
    repair_mutation,
)
from murmurations.training.environments.repositories import RepoRecord
from murmurations.training.generate_trajectories import _generate_repo_burst
from murmurations.training.propose_mutations import _validated_candidates


class HybridMutationCandidateTests(unittest.TestCase):
    def test_fingerprint_partitions_are_disjoint_and_complete(self) -> None:
        candidates = [
            MutationCandidate(
                relative_path="sample.py",
                line_number=index + 1,
                kind="fixture",
                original_line=f"value_{index} == expected\n",
                mutated_line=f"value_{index} != expected\n",
            )
            for index in range(40)
        ]

        partitions = [
            partition_mutation_candidates(
                candidates,
                partition_id=partition,
                partition_count=4,
            )
            for partition in range(4)
        ]
        fingerprints = [
            {candidate.fingerprint for candidate in partition}
            for partition in partitions
        ]

        self.assertEqual(
            set().union(*fingerprints),
            {candidate.fingerprint for candidate in candidates},
        )
        for left in range(len(fingerprints)):
            for right in range(left + 1, len(fingerprints)):
                self.assertTrue(fingerprints[left].isdisjoint(fingerprints[right]))

    def test_llm_candidate_validation_preserves_exact_source_structure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "sample.py"
            path.write_text(
                "def ready(value):\n"
                "    return value == 1\n",
                encoding="utf-8",
            )

            accepted = _validated_candidates(
                root=root,
                path=path,
                payload={
                    "candidates": [
                        {
                            "line": 2,
                            "mutated_line": "    return value != 1",
                            "kind": "wrong_condition",
                        }
                    ]
                },
            )
            rejected = _validated_candidates(
                root=root,
                path=path,
                payload={
                    "candidates": [
                        {
                            "line": 2,
                            "mutated_line": "return value != 1",
                            "kind": "destroy_indentation",
                        }
                    ]
                },
            )

            self.assertEqual(len(accepted), 1)
            self.assertEqual(accepted[0].source, "llm")
            self.assertEqual(accepted[0].original_line, "    return value == 1\n")
            self.assertEqual(accepted[0].mutated_line, "    return value != 1\n")
            self.assertEqual(rejected, [])

    def test_targeted_pytest_command_is_derived_not_model_supplied(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pkg").mkdir()
            (root / "pkg" / "cache.py").write_text(
                "def ready(value):\n    return value == 1\n",
                encoding="utf-8",
            )
            (root / "tests").mkdir()
            (root / "tests" / "test_cache.py").write_text(
                "def test_cache():\n    assert True\n",
                encoding="utf-8",
            )
            candidate = MutationCandidate(
                relative_path="pkg/cache.py",
                line_number=2,
                kind="wrong_boundary",
                original_line="    return value == 1\n",
                mutated_line="    return value != 1\n",
                source="llm",
            )

            argv = infer_targeted_test_argv(
                root,
                candidate,
                [".murmurations-venv/bin/python3", "-m", "pytest", "-q"],
            )

            self.assertEqual(
                argv,
                (
                    ".murmurations-venv/bin/python3",
                    "-m",
                    "pytest",
                    "-q",
                    "tests/test_cache.py",
                ),
            )


class _Episode:
    def __init__(self, repo: RepoRecord, mutation) -> None:
        self.repo = repo
        self.mutation = mutation

    def record(self):
        return {
            "repository": {
                "name": self.repo.name,
                "language": self.repo.language,
            },
            "mutation": {
                "path": self.mutation.relative_path,
                "line": self.mutation.line_number,
                "kind": self.mutation.kind,
                "original_line": self.mutation.original_line,
                "mutated_line": self.mutation.mutated_line,
            },
            "events": [],
        }


class _Remote:
    def __init__(self) -> None:
        self.verify_calls = 0

    def verify(self, workspace, _argv, _timeout_seconds):
        self.verify_calls += 1
        text = (Path(workspace) / "sample.py").read_text(encoding="utf-8")
        passed = "!=" not in text
        return Verification(
            passed=passed,
            exit_code=0 if passed else 1,
            output="ok" if passed else "fixture verifier failure",
            argv=("python3", "-m", "unittest"),
            backend="daytona",
            sandbox_id="fixture-sandbox",
            sandbox_snapshot="fixture-snapshot",
        )

    def run_operator(self, workspace, argv, timeout_seconds):
        result = self.verify(workspace, argv, timeout_seconds)

        class _Result:
            ok = result.passed
            text = result.output
            exit_code = result.exit_code
            metadata = {
                "argv": list(result.argv),
                "sandbox_backend": "daytona",
                "sandbox_id": result.sandbox_id,
                "sandbox_snapshot": result.sandbox_snapshot,
            }

        return _Result()


class _Runner:
    def __init__(self) -> None:
        self.entries = 0
        self.remote = _Remote()

    def worker(self):
        return self

    @contextmanager
    def workspace(self, *_args, **_kwargs):
        self.entries += 1
        yield self.remote


class PersistentBurstTests(unittest.TestCase):
    def test_burst_prepares_one_workspace_and_reuses_clean_verification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            source.mkdir()
            (source / "sample.py").write_text(
                "def first(a, b):\n"
                "    return a == b\n\n"
                "def second(a, b):\n"
                "    return a == b\n",
                encoding="utf-8",
            )
            tests = source / "tests"
            tests.mkdir()
            (tests / "test_sample.py").write_text(
                "import unittest\n"
                "class SampleTests(unittest.TestCase):\n"
                "    def test_fixture(self):\n"
                "        self.assertTrue(True)\n",
                encoding="utf-8",
            )
            repo = RepoRecord(
                "fixture/repo",
                "fixture-v1",
                "MIT",
                path=str(source),
                language="Python",
            )
            runner = _Runner()

            def fake_episode(repo, workspace, mutation, _registry, **_kwargs):
                repair_mutation(workspace, mutation)
                return _Episode(repo, mutation)

            with patch(
                "murmurations.training.generate_trajectories.make_oracle_bootstrap_episode",
                side_effect=fake_episode,
            ):
                outcomes = _generate_repo_burst(
                    repo=repo,
                    slots=[(0, 0), (1, 1)],
                    excluded_fingerprints=set(),
                    source=source,
                    work_root=root / "work",
                    repo_index=0,
                    seed=17,
                    timeout_seconds=30,
                    max_attempts=16,
                    generation_retries=1,
                    enrichment_operators=(),
                    max_enrichment_calls=0,
                    sandbox_runner=runner,
                    signature="fixture-signature",
                )

            self.assertEqual(runner.entries, 1)
            self.assertEqual(len(outcomes), 2)
            self.assertTrue(all(outcome.record is not None for outcome in outcomes))
            self.assertEqual(
                len({outcome.raw_fingerprint for outcome in outcomes}),
                2,
            )
            # One clean verification plus one broken verification per accepted
            # candidate. The clean pass is not repeated for the second slot.
            self.assertEqual(runner.remote.verify_calls, 3)


if __name__ == "__main__":
    unittest.main()
