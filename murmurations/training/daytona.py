"""Daytona-backed execution for serious Murmurations corpus generation."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shlex
import time
import urllib.error
import urllib.request
from typing import Any, Sequence

from murmurations.training.environments.repositories import RepoRecord
from murmurations.training.operators import detect_prepare_commands


_SYNC_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".go", ".h", ".hpp", ".java", ".js", ".jsx",
    ".py", ".rs", ".ts", ".tsx", ".zig",
}
_SKIP_DIRS = {".git", ".venv", "node_modules", "target", "zig-cache", ".zig-cache"}


@dataclass(frozen=True)
class DaytonaExecution:
    ok: bool
    exit_code: int
    output: str
    argv: tuple[str, ...]
    sandbox_id: str
    snapshot: str
    remote_cwd: str
    remote_command: str


class DaytonaCorpusRunner:
    """Create ephemeral Daytona sandboxes for serious dynamic corpus work."""

    def __init__(
        self,
        *,
        snapshot: str,
        ttl_minutes: int = 45,
        block_network_after_prepare: bool = False,
        target: str | None = None,
        client=None,
        sandbox_params_factory=None,
    ) -> None:
        self.snapshot = snapshot
        self.ttl_minutes = ttl_minutes
        self.block_network_after_prepare = block_network_after_prepare
        self.target = target
        self._client = client
        self._client_injected = client is not None
        self._sandbox_params_factory = sandbox_params_factory
        self._snapshot_info: dict[str, Any] | None = None

    @staticmethod
    def _log(message: str) -> None:
        print(f"[daytona] {message}", flush=True)

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "DaytonaCorpusRunner":
        if str(config.get("runtime", "")) != "daytona":
            raise ValueError("serious corpus sandbox.runtime must be 'daytona'")
        snapshot = str(config.get("snapshot") or "").strip()
        if not snapshot:
            raise ValueError("serious corpus sandbox.snapshot is required")
        return cls(
            snapshot=snapshot,
            ttl_minutes=int(config.get("ttl_minutes", 45)),
            block_network_after_prepare=bool(
                config.get("block_network_after_prepare", False)
            ),
            target=(str(config.get("target")).strip() if config.get("target") else None),
        )

    @property
    def client(self):
        if self._client is None:
            try:
                from daytona import Daytona, DaytonaConfig
            except ImportError as exc:
                raise RuntimeError(
                    "Daytona SDK is required; install murmurations/requirements.txt"
                ) from exc
            if self.target:
                self._client = Daytona(
                    DaytonaConfig(
                        api_key=os.environ.get("DAYTONA_API_KEY"),
                        api_url=os.environ.get("DAYTONA_API_URL"),
                        target=self.target,
                        connection_pool_maxsize=None,
                    )
                )
            else:
                self._client = Daytona()
        return self._client

    def validate_environment(self) -> None:
        if self._client is None:
            if not os.environ.get("DAYTONA_API_KEY"):
                raise RuntimeError("DAYTONA_API_KEY is required for serious corpus generation")
            if not os.environ.get("DAYTONA_API_URL"):
                raise RuntimeError("DAYTONA_API_URL is required for serious corpus generation")
        self._log(f"validate snapshot={self.snapshot}")
        snapshot = self.client.snapshot.get(self.snapshot)
        self._snapshot_info = {
            "id": getattr(snapshot, "id", None),
            "name": getattr(snapshot, "name", self.snapshot),
            "state": getattr(snapshot, "state", None),
            "cpu": getattr(snapshot, "cpu", None),
            "memory_gib": getattr(snapshot, "mem", None),
            "disk_gib": getattr(snapshot, "disk", None),
            "organization_id": getattr(snapshot, "organization_id", None),
        }
        self._log(
            f"snapshot ready name={self._snapshot_info['name']} "
            f"state={self._snapshot_info['state']}"
        )

    def concurrency_capacity(self, max_workers: int) -> dict[str, Any]:
        """Return the safe cross-sandbox worker capacity for this snapshot."""
        if max_workers <= 0:
            raise ValueError("max_workers must be positive")
        if self._snapshot_info is None:
            raise RuntimeError("validate_environment must run before capacity discovery")

        cpu = float(self._snapshot_info.get("cpu") or 0)
        memory = float(self._snapshot_info.get("memory_gib") or 0)
        disk = float(self._snapshot_info.get("disk_gib") or 0)
        if cpu <= 0 or memory <= 0 or disk <= 0:
            raise RuntimeError("Daytona snapshot resource metadata is incomplete")

        result: dict[str, Any] = {
            "requested_max_workers": max_workers,
            "snapshot_cpu": cpu,
            "snapshot_memory_gib": memory,
            "snapshot_disk_gib": disk,
            "source": "configured_max",
            "workers": max_workers,
        }
        organization_id = str(
            self._snapshot_info.get("organization_id")
            or os.environ.get("DAYTONA_ORGANIZATION_ID")
            or ""
        ).strip()
        api_key = os.environ.get("DAYTONA_API_KEY")
        api_url = os.environ.get("DAYTONA_API_URL", "https://app.daytona.io/api").rstrip("/")
        if not organization_id or not api_key:
            return result

        request = urllib.request.Request(
            f"{api_url}/organizations/{organization_id}/usage",
            headers={"Authorization": f"Bearer {api_key}", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            self._log(f"capacity discovery unavailable; using configured max: {exc}")
            return result

        regions = list(payload.get("regionUsage") or [])
        target = self.target
        region = next(
            (
                item for item in regions
                if not target or str(item.get("regionId") or "") == target
            ),
            None,
        )
        if region is None:
            self._log("capacity discovery found no matching region; using configured max")
            return result

        available_cpu = max(
            0.0,
            float(region.get("totalCpuQuota") or 0)
            - float(region.get("currentCpuUsage") or 0),
        )
        available_memory = max(
            0.0,
            float(region.get("totalMemoryQuota") or 0)
            - float(region.get("currentMemoryUsage") or 0),
        )
        available_disk = max(
            0.0,
            float(region.get("totalDiskQuota") or 0)
            - float(region.get("currentDiskUsage") or 0),
        )
        workers = min(
            max_workers,
            int(available_cpu // cpu),
            int(available_memory // memory),
            int(available_disk // disk),
        )
        if workers <= 0:
            raise RuntimeError(
                "Daytona has no free capacity for the corpus snapshot: "
                f"cpu={available_cpu:g}, memory={available_memory:g}GiB, "
                f"disk={available_disk:g}GiB"
            )
        result.update(
            {
                "source": "organization_usage",
                "organization_id": organization_id,
                "region": region.get("regionId"),
                "available_cpu": available_cpu,
                "available_memory_gib": available_memory,
                "available_disk_gib": available_disk,
                "workers": workers,
            }
        )
        self._log(
            f"capacity workers={workers} available_cpu={available_cpu:g} "
            f"available_memory={available_memory:g}GiB "
            f"available_disk={available_disk:g}GiB"
        )
        return result

    def provenance(self) -> dict[str, Any]:
        return {
            "runtime": "daytona",
            "snapshot": self.snapshot,
            "ttl_minutes": self.ttl_minutes,
            "block_network_after_prepare": self.block_network_after_prepare,
            "target": self.target,
            "snapshot_info": self._snapshot_info,
        }

    def worker(self) -> "DaytonaCorpusRunner":
        """Return an independent runner for concurrent sandbox lifecycle calls."""
        if self._client_injected or self._sandbox_params_factory is not None:
            return self
        return DaytonaCorpusRunner(
            snapshot=self.snapshot,
            ttl_minutes=self.ttl_minutes,
            block_network_after_prepare=self.block_network_after_prepare,
            target=self.target,
        )

    def workspace(
        self,
        local_root: str | Path | None,
        repository: RepoRecord,
        *,
        plan_root: str | Path | None = None,
        prepare_commands: Sequence[Sequence[str]] | None = None,
        sync_local_changes: bool = True,
        remote_plan: bool = False,
    ) -> "DaytonaWorkspace":
        return DaytonaWorkspace(
            self,
            local_root=local_root,
            repository=repository,
            plan_root=plan_root,
            prepare_commands=prepare_commands,
            sync_local_changes=sync_local_changes,
            remote_plan=remote_plan,
        )


class DaytonaWorkspace:
    """One repository-scoped remote sandbox with local mutation synchronization."""

    remote_root = "workspace/repo"

    def __init__(
        self,
        runner: DaytonaCorpusRunner,
        *,
        local_root: str | Path | None,
        repository: RepoRecord,
        plan_root: str | Path | None,
        prepare_commands: Sequence[Sequence[str]] | None,
        sync_local_changes: bool,
        remote_plan: bool,
    ) -> None:
        if not repository.url:
            raise ValueError(
                "Daytona serious corpus execution requires a remote repository URL"
            )
        self.runner = runner
        self.local_root = (
            Path(local_root).expanduser().resolve()
            if local_root is not None
            else None
        )
        self.repository = repository
        self.plan_root = (
            Path(plan_root).expanduser().resolve()
            if plan_root is not None
            else self.local_root
        )
        self.prepare_commands = (
            tuple(tuple(str(item) for item in command) for command in prepare_commands)
            if prepare_commands is not None
            else None
        )
        self.sync_local_changes = sync_local_changes
        self.remote_plan = remote_plan
        self.planned_test_command: tuple[str, ...] | None = None
        self.sandbox = None
        self._local_hashes: dict[str, str] | None = None

    def __enter__(self) -> "DaytonaWorkspace":
        if self.runner._sandbox_params_factory is None:
            try:
                from daytona import CreateSandboxFromSnapshotParams
            except ImportError as exc:
                raise RuntimeError(
                    "Daytona SDK is required; install murmurations/requirements.txt"
                ) from exc
            params_factory = CreateSandboxFromSnapshotParams
        else:
            params_factory = self.runner._sandbox_params_factory

        params = params_factory(
            snapshot=self.runner.snapshot,
            ttl_minutes=self.runner.ttl_minutes,
            ephemeral=True,
            public=False,
            labels={"murmurations": "corpus"},
            env_vars={
                "CI": "1",
                "PYTHONDONTWRITEBYTECODE": "1",
                "TZ": "UTC",
            },
        )
        self.runner._log(
            f"create repo={self.repository.name} snapshot={self.runner.snapshot}"
        )
        started = time.monotonic()
        self.sandbox = self.runner.client.create(params, timeout=120)
        self.runner._log(
            f"created repo={self.repository.name} sandbox={self.sandbox.id} "
            f"seconds={time.monotonic() - started:.1f}"
        )
        try:
            self.runner._log(
                f"clone repo={self.repository.name} url={self.repository.url}"
            )
            self.sandbox.git.clone(url=self.repository.url, path=self.remote_root)
            self.runner._log(
                f"checkout repo={self.repository.name} commit={self.repository.commit}"
            )
            checkout = self.sandbox.process.exec(
                shlex.join(["git", "checkout", "--detach", self.repository.commit])
                + " 2>&1",
                cwd=self.remote_root,
                timeout=120,
            )
            if int(checkout.exit_code) != 0:
                raise RuntimeError(
                    f"remote checkout failed for {self.repository.name}: "
                    f"{(checkout.result or '')[-4000:]}"
                )

            if self.remote_plan:
                planner_local = Path(__file__).with_name("repository_plan.py")
                planner_remote = "workspace/murmurations_repository_plan.py"
                self.sandbox.fs.upload_file(str(planner_local), planner_remote)
                self.runner._log(
                    f"plan repo={self.repository.name} sandbox={self.sandbox.id}"
                )
                planned = self.sandbox.process.exec(
                    "python3 ../murmurations_repository_plan.py --root . 2>&1",
                    cwd=self.remote_root,
                    timeout=30,
                )
                if int(planned.exit_code) != 0:
                    raise RuntimeError(
                        f"remote repository planning failed: {(planned.result or '')[-4000:]}"
                    )
                try:
                    payload = json.loads((planned.result or "").strip().splitlines()[-1])
                except (IndexError, json.JSONDecodeError) as exc:
                    raise RuntimeError(
                        f"invalid remote repository plan: {(planned.result or '')[-4000:]}"
                    ) from exc
                raw_test = payload.get("test_command")
                self.planned_test_command = (
                    tuple(str(item) for item in raw_test)
                    if isinstance(raw_test, list) and raw_test
                    else None
                )
                if self.planned_test_command is None:
                    raise RuntimeError("no supported repository test command detected")
                raw_prepare = payload.get("prepare_commands") or []
                prepare_commands = tuple(
                    tuple(str(item) for item in command)
                    for command in raw_prepare
                    if isinstance(command, list)
                )
            else:
                prepare_commands = (
                    self.prepare_commands
                    if self.prepare_commands is not None
                    else tuple(tuple(command) for command in detect_prepare_commands(self.plan_root))
                )
            for index, argv in enumerate(prepare_commands, start=1):
                portable = self._portable_argv(argv)
                command = shlex.join(portable) + " 2>&1"
                self.runner._log(
                    f"prepare repo={self.repository.name} sandbox={self.sandbox.id} "
                    f"step={index}/{len(prepare_commands)} argv={shlex.join(portable)}"
                )
                started = time.monotonic()
                result = self.sandbox.process.exec(
                    command,
                    cwd=self.remote_root,
                    timeout=max(300, self.runner.ttl_minutes * 60 // 2),
                )
                self.runner._log(
                    f"prepare done repo={self.repository.name} step={index}/{len(prepare_commands)} "
                    f"exit={result.exit_code} seconds={time.monotonic() - started:.1f}"
                )
                if int(result.exit_code) != 0:
                    raise RuntimeError(
                        f"repository preparation failed: {portable!r}\n"
                        f"{(result.result or '')[-4000:]}"
                    )

            if self.runner.block_network_after_prepare:
                self.runner._log(
                    f"block network repo={self.repository.name} sandbox={self.sandbox.id}"
                )
                self.sandbox.update_network_settings(network_block_all=True)
            self.runner._log(
                f"workspace ready repo={self.repository.name} sandbox={self.sandbox.id}"
            )
            return self
        except Exception:
            try:
                self.runner.client.delete(self.sandbox, timeout=60, wait=True)
            except Exception:
                pass
            self.sandbox = None
            raise

    def __exit__(self, exc_type, exc, tb) -> bool:
        if self.sandbox is not None:
            try:
                self.runner._log(
                    f"delete repo={self.repository.name} sandbox={self.sandbox.id}"
                )
                self.runner.client.delete(self.sandbox, timeout=60, wait=True)
            except Exception:
                if exc_type is None:
                    raise
        return False

    @staticmethod
    def _portable_argv(argv: Sequence[str]) -> tuple[str, ...]:
        values = tuple(str(item) for item in argv)
        if not values:
            return values
        executable = Path(values[0])
        if executable.is_absolute() and executable.name.startswith("python"):
            return ("python3",) + values[1:]
        return values

    def _hash_local_sources(self) -> dict[str, str]:
        if self.local_root is None or not self.local_root.is_dir():
            raise RuntimeError(f"local corpus workspace not found: {self.local_root}")
        hashes: dict[str, str] = {}
        for path in self.local_root.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(self.local_root)
            if any(part in _SKIP_DIRS for part in relative.parts):
                continue
            if path.suffix.lower() not in _SYNC_EXTENSIONS:
                continue
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
            hashes[str(relative)] = digest.hexdigest()
        return hashes

    def _sync_local_changes(self) -> None:
        if self.sandbox is None:
            raise RuntimeError("Daytona workspace is not active")
        current = self._hash_local_sources()
        if self._local_hashes is None:
            # The remote workspace is the same pinned commit. Establish the
            # local baseline without transferring the clean repository.
            self._local_hashes = current
            return
        deleted = set(self._local_hashes) - set(current)
        if deleted:
            raise RuntimeError(
                "local corpus mutation deleted source files; deletion sync is unsupported"
            )
        for relative, digest in current.items():
            if self._local_hashes.get(relative) == digest:
                continue
            self.sandbox.fs.upload_file(
                str(self.local_root / relative),
                f"{self.remote_root}/{relative}",
            )
        self._local_hashes = current

    def run(
        self,
        _workspace: str | Path,
        argv: Sequence[str],
        timeout_seconds: int,
    ) -> DaytonaExecution:
        if self.sandbox is None:
            raise RuntimeError("Daytona workspace is not active")
        if self.sync_local_changes:
            self._sync_local_changes()
        portable = self._portable_argv(argv)
        if not portable:
            raise ValueError("cannot execute empty argv")
        command = shlex.join(portable) + " 2>&1"
        self.runner._log(
            f"exec repo={self.repository.name} sandbox={self.sandbox.id} "
            f"timeout={timeout_seconds}s argv={shlex.join(portable)}"
        )
        started = time.monotonic()
        response = self.sandbox.process.exec(
            command,
            cwd=self.remote_root,
            timeout=timeout_seconds,
        )
        self.runner._log(
            f"exec done repo={self.repository.name} sandbox={self.sandbox.id} "
            f"exit={response.exit_code} seconds={time.monotonic() - started:.1f}"
        )
        output = (response.result or "")[-8000:]
        exit_code = int(response.exit_code)
        return DaytonaExecution(
            ok=exit_code == 0,
            exit_code=exit_code,
            output=output,
            argv=portable,
            sandbox_id=str(self.sandbox.id),
            snapshot=self.runner.snapshot,
            remote_cwd=self.remote_root,
            remote_command=command,
        )

    def verify(
        self,
        workspace: str | Path,
        argv: Sequence[str],
        timeout_seconds: int,
    ):
        from murmurations.training.environments.mutations import Verification

        result = self.run(workspace, argv, timeout_seconds)
        return Verification(
            passed=result.ok,
            exit_code=result.exit_code,
            output=result.output,
            argv=result.argv,
            backend="daytona",
            sandbox_argv=(),
            sandbox_id=result.sandbox_id,
            sandbox_snapshot=result.snapshot,
        )

    def run_operator(
        self,
        workspace: str | Path,
        argv: Sequence[str],
        timeout_seconds: int,
    ):
        from murmurations.training.operators import OperatorResult

        result = self.run(workspace, argv, timeout_seconds)
        return OperatorResult(
            result.ok,
            result.output,
            exit_code=result.exit_code,
            metadata={
                "argv": list(result.argv),
                "sandbox_backend": "daytona",
                "sandbox_id": result.sandbox_id,
                "sandbox_snapshot": result.snapshot,
                "remote_cwd": result.remote_cwd,
                "remote_command": result.remote_command,
            },
        )
