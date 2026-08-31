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

    def test_workload_exit_code_is_taken_from_zviz_runtime_log(self) -> None:
        output = (
            "[1700000000] [INFO] Starting container\n"
            "compiler output\n"
            "[1700000001] [INFO] Container exited with code 7\n"
            "[1700000001] [INFO] Container x started (pid: 1, exit_code: 7)\n"
        )
        self.assertEqual(ZVizCorpusRunner._workload_exit_code(output), 7)
        self.assertEqual(ZVizCorpusRunner._clean_output(output), "compiler output")


if __name__ == "__main__":
    unittest.main()
