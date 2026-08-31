from __future__ import annotations

import tempfile
from pathlib import Path
import unittest

from murmurations.training.zviz import ZVizCorpusRunner


class ZVizCorpusRunnerTests(unittest.TestCase):
    def test_oci_config_preserves_argv_and_mounts_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle = root / "bundle"
            (bundle / "rootfs").mkdir(parents=True)
            workspace = root / "repo"
            workspace.mkdir()
            runner = ZVizCorpusRunner(
                binary="zviz",
                bundle=bundle,
                state_dir=root / "state",
            )
            config = runner.render_oci_config(
                workspace,
                ["cargo", "test", "--quiet"],
            )
            self.assertEqual(
                config["process"]["args"],
                ["cargo", "test", "--quiet"],
            )
            self.assertEqual(config["process"]["cwd"], "/tmp/work")
            self.assertTrue(config["root"]["readonly"])
            self.assertEqual(config["mounts"][0]["source"], str(workspace.resolve()))
            self.assertEqual(config["mounts"][0]["destination"], "/tmp/work")
            self.assertIn("rw", config["mounts"][0]["options"])

    def test_workload_exit_code_is_bound_to_container_identity(self) -> None:
        output = (
            "repository says exit_code: 99\n"
            "[1700000000] [INFO] Container wrong started (pid: 1, exit_code: 5)\n"
            "[1700000001] [INFO] Container expected started (pid: 2, exit_code: 7)\n"
        )
        self.assertEqual(
            ZVizCorpusRunner._workload_exit_code(output, "expected"),
            7,
        )
        self.assertEqual(
            ZVizCorpusRunner._workload_exit_code(output, "missing"),
            None,
        )
        self.assertEqual(
            ZVizCorpusRunner._clean_output(output),
            "repository says exit_code: 99",
        )

    def test_absolute_host_python_is_normalized_for_rootfs(self) -> None:
        self.assertEqual(
            ZVizCorpusRunner._portable_argv(
                ["/Library/Frameworks/Python.framework/Versions/3.14/bin/python3", "-m", "pytest"]
            ),
            ("python3", "-m", "pytest"),
        )


if __name__ == "__main__":
    unittest.main()
