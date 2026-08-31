"""ZViz-backed execution for serious Murmurations corpus generation."""

from __future__ import annotations

from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
from typing import Any, Sequence


_EXIT_PATTERNS = (
    re.compile(r"Container exited with code (\d+)"),
    re.compile(r"exit_code:\s*(\d+)"),
)
_ZVIZ_LOG = re.compile(r"^\[\d+\] \[(?:DEBUG|INFO|WARN|ERROR)\] ")


@dataclass(frozen=True)
class ZVizExecution:
    ok: bool
    exit_code: int | None
    output: str
    argv: tuple[str, ...]
    runtime_argv: tuple[str, ...]
    container_id: str
    config_sha256: str


class ZVizCorpusRunner:
    """Run repository commands in one pinned OCI rootfs through ZViz."""

    def __init__(
        self,
        *,
        binary: str | Path,
        bundle: str | Path,
        state_dir: str | Path,
        profile: str = "ci-runner",
        source_commit: str | None = None,
    ) -> None:
        self.binary = str(binary)
        self.bundle = Path(bundle).expanduser().resolve()
        self.state_dir = Path(state_dir).expanduser().resolve()
        self.profile = profile
        self.source_commit = source_commit
        self._counter = 0

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "ZVizCorpusRunner":
        if str(config.get("runtime", "")) != "zviz":
            raise ValueError("serious corpus sandbox.runtime must be 'zviz'")
        return cls(
            binary=config.get("binary", "zviz"),
            bundle=config["bundle"],
            state_dir=config.get("state_dir", ".cache/murmurations/zviz/state"),
            profile=config.get("profile", "ci-runner"),
            source_commit=config.get("source_commit"),
        )

    def validate_environment(self) -> None:
        if platform.system() != "Linux":
            raise RuntimeError("ZViz corpus generation requires a Linux host")
        binary_path = (
            Path(self.binary).expanduser()
            if os.sep in self.binary
            else Path(shutil.which(self.binary) or "")
        )
        if not binary_path or not binary_path.is_file():
            raise RuntimeError(f"ZViz binary not found: {self.binary}")
        rootfs = self.bundle / "rootfs"
        if not rootfs.is_dir():
            raise RuntimeError(f"ZViz corpus rootfs not found: {rootfs}")
        self.state_dir.mkdir(parents=True, exist_ok=True)

    def provenance(self) -> dict[str, Any]:
        return {
            "runtime": "zviz",
            "profile": self.profile,
            "bundle": str(self.bundle),
            "source_commit": self.source_commit,
        }

    def _container_id(self, workspace: Path, argv: Sequence[str]) -> str:
        self._counter += 1
        payload = json.dumps(
            {
                "pid": os.getpid(),
                "counter": self._counter,
                "workspace": str(workspace),
                "argv": list(argv),
            },
            sort_keys=True,
        ).encode("utf-8")
        return "murmurations-" + hashlib.sha256(payload).hexdigest()[:20]

    def render_oci_config(
        self,
        workspace: str | Path,
        argv: Sequence[str],
    ) -> dict[str, Any]:
        workspace = Path(workspace).expanduser().resolve()
        return {
            "ociVersion": "1.0.2",
            "process": {
                "terminal": False,
                "user": {"uid": 0, "gid": 0},
                "args": [str(item) for item in argv],
                "env": [
                    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    "HOME=/tmp/work/.murmurations-home",
                    "XDG_CACHE_HOME=/tmp/work/.murmurations-cache",
                    "CARGO_HOME=/tmp/work/.murmurations-cache/cargo",
                    "GOPATH=/tmp/work/.murmurations-cache/go",
                    "GRADLE_USER_HOME=/tmp/work/.murmurations-cache/gradle",
                    "npm_config_cache=/tmp/work/.murmurations-cache/npm",
                    "PYTHONDONTWRITEBYTECODE=1",
                ],
                "cwd": "/tmp/work",
            },
            "root": {"path": "rootfs", "readonly": True},
            "hostname": "murmurations-corpus",
            "mounts": [
                {
                    "destination": "/tmp/work",
                    "type": "bind",
                    "source": str(workspace),
                    "options": ["rbind", "rw", "nosuid", "nodev"],
                }
            ],
            "linux": {
                "namespaces": [
                    {"type": "pid"},
                    {"type": "mount"},
                    {"type": "ipc"},
                    {"type": "uts"},
                ],
                "resources": {
                    "memory": {"limit": 4294967296},
                    "pids": {"limit": 512},
                },
            },
        }

    @staticmethod
    def _workload_exit_code(output: str) -> int | None:
        matches: list[int] = []
        for pattern in _EXIT_PATTERNS:
            matches.extend(int(match.group(1)) for match in pattern.finditer(output))
        return matches[-1] if matches else None

    @staticmethod
    def _clean_output(output: str) -> str:
        return "\n".join(
            line for line in output.splitlines()
            if not _ZVIZ_LOG.match(line)
        )[-8000:]

    def run(
        self,
        workspace: str | Path,
        argv: Sequence[str],
        timeout_seconds: int,
    ) -> ZVizExecution:
        workspace_path = Path(workspace).expanduser().resolve()
        config = self.render_oci_config(workspace_path, argv)
        config_bytes = (
            json.dumps(config, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")
        config_sha256 = hashlib.sha256(config_bytes).hexdigest()
        container_id = self._container_id(workspace_path, argv)
        runtime_argv = (
            self.binary,
            "--root",
            str(self.state_dir),
            "--profile",
            self.profile,
            "run",
            container_id,
            str(self.bundle),
        )
        lock_path = self.bundle / ".murmurations.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)

        with lock_path.open("a+", encoding="utf-8") as lock_handle:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
            config_path = self.bundle / "config.json"
            fd, tmp_name = tempfile.mkstemp(
                prefix=".config.",
                suffix=".json",
                dir=self.bundle,
            )
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(config_bytes)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(tmp_name, config_path)

                try:
                    completed = subprocess.run(
                        list(runtime_argv),
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        timeout=timeout_seconds + 15,
                        check=False,
                    )
                    raw_output = completed.stdout or ""
                except FileNotFoundError:
                    return ZVizExecution(
                        False,
                        None,
                        f"ZViz binary not found: {self.binary}",
                        tuple(str(x) for x in argv),
                        runtime_argv,
                        container_id,
                        config_sha256,
                    )
                except subprocess.TimeoutExpired as exc:
                    raw_output = exc.stdout if isinstance(exc.stdout, str) else ""
                    return ZVizExecution(
                        False,
                        None,
                        self._clean_output(raw_output + "\n[ZVIZ TIMEOUT]"),
                        tuple(str(x) for x in argv),
                        runtime_argv,
                        container_id,
                        config_sha256,
                    )
                finally:
                    subprocess.run(
                        [
                            self.binary,
                            "--root",
                            str(self.state_dir),
                            "delete",
                            container_id,
                        ],
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=10,
                        check=False,
                    )

                workload_code = self._workload_exit_code(raw_output)
                output = self._clean_output(raw_output)
                if workload_code is None:
                    runtime_note = (
                        f"ZViz runtime exited {completed.returncode} without "
                        "reporting a workload exit code"
                    )
                    output = (output + "\n" + runtime_note).strip()[-8000:]
                    return ZVizExecution(
                        False,
                        None,
                        output,
                        tuple(str(x) for x in argv),
                        runtime_argv,
                        container_id,
                        config_sha256,
                    )
                return ZVizExecution(
                    workload_code == 0,
                    workload_code,
                    output,
                    tuple(str(x) for x in argv),
                    runtime_argv,
                    container_id,
                    config_sha256,
                )
            finally:
                try:
                    os.unlink(tmp_name)
                except FileNotFoundError:
                    pass

    def verify(self, workspace: str | Path, argv: Sequence[str], timeout_seconds: int):
        from murmurations.training.environments.mutations import Verification

        result = self.run(workspace, argv, timeout_seconds)
        return Verification(
            passed=result.ok,
            exit_code=result.exit_code,
            output=result.output,
            argv=result.argv,
            backend="zviz",
            sandbox_argv=result.runtime_argv,
        )

    def run_operator(self, workspace: str | Path, argv: Sequence[str], timeout_seconds: int):
        from murmurations.training.operators import OperatorResult

        result = self.run(workspace, argv, timeout_seconds)
        return OperatorResult(
            result.ok,
            result.output,
            exit_code=result.exit_code,
            metadata={
                "argv": list(result.argv),
                "sandbox_backend": "zviz",
                "sandbox_argv": list(result.runtime_argv),
                "sandbox_config_sha256": result.config_sha256,
            },
        )
