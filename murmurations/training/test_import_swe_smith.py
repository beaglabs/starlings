from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

import yaml

import murmurations.training.build_shard as build_shard_module
from murmurations.training.annotate_imported import apply_annotation_payload
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



def _raw_record(
    *,
    traj_id: str = "external__repo.abc123.func_basic__one.trace",
    resolved: bool = True,
    style: str = "xml",
) -> dict:
    instance_id = "external__repo.abc123.func_basic__one"
    system = {"role": "system", "content": "You are a coding agent."}
    user = {
        "role": "user",
        "content": "Fix the broken cache behavior and make the tests pass.",
    }

    if style == "xml":
        inspect = {
            "role": "assistant",
            "content": (
                "I will inspect the cache.\n\n"
                "<function=bash>\n"
                "<parameter=command>cd /testbed && rg cache src tests</parameter>\n"
                "</function>"
            ),
        }
        test = {
            "role": "assistant",
            "content": (
                "Now verify the repair.\n\n"
                "<function=bash>\n"
                "<parameter=command>cd /testbed && pytest -q</parameter>\n"
                "</function>"
            ),
        }
        finish = {
            "role": "assistant",
            "content": "<function=submit>\n</function>",
        }
        inspect_observation = {
            "role": "user",
            "content": "OBSERVATION:\nsrc/cache.py:10:def get_cached_value(...):",
        }
        test_observation = {
            "role": "user",
            "content": "OBSERVATION:\n42 passed in 1.21s",
        }
    elif style == "ticks":
        inspect = {
            "role": "assistant",
            "content": (
                "I will inspect the cache.\n\n"
                "\x60\x60\x60\ncd /testbed && rg cache src tests\n\x60\x60\x60"
            ),
        }
        test = {
            "role": "assistant",
            "content": (
                "Now verify the repair.\n\n"
                "\x60\x60\x60bash\ncd /testbed && pytest -q\n\x60\x60\x60"
            ),
        }
        finish = {
            "role": "assistant",
            "content": "<function=submit>\n</function>",
        }
        inspect_observation = {
            "role": "user",
            "content": "OBSERVATION:\nsrc/cache.py:10:def get_cached_value(...):",
        }
        test_observation = {
            "role": "user",
            "content": "OBSERVATION:\n42 passed in 1.21s",
        }
    elif style == "tool":
        inspect = {
            "role": "assistant",
            "content": "I will inspect the cache.",
            "thought": "I will inspect the cache.",
            "tool_calls": [
                {
                    "id": "tool_1",
                    "function": {
                        "name": "bash",
                        "arguments": json.dumps(
                            {"command": "cd /testbed && rg cache src tests"}
                        ),
                    },
                }
            ],
        }
        test = {
            "role": "assistant",
            "content": "Now verify the repair.",
            "thought": "Now verify the repair.",
            "tool_calls": [
                {
                    "id": "tool_2",
                    "function": {
                        "name": "bash",
                        "arguments": json.dumps(
                            {"command": "cd /testbed && pytest -q"}
                        ),
                    },
                }
            ],
        }
        finish = {
            "role": "assistant",
            "content": "",
            "thought": "",
            "tool_calls": [
                {
                    "id": "tool_3",
                    "function": {"name": "submit", "arguments": "{}"},
                }
            ],
        }
        inspect_observation = {
            "role": "tool",
            "tool_call_id": "tool_1",
            "content": [
                {"type": "text", "text": "src/cache.py:10:def get_cached_value(...)"}
            ],
        }
        test_observation = {
            "role": "tool",
            "tool_call_id": "tool_2",
            "content": [{"type": "text", "text": "42 passed in 1.21s"}],
        }
    else:
        raise ValueError(style)

    return {
        "messages": [
            system,
            user,
            inspect,
            inspect_observation,
            test,
            test_observation,
            finish,
        ],
        "instance_id": instance_id,
        "resolved": resolved,
        "model": "fixture-model",
        "traj_id": traj_id,
        "patch": "",
    }


class SweSmithImportTests(unittest.TestCase):
    def test_raw_swe_smith_styles_convert_to_grounded_episode(self) -> None:
        for style in ("xml", "tool", "ticks"):
            with self.subTest(style=style):
                episode = convert_atif_record(_raw_record(style=style))
                self.assertIsNotNone(episode)
                assert episode is not None
                self.assertEqual(episode["repository"]["name"], "external/repo")
                self.assertEqual(episode["repository"]["commit"], "abc123")
                self.assertTrue(episode["generation"]["resolved"])

                execute_events = [
                    event
                    for event in episode["events"]
                    if event["frame"]["operation"] == "EXECUTE"
                ]
                self.assertGreaterEqual(len(execute_events), 2)
                operator_refs = [
                    event["frame"].get("operator_ref") for event in execute_events
                ]
                self.assertIn("repo.search", operator_refs)
                self.assertIn("repo.tests", operator_refs)
                self.assertTrue(
                    any(
                        "42 passed" in str(event["environment"].get("output") or "")
                        for event in execute_events
                    )
                )
                self.assertEqual(
                    episode["events"][-1]["frame"]["operation"],
                    "ACCEPT",
                )

    def test_raw_unresolved_records_are_rejected(self) -> None:
        self.assertIsNone(convert_atif_record(_raw_record(resolved=False)))

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
        self.assertEqual(episode["repository"]["commit"], "abc123")
        self.assertEqual(episode["repository"]["language"], "Python")
        self.assertEqual(episode["repository"]["license"], "unknown")
        self.assertEqual(
            episode["generation"]["candidate_source"],
            "external_execution_trace",
        )
        self.assertEqual(episode["generation"]["source_dataset_license"], "MIT")

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

    def test_materialization_compacts_oversized_direct_parent(self) -> None:
        episode = convert_atif_record(_record())
        self.assertIsNotNone(episode)
        assert episode is not None

        episode["task"] = "task-" + ("T" * 50000)
        execute_index = next(
            index
            for index, event in enumerate(episode["events"])
            if event["frame"]["operation"] == "EXECUTE"
            and event["frame"].get("operator_ref") == "repo.tests"
        )
        execute = episode["events"][execute_index]
        execute["environment"]["tool_arguments"] = {"blob": "A" * 50000}
        execute["environment"]["command"] = "python -m pytest " + ("C" * 50000)
        execute["environment"]["output"] = "result-" + ("O" * 50000)

        evidence_index = next(
            index
            for index, event in enumerate(episode["events"])
            if execute["id"] in event["frame"].get("parents", [])
        )
        episode["events"][evidence_index]["grounding"] = "ground-" + ("G" * 50000)

        rows = materialize_episode(episode, max_context_chars=12000)

        self.assertTrue(all(len(row["context"]) <= 12000 for row in rows))
        self.assertIn(execute["id"], rows[evidence_index]["context"])
        self.assertIn("repo.tests", rows[evidence_index]["context"])

    def test_semantic_annotation_cannot_change_grounded_identity(self) -> None:
        episode = convert_atif_record(_record())
        self.assertIsNotNone(episode)
        assert episode is not None

        test_execute = next(
            event
            for event in episode["events"]
            if event["frame"]["operation"] == "EXECUTE"
            and event["frame"].get("operator_ref") == "repo.tests"
        )
        prior_evidence = next(
            event
            for event in episode["events"]
            if event["frame"]["operation"] == "EVIDENCE"
        )
        original_id = test_execute["id"]
        original_frame = json.loads(json.dumps(test_execute["frame"]))
        original_environment = json.loads(json.dumps(test_execute["environment"]))

        report = apply_annotation_payload(
            episode,
            {
                "events": [
                    {
                        "id": original_id,
                        "retrieval_query": "verify repository tests after repair",
                        "intent": "verification",
                        "supporting_evidence": [prior_evidence["id"], "not-an-event"],
                        "argument_kind_suggestion": "ACTION",
                    }
                ]
            },
            model="fixture-blackwell-model",
        )

        self.assertEqual(report["applied"], 1)
        self.assertEqual(report["query_updates"], 1)
        self.assertEqual(test_execute["id"], original_id)
        self.assertEqual(test_execute["frame"], original_frame)
        self.assertEqual(test_execute["environment"], original_environment)
        self.assertEqual(
            test_execute["semantic_annotation"]["supporting_evidence"],
            [prior_evidence["id"]],
        )
        self.assertIn("repo.tests", test_execute["candidates"])

        previous_query = test_execute["retrieval_query"]
        rejected = apply_annotation_payload(
            episode,
            {
                "events": [
                    {
                        "id": original_id,
                        "retrieval_query": "look up package documentation",
                        "intent": "documentation",
                    }
                ]
            },
            model="fixture-blackwell-model",
        )
        self.assertEqual(rejected["applied"], 1)
        self.assertEqual(rejected["query_updates"], 0)
        self.assertEqual(test_execute["retrieval_query"], previous_query)

    def test_unresolved_records_are_rejected(self) -> None:
        self.assertIsNone(convert_atif_record(_record(resolved=False)))

    def test_raw_import_deduplicates_trajectory_ids(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            input_path = root / "raw.jsonl"
            first = _raw_record(traj_id="same.trace", style="xml")
            second = _raw_record(traj_id="same.trace", style="tool")
            input_path.write_text(
                json.dumps(first) + "\n" + json.dumps(second) + "\n",
                encoding="utf-8",
            )
            output = root / "episodes.jsonl"

            report = import_swe_smith(
                output,
                input_jsonl=input_path,
                target_rows=1,
                min_episodes=1,
                min_repositories=1,
                max_episodes=2,
            )

            self.assertEqual(report["written"], 1)
            self.assertEqual(report["duplicate_trajectories_skipped"], 1)
            self.assertEqual(
                len(
                    [
                        line
                        for line in output.read_text(encoding="utf-8").splitlines()
                        if line
                    ]
                ),
                1,
            )

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
