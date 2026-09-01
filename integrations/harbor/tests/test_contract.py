from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import unittest

PROJECT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))

from starlings_harbor.inference import _parse_decision, history_text
from starlings_harbor.wire import b64encode_text


class HostedHarborContractTests(unittest.TestCase):
    def test_manifests_are_three_distinct_acp_conditions(self) -> None:
        expected = {
            "harbor-agent-baseline.json": "starlings_harbor.baseline",
            "harbor-agent-starlings.json": "starlings_harbor.starlings",
            "harbor-agent-deterministic.json": "starlings_harbor.deterministic",
        }
        for name, module in expected.items():
            manifest = json.loads((PROJECT / name).read_text())
            self.assertEqual(manifest["schema_version"], 1)
            self.assertEqual(manifest["protocol"], "acp")
            self.assertEqual(manifest["runtime"]["kind"], "python-uv")
            self.assertEqual(manifest["runtime"]["python"], "3.12")
            self.assertEqual(manifest["runtime"]["project"], "integrations/harbor")
            self.assertEqual(manifest["runtime"]["entrypoint"], ["python", "-m", module])

    def test_shared_model_decision_parser(self) -> None:
        shell = _parse_decision('{"type":"shell","command":"pytest -q"}')
        final = _parse_decision('{"type":"final","answer":"done"}')
        self.assertEqual((shell.kind, shell.value), ("shell", "pytest -q"))
        self.assertEqual((final.kind, final.value), ("final", "done"))

    def test_shared_history_is_bounded(self) -> None:
        history = [
            {"command": f"cmd-{i}", "output": "x" * 10000, "exit_code": 0}
            for i in range(20)
        ]
        encoded = history_text(history)
        self.assertLessEqual(len(encoded), 24000)
        decoded = json.loads(encoded)
        self.assertLessEqual(len(decoded), 8)
        self.assertEqual(decoded[-1]["command"], "cmd-19")

    def test_deterministic_operator_uses_canonical_wire(self) -> None:
        script = PROJECT / "packs/deterministic/operators/deterministic_planner.py"
        request = (
            "STARLINGS/1 REQUEST\n"
            "operator=7\n"
            "round=1\n"
            f"var=1,1,t:{b64encode_text('inspect task')}\n"
            f"var=2,1,t:{b64encode_text('[]')}\n"
            "provide_var=3\n"
            "provide_var=4\n"
            "END\n"
        )
        result = subprocess.run(
            [sys.executable, str(script)],
            input=request,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            cwd=PROJECT,
        )
        self.assertTrue(result.stdout.startswith("STARLINGS/1 RESPONSE\noperator=7\n"))
        self.assertIn("claim=3,3,1000,7,t:", result.stdout)
        self.assertTrue(result.stdout.endswith("END\n"))


if __name__ == "__main__":
    unittest.main()
