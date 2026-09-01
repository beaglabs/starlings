from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

import yaml

import murmurations.training.build_shard as build_shard_module
from murmurations.training.build_shard import build_shard
from murmurations.training.import_swe_smith import (
    classify_tool_call,
    convert_atif_record,
    import_swe_smith,
)
from murmurations.training.materialize import materialize_episode
from murmurations.utils.protocol import ArgumentKind


def _record(
    *,
    traj_id: str = "external__repo.abc123.func_basic__one.trace",
    resolved: bool = True,
) -> dict:
    return {
        "id": traj_id,
        "steps": [
            {
                "step_id": 0,
                "source": "system",
                "message": "You are a software engineering agent.",
            },
            {
                "step_id": 1,
                "source": "user",
                "message": "Fix the broken cache behavior and make the tests pass.",
            },
            {
                "step_id": 2,
                "source": "agent",
                "message": "I will inspect the implementation first.",
                "tool_calls": [
                    {
                        "tool_call_id": "call_1",
                        "function_name": "terminal",
                        "arguments": {"command": "cd /testbed && rg cache src tests"},
                    }
                ],
                "observation": {
                    "results": [
                        {
                            "source_call_id": "call_1",
                            "content": "src/cache.py:10:def get_cached_value(...):",
                        }
                    ]
                },
            },
            {
                "step_id": 3,
                "source": "agent",
                "message": "The stale-value branch is wrong; I will replace it.",
                "tool_calls": [
                    {
                        "tool_call_id": "call_2",
                        "function_name": "str_replace_editor",
                        "arguments": {
                            "command": "str_replace",
                            "path": "/testbed/src/cache.py",
                            "old_str": "return stale",
                            "new_str": "return fresh",
                        },
                    }
                ],
                "observation": {
                    "results": [
                        {
                            "source_call_id": "call_2",
                            "content": "The file was edited successfully.",
                        }
                    ]
                },
            },
            {
                "step_id": 4,
                "source": "agent",
                "message": "Now I will run the repository tests.",
                "tool_calls": [
                    {
                        "tool_call_id": "call_3",
                        "function_name": "terminal",
                        "arguments": {"command": "cd /testbed && pytest -q"},
                    }
                ],
                "observation": {
                    "results": [
                        {
                            "source_call_id": "call_3",
                            "content": "42 passed in 1.21s",
                        }
                    ]
                },
            },
            {
                "step_id": 5,
                "source": "agent",
                "message": "All tests pass.",
                "tool_calls": [
                    {
                        "tool_call_id": "call_4",
                        "function_name": "finish",
                        "arguments": {"task_completed": "true"},
                    }
                ],
            },
        ],
        "extra": {
            "raw": {
                "instance_id": "external__repo.abc123.func_basic__one",
                "resolved": resolved,
                "model": "fixture-model",
                "traj_id": traj_id,
                "patch": "",
            },
            "source_dataset": "swe-smith",
        },
    }


class SweSmithImportTests(unittest.TestCase):
    def test_terminal_commands_map_to_semantic_operators(self) -> None:
        operator, _, kind = classify_tool_call(
            "terminal", {"command": "cd /testbed && pytest -q"}
        )
        self.assertEqual(operator, "repo.tests")
        self.assertEqual(kind, ArgumentKind.ACTION)

        operator, _, _ = classify_tool_call(
            "terminal", {"command": "rg normalize src tests"}
        )
        self.assertEqual(operator, "repo.search")

        operator, _, _ = classify_tool_call(
            "terminal", {"command": "cargo check --quiet"}
        )
        self.assertEqual(operator, "type.check")

    def test_resolved_atif_record_converts_to_grounded_episode(self) -> None:
        episode = convert_atif_record(_record())

        self.assertIsNotNone(episode)
        assert episode is not None
        self.assertEqual(episode["producer"], "swe-smith-atif-import-v1")
        self.assertEqual(episode["repository"]["name"], "external/repo")
        self.assertEqual(episode["repository"]["language"], "Python")
        self.assertEqual(
            episode["generation"]["candidate_source"],
            "external_execution_trace",
        )

        execute_events = [
            event
            for event in episode["events"]
            if event["frame"]["operation"] == "EXECUTE"
        ]
        self.assertEqual(len(execute_events), 3)
        self.assertEqual(
            [event["frame"]["operator_ref"] for event in execute_events],
            ["repo.search", None, "repo.tests"],
        )
        self.assertTrue(
            all(event["environment"]["external_execution"] for event in execute_events)
        )
        self.assertEqual(
            execute_events[-1]["environment"]["output"],
            "42 passed in 1.21s",
        )

        rows = materialize_episode(episode)
        rendered = "\n".join(row["context"] for row in rows)
        self.assertIn("TOOL[", rendered)
        self.assertIn("COMMAND[", rendered)
        self.assertIn("pytest -q", rendered)
        self.assertIn("42 passed in 1.21s", rendered)

    def test_unresolved_records_are_rejected(self) -> None:
        self.assertIsNone(convert_atif_record(_record(resolved=False)))

    def test_stream_import_stops_at_target_and_excludes_static_repositories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            input_path = root / "atif.jsonl"
            rows = [
                _record(traj_id="blocked.trace"),
                _record(traj_id="allowed.trace"),
            ]
            rows[0]["extra"]["raw"]["instance_id"] = "external__repo.abc.blocked"
            rows[1]["extra"]["raw"]["instance_id"] = "other__repo.abc.allowed"
            input_path.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            output = root / "episodes.jsonl"

            report = import_swe_smith(
                output,
                input_jsonl=input_path,
                target_rows=1,
                min_episodes=1,
                min_repositories=1,
                max_episodes=10,
                exclude_repositories={"external/repo"},
            )

            self.assertEqual(report["written"], 1)
            self.assertEqual(report["repositories"], 1)
            imported = json.loads(output.read_text(encoding="utf-8").strip())
            self.assertEqual(imported["repository"]["name"], "other/repo")


class ImportedShardBuildTests(unittest.TestCase):
    def test_import_mode_builds_without_touching_daytona(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            static_repo = root / "static"
            static_repo.mkdir()
            (static_repo / "sample.py").write_text(
                (
                    "def add(a, b):\n"
                    "    return a + b\n\n"
                    "def subtract(a, b):\n"
                    "    return a - b\n\n"
                    "def multiply(a, b):\n"
                    "    return a * b\n\n"
                    "def divide(a, b):\n"
                    "    if b == 0:\n"
                    "        raise ValueError('division by zero')\n"
                    "    return a / b\n\n"
                    "def clamp(value, lower, upper):\n"
                    "    return max(lower, min(value, upper))\n"
                ),
                encoding="utf-8",
            )
            catalog = root / "catalog.jsonl"
            catalog.write_text(
                json.dumps(
                    {
                        "name": "static/example",
                        "commit": "fixture-v1",
                        "license": "MIT",
                        "language": "Python",
                        "path": str(static_repo),
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            source = root / "atif.jsonl"
            source.write_text(json.dumps(_record()) + "\n", encoding="utf-8")

            config = {
                "name": "import-smoke",
                "exclude_catalog": str(catalog),
                "output_dir": str(root / "out"),
                "seed": 17,
                "eval_fraction": 0.0,
                "generation": {
                    "mode": "import",
                    "source": {
                        "input_jsonl": str(source),
                        "target_rows": 1,
                        "max_episodes": 1,
                        "smoke_target_rows": 1,
                        "smoke_max_episodes": 1,
                    },
                },
                "max_context_chars": 12000,
                "quality": {
                    "min_generation_success_rate": 1.0,
                    "min_episodes": 1,
                    "min_dynamic_repositories": 1,
                    "required_dynamic_languages": ["Python"],
                    "required_operator_refs": ["repo.search", "repo.tests"],
                    "min_trajectory_rows": 1,
                    "min_external_execution_events": 1,
                },
            }
            config_path = root / "config.yaml"
            config_path.write_text(yaml.safe_dump(config), encoding="utf-8")

            self.assertFalse(hasattr(build_shard_module, "DaytonaCorpusRunner"))
            self.assertFalse(hasattr(build_shard_module, "materialize_repository_code"))
            manifest = build_shard(config_path, smoke=True)

            self.assertTrue(manifest["qa"]["passed"])
            self.assertEqual(manifest["mode"], "import")
            self.assertIsNone(manifest["sandbox"])
            self.assertIsNone(manifest["code"])
            self.assertEqual(manifest["generation"]["mode"], "import")
            self.assertNotIn("code_rows", manifest["qa"]["gates"])
            self.assertFalse((root / "out" / "code-train.jsonl").exists())
            self.assertFalse((root / "out" / "code-eval.jsonl").exists())
            self.assertGreater(
                manifest["qa"]["episodes"]["external_execution_events"],
                0,
            )


if __name__ == "__main__":
    unittest.main()
