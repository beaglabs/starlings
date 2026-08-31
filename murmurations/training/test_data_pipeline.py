from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from murmurations.training.environments.episodes import make_oracle_bootstrap_episode
from murmurations.training.environments.mutations import inject_verified_mutation, verify
from murmurations.training.environments.repositories import RepoRecord
from murmurations.training.materialize import materialize_episode
from murmurations.training.operators import default_operator_registry


class DataPipelineTests(unittest.TestCase):
    def test_verify_does_not_reuse_stale_python_bytecode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "src").mkdir()
            (root / "tests").mkdir()
            (root / "src" / "__init__.py").write_text("", encoding="utf-8")
            source = root / "src" / "logic.py"
            source.write_text(
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
            verifier = [
                sys.executable,
                "-m",
                "unittest",
                "discover",
                "-s",
                "tests",
            ]

            original_stat = source.stat()
            warmed = subprocess.run(
                verifier,
                cwd=root,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
            self.assertEqual(warmed.returncode, 0, warmed.stdout)
            self.assertTrue(any(root.rglob("*.pyc")))

            # Same-size mutation + restored mtime makes timestamp/size pyc
            # validation accept the stale clean bytecode unless verify purges it.
            source.write_text(
                "def same(a, b):\n    return a != b\n", encoding="utf-8"
            )
            os.utime(
                source,
                ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns),
            )

            broken = verify(root, verifier, timeout_seconds=20)
            self.assertFalse(broken.passed)
            self.assertFalse(any(root.rglob("*.pyc")))

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
            (root / "pyproject.toml").write_text(
                "[project]\nname = \"fixture\"\nversion = \"1.0.0\"\n",
                encoding="utf-8",
            )

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
            episode = make_oracle_bootstrap_episode(
                repo,
                workspace,
                mutation,
                registry,
                episode_seed=17,
                enrichment_operators=("package.metadata",),
                max_enrichment_calls=1,
            )
            rows = materialize_episode(episode.record())
            execute_rows = [row for row in rows if row["operation"] == "EXECUTE"]
            self.assertTrue(execute_rows)
            self.assertTrue(any(row["argument"]["operator"] == "repo.tests" for row in execute_rows))
            self.assertTrue(
                any(
                    row["argument"]["operator"] == "package.metadata"
                    for row in execute_rows
                )
            )
            for row in execute_rows:
                operator = row["argument"]["operator"]
                if operator is not None:
                    self.assertIn(f"<OPERATOR>{operator}</OPERATOR>", row["context"])

            # Terminal-backed semantic operators also expose their concrete argv
            # to subsequent state, so the language stream can learn command
            # implementations without coupling operator identity to one backend.
            self.assertTrue(
                any("ARGV[" in row["context"] for row in rows),
                "expected concrete terminal argv evidence in materialized state",
            )


if __name__ == "__main__":
    unittest.main()
