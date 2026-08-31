"""Daytona-backed execution for serious Murmurations corpus generation."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import shlex
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
        client=None,
        sandbox_params_factory=None,
    ) -> None:
        self.snapshot = snapshot
        self.ttl_minutes = ttl_minutes
        self.block_network_after_prepare = block_network_after_prepare
        self._client = client
        self._sandbox_params_factory = sandbox_params_factory
        self._snapshot_info: dict[str, Any] | None = None

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
        )

    @property
    def client(self):
        if self._client is None:
            try:
                from daytona import Daytona
            except ImportError as exc:
                raise RuntimeError(
                    "Daytona SDK is required; install murmurations/requirements.txt"
                ) from exc
            self._client = Daytona()
        return self._client

    def validate_environment(self) -> None:
        if self._client is None:
            if not os.environ.get("DAYTONA_API_KEY"):
                raise RuntimeError("DAYTONA_API_KEY is required for serious corpus generation")
            if not os.environ.get("DAYTONA_API_URL"):
                raise RuntimeError("DAYTONA_API_URL is required for serious corpus generation")
        snapshot = self.client.snapshot.get(self.snapshot)
        self._snapshot_info = {
            "id": getattr(snapshot, "id", None),
            "name": getattr(snapshot, "name", self.snapshot),
            "state": getattr(snapshot, "state", None),
            "cpu": getattr(snapshot, "cpu", None),
            "memory_gib": getattr(snapshot, "mem", None),
            "disk_gib": getattr(snapshot, "disk", None),
        }

    def provenance(self) -> dict[str, Any]:
        return {
            "runtime": "daytona",
            "snapshot": self.snapshot,
            "ttl_minutes": self.ttl_minutes,
            "block_network_after_prepare": self.block_network_after_prepare,
            "snapshot_info": self._snapshot_info,
        }

    def workspace(
        self,
        local_root: str | Path,
        repository: RepoRecord,
        *,
        plan_root: str | Path | None = None,
    ) -> "DaytonaWorkspace":
        return DaytonaWorkspace(
            self,
            local_root=local_root,
            repository=repository,
            plan_root=plan_root,
        )


class DaytonaWorkspace:
    """One repository-scoped remote sandbox with local mutation synchronization."""

    remote_root = "workspace/repo"

    def __init__(
        self,
        runner: DaytonaCorpusRunner,
        *,
        local_root: str | Path,
        repository: RepoRecord,
        plan_root: str | Path | None,
    ) -> None:
        if not repository.url:
            raise ValueError(
                "Daytona serious corpus execution requires a remote repository URL"
            )
        self.runner = runner
        self.local_root = Path(local_root).expanduser().resolve()
        self.repository = repository
        self.plan_root = (
            Path(plan_root).expanduser().resolve()
            if plan_root is not None
            else self.local_root
        )
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
        self.sandbox = self.runner.client.create(params, timeout=120)
        try:
            self.sandbox.git.clone(url=self.repository.url, path=self.remote_root)
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

            for argv in detect_prepare_commands(self.plan_root):
                portable = self._portable_argv(argv)
                command = shlex.join(portable) + " 2>&1"
                result = self.sandbox.process.exec(
                    command,
                    cwd=self.remote_root,
                    timeout=max(300, self.runner.ttl_minutes * 60 // 2),
                )
                if int(result.exit_code) != 0:
                    raise RuntimeError(
                        f"repository preparation failed: {portable!r}\n"
                        f"{(result.result or '')[-4000:]}"
                    )

            if self.runner.block_network_after_prepare:
                self.sandbox.update_network_settings(network_block_all=True)
            return self
        except Exception:
            try:
                self.runner.client.delete(self.sandbox, timeout=60, wait=True)
            finally:
                self.sandbox = None
            raise

    def __exit__(self, exc_type, exc, tb) -> bool:
        if self.sandbox is not None:
            try:
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
        if not self.local_root.is_dir():
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
        self._sync_local_changes()
        portable = self._portable_argv(argv)
        if not portable:
            raise ValueError("cannot execute empty argv")
        command = shlex.join(portable) + " 2>&1"
        response = self.sandbox.process.exec(
            command,
            cwd=self.remote_root,
            timeout=timeout_seconds,
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
