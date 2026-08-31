from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from murmurations.training.environments.episodes import EpisodeBuilder
from murmurations.training.operator_retrieval import OperatorDescriptor, OperatorRegistry
from murmurations.utils.protocol import ArgumentKind, Operation
from murmurations.training.operators import default_operator_registry, execute_operator


class OperatorRetrievalTests(unittest.TestCase):
    def test_retrieval_is_bounded_and_semantic(self) -> None:
        registry = OperatorRegistry(
            [
                OperatorDescriptor(
                    "symbol.references",
                    "Find references to a source symbol",
                    "python",
                    tags=("ast", "symbol"),
                ),
                OperatorDescriptor(
                    "repo.tests",
                    "Run repository tests",
                    "subprocess",
                    tags=("test",),
                    cost_millis=100,
                ),
            ]
        )
        hits = registry.retrieve("find symbol references", top_k=1)
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0].descriptor.name, "symbol.references")

    def test_unmet_requirements_are_not_retrieved(self) -> None:
        registry = OperatorRegistry(
            [OperatorDescriptor("repo.tests", "Run tests", "subprocess", requires=("repo",))]
        )
        self.assertEqual(registry.retrieve("tests", available=()), [])
        self.assertEqual(
            registry.retrieve("tests", available=("repo",))[0].descriptor.name,
            "repo.tests",
        )

    def test_episode_builder_rejects_oracle_operator_not_retrieved(self) -> None:
        registry = OperatorRegistry(
            [
                OperatorDescriptor(
                    "repo.tests",
                    "Run repository tests",
                    "subprocess",
                    tags=("test",),
                    requires=("repo",),
                )
            ]
        )
        builder = EpisodeBuilder(registry)
        with self.assertRaisesRegex(ValueError, "operator retrieval miss"):
            builder.add(
                Operation.EXECUTE,
                ArgumentKind.ACTION,
                "run repository tests",
                grounding="run repository tests",
                retrieval_query="banana unrelated capability",
                operator_ref="repo.tests",
            )

    def test_terminal_backed_package_type_and_docs_operators(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pyproject.toml").write_text(
                "[project]\n"
                "name = \"fixture-package\"\n"
                "version = \"1.0.0\"\n"
                "dependencies = [\"example>=1\"]\n",
                encoding="utf-8",
            )
            (root / "sample.py").write_text(
                "def add(a, b):\n"
                "    \"\"\"Add two values.\"\"\"\n"
                "    return a + b\n",
                encoding="utf-8",
            )

            registry = default_operator_registry(root)
            names = {descriptor.name for descriptor in registry.descriptors()}
            self.assertIn("type.check", names)
            self.assertIn("package.metadata", names)
            self.assertIn("docs.lookup", names)

            package = execute_operator("package.metadata", "", root)
            self.assertTrue(package.ok, package.text)
            self.assertIn("fixture-package", package.text)
            self.assertTrue(package.metadata.get("argv"))

            checked = execute_operator("type.check", "", root)
            self.assertTrue(checked.ok, checked.text)
            self.assertTrue(checked.metadata.get("argv"))

            docs = execute_operator("docs.lookup", "sample", root)
            self.assertTrue(docs.ok, docs.text)
            self.assertIn("add", docs.text)
            self.assertTrue(docs.metadata.get("argv"))

    def test_remote_python_operator_preserves_venv_argv(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pyproject.toml").write_text(
                "[project]\nname='fixture'\nversion='1.0.0'\n",
                encoding="utf-8",
            )
            seen: list[list[str]] = []

            def runner(_root, argv, _timeout):
                from murmurations.training.operators import OperatorResult
                seen.append(list(argv))
                return OperatorResult(True, "ok", exit_code=0, metadata={"argv": list(argv)})

            result = execute_operator(
                "package.metadata",
                "",
                root,
                command_runner=runner,
            )
            self.assertTrue(result.ok)
            self.assertEqual(seen[0][0], ".murmurations-venv/bin/python3")

    def test_python_ast_and_search_adapters_execute(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "sample.py").write_text(
                "def add(a, b):\n    return a + b\n", encoding="utf-8"
            )
            registry = default_operator_registry(root)
            self.assertEqual(registry.retrieve("search source", available=("repo",))[0].descriptor.name, "repo.search")

            search = execute_operator("repo.search", "add", root)
            self.assertTrue(search.ok)
            self.assertIn("sample.py", search.text)

            parsed = execute_operator("ast.python.symbols", "sample.py::add", root)
            self.assertTrue(parsed.ok)
            self.assertIn("FunctionDef:add", parsed.text)


if __name__ == "__main__":
    unittest.main()
