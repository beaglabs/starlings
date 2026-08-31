"""Objective known-good -> broken repository mutation generator."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import random
import shutil
import subprocess
from typing import Sequence


_SOURCE_EXTENSIONS = {".c", ".cc", ".cpp", ".go", ".h", ".hpp", ".js", ".py", ".rs", ".ts", ".zig"}
_SKIP_DIRS = {".git", ".venv", "node_modules", "target", "zig-cache", ".zig-cache", "test", "tests"}
_RULES = (
    ("==", "!=", "eq_to_ne"),
    ("!=", "==", "ne_to_eq"),
    ("<=", "<", "le_to_lt"),
    (">=", ">", "ge_to_gt"),
)


@dataclass(frozen=True)
class Verification:
    passed: bool
    exit_code: int | None
    output: str


@dataclass(frozen=True)
class Mutation:
    relative_path: str
    line_number: int
    kind: str
    original_line: str
    mutated_line: str
    clean_verification: Verification
    broken_verification: Verification

    @property
    def repair_text(self) -> str:
        return (
            f"Restore {self.relative_path}:{self.line_number} from "
            f"{self.mutated_line.strip()!r} to {self.original_line.strip()!r}."
        )


def _purge_python_bytecode(root: Path) -> None:
    """Remove stale Python bytecode before verifier runs.

    Mutation rules often preserve source-file size (for example == -> !=).
    Python's timestamp/size pyc validation can therefore reuse bytecode from
    the clean verification when a mutation is written within the same
    filesystem timestamp tick. That creates false negatives in mutation
    testing, especially on macOS.
    """

    for cache_dir in root.rglob("__pycache__"):
        if cache_dir.is_dir():
            shutil.rmtree(cache_dir, ignore_errors=True)
    for pyc in root.rglob("*.pyc"):
        try:
            pyc.unlink()
        except FileNotFoundError:
            pass


def verify(root: str | Path, argv: Sequence[str], timeout_seconds: int) -> Verification:
    root_path = Path(root)
    _purge_python_bytecode(root_path)
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        completed = subprocess.run(
            list(argv),
            cwd=root_path,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_seconds,
            check=False,
            env=env,
        )
    except FileNotFoundError:
        return Verification(False, None, f"command not found: {argv[0]}")
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout if isinstance(exc.stdout, str) else ""
        return Verification(False, None, (output or "")[-8000:] + "\n[TIMEOUT]")
    return Verification(completed.returncode == 0, completed.returncode, completed.stdout[-8000:])


def _candidate_mutations(root: Path) -> list[tuple[Path, int, str, str, str]]:
    out: list[tuple[Path, int, str, str, str]] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in _SOURCE_EXTENSIONS:
            continue
        relative_parts = path.relative_to(root).parts
        if any(part in _SKIP_DIRS for part in relative_parts):
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        except (OSError, UnicodeDecodeError):
            continue
        for index, line in enumerate(lines):
            stripped = line.lstrip()
            if stripped.startswith(("#", "//", "/*", "*")):
                continue
            for before, after, kind in _RULES:
                if before not in line:
                    continue
                mutated = line.replace(before, after, 1)
                if mutated != line:
                    out.append((path, index, mutated, line, kind))
    return out


def inject_verified_mutation(
    source_root: str | Path,
    workspace_root: str | Path,
    verifier_argv: Sequence[str],
    *,
    seed: int,
    timeout_seconds: int = 120,
    max_attempts: int = 64,
) -> Mutation:
    """Copy a clean repo and retain only a mutation that verifier catches."""

    source = Path(source_root).resolve()
    workspace = Path(workspace_root).resolve()
    if workspace.exists():
        shutil.rmtree(workspace)
    shutil.copytree(
        source,
        workspace,
        ignore=shutil.ignore_patterns(".git", ".venv", "node_modules", "target", "zig-cache", ".zig-cache"),
    )

    clean = verify(workspace, verifier_argv, timeout_seconds)
    if not clean.passed:
        raise RuntimeError("source repository verifier does not pass; cannot establish mutation ground truth")

    candidates = _candidate_mutations(workspace)
    random.Random(seed).shuffle(candidates)
    for path, index, mutated_line, original_line, kind in candidates[:max_attempts]:
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        if index >= len(lines) or lines[index] != original_line:
            continue
        lines[index] = mutated_line
        path.write_text("".join(lines), encoding="utf-8")
        broken = verify(workspace, verifier_argv, timeout_seconds)
        if not broken.passed:
            return Mutation(
                relative_path=str(path.relative_to(workspace)),
                line_number=index + 1,
                kind=kind,
                original_line=original_line,
                mutated_line=mutated_line,
                clean_verification=clean,
                broken_verification=broken,
            )
        lines[index] = original_line
        path.write_text("".join(lines), encoding="utf-8")

    raise RuntimeError("could not find a verifier-caught mutation within max_attempts")


def repair_mutation(workspace_root: str | Path, mutation: Mutation) -> None:
    path = Path(workspace_root) / mutation.relative_path
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    index = mutation.line_number - 1
    if index >= len(lines) or lines[index] != mutation.mutated_line:
        raise RuntimeError("workspace no longer matches the injected mutation")
    lines[index] = mutation.original_line
    path.write_text("".join(lines), encoding="utf-8")
