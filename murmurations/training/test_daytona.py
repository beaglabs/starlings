from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from murmurations.training.daytona import DaytonaCorpusRunner
from murmurations.training.environments.repositories import RepoRecord


class _Response:
    def __init__(self, exit_code: int = 0, result: str = "ok") -> None:
        self.exit_code = exit_code
        self.result = result


class _Process:
    def __init__(self) -> None:
        self.commands: list[tuple[str, str | None, int | None]] = []

    def exec(self, command: str, *, cwd=None, timeout=None):
        self.commands.append((command, cwd, timeout))
        if "murmurations_repository_plan.py" in command:
            return _Response(
                result='{"check_command":["python3","-m","compileall","-q","."],'
                '"prepare_commands":[],'
                '"test_command":["python3","-m","pytest","-q"]}'
            )
        return _Response()


class _Git:
    def __init__(self) -> None:
        self.clones: list[tuple[str, str]] = []

    def clone(self, *, url: str, path: str) -> None:
        self.clones.append((url, path))


class _Fs:
    def __init__(self) -> None:
        self.uploads: list[tuple[str, str]] = []

    def upload_file(self, local_path: str, remote_path: str) -> None:
        self.uploads.append((local_path, remote_path))


class _Sandbox:
    def __init__(self) -> None:
        self.id = "sandbox-123"
        self.process = _Process()
        self.git = _Git()
        self.fs = _Fs()
        self.network_updates: list[bool] = []

    def update_network_settings(self, *, network_block_all: bool) -> None:
        self.network_updates.append(network_block_all)


class _Snapshot:
    id = "snapshot-123"
    name = "murmurations-corpus-v1"
    state = "active"
    cpu = 4
    mem = 8
    disk = 10


class _SnapshotService:
    def get(self, _name: str):
        return _Snapshot()


class _Client:
    def __init__(self) -> None:
        self.snapshot = _SnapshotService()
        self.sandbox = _Sandbox()
        self.created = []
        self.deleted = []

    def create(self, params, *, timeout: int):
        self.created.append((params, timeout))
        return self.sandbox

    def delete(self, sandbox, *, timeout: int, wait: bool) -> None:
        self.deleted.append((sandbox.id, timeout, wait))


def _params_factory(**kwargs):
    return kwargs


class DaytonaCorpusRunnerTests(unittest.TestCase):
    def test_workspace_preserves_logical_argv_and_syncs_only_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "src.py"
            source.write_text("value = 1\n", encoding="utf-8")
            repo = RepoRecord(
                "fixture",
                "a" * 40,
                "MIT",
                url="https://github.com/example/fixture.git",
                language="Python",
            )
            client = _Client()
            runner = DaytonaCorpusRunner(
                snapshot="murmurations-corpus-v1",
                client=client,
                sandbox_params_factory=_params_factory,
            )
            runner.validate_environment()

            with runner.workspace(root, repo, plan_root=root) as remote:
                clean = remote.verify(
                    root,
                    ["/usr/local/bin/python3", "-m", "pytest"],
                    30,
                )
                self.assertTrue(clean.passed)
                self.assertEqual(clean.argv, ("python3", "-m", "pytest"))
                self.assertEqual(clean.backend, "daytona")
                self.assertEqual(clean.sandbox_id, "sandbox-123")
                self.assertEqual(clean.sandbox_snapshot, "murmurations-corpus-v1")
                self.assertEqual(client.sandbox.fs.uploads, [])

                source.write_text("value = 2\n", encoding="utf-8")
                changed = remote.verify(root, ["python3", "-m", "pytest"], 30)
                self.assertTrue(changed.passed)
                self.assertEqual(len(client.sandbox.fs.uploads), 1)
                self.assertEqual(
                    client.sandbox.fs.uploads[0][1],
                    "workspace/repo/src.py",
                )

            self.assertEqual(
                client.sandbox.git.clones,
                [("https://github.com/example/fixture.git", "workspace/repo")],
            )
            self.assertEqual(client.deleted, [("sandbox-123", 60, True)])

    def test_clean_probe_can_run_after_local_checkout_is_pruned(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            root.mkdir()
            repo = RepoRecord(
                "fixture",
                "a" * 40,
                "MIT",
                url="https://github.com/example/fixture.git",
                language="Python",
            )
            client = _Client()
            runner = DaytonaCorpusRunner(
                snapshot="murmurations-corpus-v1",
                client=client,
                sandbox_params_factory=_params_factory,
            )
            runner.validate_environment()

            with runner.workspace(
                root,
                repo,
                plan_root=root,
                prepare_commands=[],
                sync_local_changes=False,
            ) as remote:
                root.rmdir()
                result = remote.verify(
                    root,
                    [".murmurations-venv/bin/python3", "-m", "pytest", "-q"],
                    30,
                )

            self.assertTrue(result.passed)
            self.assertEqual(client.sandbox.fs.uploads, [])

    def test_remote_probe_plans_without_local_checkout(self) -> None:
        repo = RepoRecord(
            "fixture",
            "a" * 40,
            "MIT",
            url="https://github.com/example/fixture.git",
            language="Python",
        )
        client = _Client()
        runner = DaytonaCorpusRunner(
            snapshot="murmurations-corpus-v1",
            client=client,
            sandbox_params_factory=_params_factory,
        )
        runner.validate_environment()

        with runner.workspace(
            None,
            repo,
            sync_local_changes=False,
            remote_plan=True,
        ) as remote:
            self.assertEqual(
                remote.planned_test_command,
                ("python3", "-m", "pytest", "-q"),
            )
            result = remote.verify(None, remote.planned_test_command, 30)

        self.assertTrue(result.passed)
        self.assertTrue(
            any(
                remote_path == "workspace/murmurations_repository_plan.py"
                for _, remote_path in client.sandbox.fs.uploads
            )
        )

    def test_config_preserves_target_region(self) -> None:
        runner = DaytonaCorpusRunner.from_config(
            {
                "runtime": "daytona",
                "snapshot": "murmurations-corpus-v1",
                "target": "us",
            }
        )
        self.assertEqual(runner.target, "us")
        self.assertEqual(runner.provenance()["target"], "us")

    def test_config_requires_daytona_runtime(self) -> None:
        with self.assertRaisesRegex(ValueError, "daytona"):
            DaytonaCorpusRunner.from_config(
                {"runtime": "zviz", "snapshot": "murmurations-corpus-v1"}
            )


if __name__ == "__main__":
    unittest.main()
