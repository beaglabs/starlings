"""Objective known-good -> broken repository mutation generator."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import random
import shutil
import subprocess
from typing import Sequence

from murmurations.utils.canonical import canonical_id


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
    argv: tuple[str, ...] = ()
    backend: str = "local"
    sandbox_argv: tuple[str, ...] = ()


def mutation_fingerprint(
    relative_path: str,
    line_number: int,
    kind: str,
    original_line: str,
    mutated_line: str,
) -> str:
    return canonical_id(
        {
            "version": 1,
            "path": relative_path,
            "line": line_number,
            "kind": kind,
            "original": original_line,
            "mutated": mutated_line,
        }
    )


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
    def fingerprint(self) -> str:
        return mutation_fingerprint(
            self.relative_path,
            self.line_number,
            self.kind,
            self.original_line,
            self.mutated_line,
        )

    @property
    def repair_text(self) -> str:
        return (
            f"Restore {self.relative_path}:{self.line_number} from "
            f"{self.mutated_line.strip()!r} to {self.original_line.strip()!r}."
        )


def _purge_python_bytecode(root: Path) -> None:
    for cache_dir in list(root.rglob("__pycache__")):
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
        return Verification(False, None, f"command not found: {argv[0]}", tuple(argv))
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout if isinstance(exc.stdout, str) else ""
        return Verification(
            False,
            None,
            (output or "")[-8000:] + "\n[TIMEOUT]",
            tuple(argv),
        )
    return Verification(
        completed.returncode == 0,
        completed.returncode,
        completed.stdout[-8000:],
        tuple(argv),
    )


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
    excluded_fingerprints: set[str] | None = None,
    verify_runner=None,
) -> Mutation:
    """Copy a clean repo and retain a unique mutation caught by its verifier."""

    source = Path(source_root).resolve()
    workspace = Path(workspace_root).resolve()
    if workspace.exists():
        shutil.rmtree(workspace)
    shutil.copytree(
        source,
        workspace,
        ignore=shutil.ignore_patterns(
            ".git", ".venv", "node_modules", "target", "zig-cache", ".zig-cache"
        ),
    )

    run_verify = verify if verify_runner is None else verify_runner
    clean = run_verify(workspace, verifier_argv, timeout_seconds)
    if not clean.passed:
        raise RuntimeError(
            "source repository verifier does not pass; cannot establish mutation ground truth"
        )

    excluded = excluded_fingerprints or set()
    candidates = _candidate_mutations(workspace)
    random.Random(seed).shuffle(candidates)
    attempted = 0
    for path, index, mutated_line, original_line, kind in candidates:
        relative_path = str(path.relative_to(workspace))
        fingerprint = mutation_fingerprint(
            relative_path,
            index + 1,
            kind,
            original_line,
            mutated_line,
        )
        if fingerprint in excluded:
            continue
        if attempted >= max_attempts:
            break
        attempted += 1

        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        if index >= len(lines) or lines[index] != original_line:
            continue
        lines[index] = mutated_line
        path.write_text("".join(lines), encoding="utf-8")
        broken = run_verify(workspace, verifier_argv, timeout_seconds)
        if not broken.passed:
            return Mutation(
                relative_path=relative_path,
                line_number=index + 1,
                kind=kind,
                original_line=original_line,
                mutated_line=mutated_line,
                clean_verification=clean,
                broken_verification=broken,
            )
        lines[index] = original_line
        path.write_text("".join(lines), encoding="utf-8")

    raise RuntimeError(
        "could not find a new verifier-caught mutation within max_attempts"
    )


def repair_mutation(workspace_root: str | Path, mutation: Mutation) -> None:
    path = Path(workspace_root) / mutation.relative_path
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    index = mutation.line_number - 1
    if index >= len(lines) or lines[index] != mutation.mutated_line:
        raise RuntimeError("workspace no longer matches the injected mutation")
    lines[index] = mutation.original_line
    path.write_text("".join(lines), encoding="utf-8")
