import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.abspath(os.path.dirname(__file__))
sys.path.insert(0, HERE)

import starlings_operator as wire


class WireTests(unittest.TestCase):
    def test_decode_encode_roundtrip_shape(self):
        request = (
            "STARLINGS/1 REQUEST\n"
            "operator=10\n"
            "round=3\n"
            "var=1,1,i:7\n"
            "inv=4,1\n"
            "END\n"
        )
        ctx = wire.decode_request(request)
        self.assertEqual(ctx["operator"], 10)
        self.assertEqual(ctx["round"], 3)
        self.assertEqual(ctx["variables"][1]["value"], 7)
        self.assertEqual(ctx["invariants"][4], 1)

        response = wire.encode_response(
            10,
            {"claims": [wire.derived(2, 8, source_operator=10)]},
        )
        self.assertEqual(
            response,
            "STARLINGS/1 RESPONSE\n"
            "operator=10\n"
            "claim=2,3,1000,10,i:8\n"
            "END\n",
        )

    def test_encode_approval_action(self):
        response = wire.encode_response(
            10,
            {
                "actions": [
                    {
                        "name": "publish-result",
                        "payload": "artifact:answer",
                        "requires_approval": True,
                    }
                ]
            },
        )
        self.assertEqual(
            response,
            "STARLINGS/1 RESPONSE\n"
            "operator=10\n"
            "action=publish-result,1,artifact:answer\n"
            "END\n",
        )

    def test_real_python_subprocess_operator_roundtrip(self):
        source = textwrap.dedent(
            """
            from starlings_operator import serve, derived

            def op(ctx):
                value = ctx["variables"][1]["value"]
                return {"claims": [derived(2, value + 5, source_operator=10)]}

            if __name__ == "__main__":
                serve(op)
            """
        )

        with tempfile.TemporaryDirectory() as tmp:
            script = os.path.join(tmp, "starlings_fixture.py")
            with open(script, "w", encoding="utf-8") as f:
                f.write(source)

            env = dict(os.environ)
            env["PYTHONPATH"] = HERE + os.pathsep + env.get("PYTHONPATH", "")
            request = (
                "STARLINGS/1 REQUEST\n"
                "operator=10\n"
                "round=1\n"
                "var=1,1,i:7\n"
                "END\n"
            )
            proc = subprocess.run(
                [sys.executable, script],
                input=request,
                text=True,
                capture_output=True,
                env=env,
                check=False,
                timeout=5,
            )
            if proc.returncode != 0:
                self.fail(
                    "Python operator subprocess failed "
                    f"(exit={proc.returncode})\n"
                    f"stdout:\n{proc.stdout}\n"
                    f"stderr:\n{proc.stderr}"
                )

        self.assertEqual(
            proc.stdout,
            "STARLINGS/1 RESPONSE\n"
            "operator=10\n"
            "claim=2,3,1000,10,i:12\n"
            "END\n",
        )


if __name__ == "__main__":
    unittest.main()
