from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from murmurations.training.environments.episodes import make_oracle_bootstrap_episode
from murmurations.training.environments.mutations import inject_verified_mutation
from murmurations.training.environments.repositories import RepoRecord
from murmurations.training.materialize import materialize_episode
from murmurations.training.operators import default_operator_registry


class DataPipelineTests(unittest.TestCase):
    def test_verified_mutation_episode_materializes_operator_supervision(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "clean"
            root.mkdir()
            (root / "src").mkdir()
            (root / "tests").mkdir()
            (root / "src" / "logic.py").write_text(
                "def same(a, b):\n    return a == b\n", encoding="utf-8"
            )
            (root / "tests" / "test_logic.py").write_text(
                "import unittest\n"
                "from src.logic import same\n\n"
                "class T(unittest.TestCase):\n"
                "    def test_same(self):\n"
                "        self.assertTrue(same(3, 3))\n"
                "        self.assertFalse(same(3, 4))\n",
                encoding="utf-8",
            )
            (root / "src" / "__init__.py").write_text("", encoding="utf-8")

            verifier = ["python3", "-m", "unittest", "discover", "-s", "tests"]
            workspace = Path(tmp) / "work"
            mutation = inject_verified_mutation(
                root, workspace, verifier, seed=2, timeout_seconds=20
            )
            self.assertFalse(mutation.broken_verification.passed)

            repo = RepoRecord(
                name="fixture",
                commit="fixture-v1",
                license="MIT",
                path=str(root),
                language="python",
            )
            registry = default_operator_registry(workspace)
            # unittest-only fixtures have no pyproject; register tests explicitly
            if "repo.tests" not in [d.name for d in registry.descriptors()]:
                from murmurations.training.operator_retrieval import OperatorDescriptor
                registry.register(
                    OperatorDescriptor(
                        "repo.tests",
                        "Run repository tests",
                        "subprocess",
                        tags=("test", "verify"),
                        requires=("repo",),
                    )
                )

            # make_oracle_bootstrap_episode uses execute_operator, whose detector
            # recognizes the tests/ fallback added by the training adapter.
            episode = make_oracle_bootstrap_episode(repo, workspace, mutation, registry)
            rows = materialize_episode(episode.record())
            execute_rows = [row for row in rows if row["operation"] == "EXECUTE"]
            self.assertTrue(execute_rows)
            self.assertTrue(any(row["argument"]["operator"] == "repo.tests" for row in execute_rows))
            for row in execute_rows:
                operator = row["argument"]["operator"]
                if operator is not None:
                    self.assertIn(f"<OPERATOR>{operator}</OPERATOR>", row["context"])


if __name__ == "__main__":
    unittest.main()
