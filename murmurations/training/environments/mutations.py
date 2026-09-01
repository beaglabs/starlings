"""Objective known-good -> broken repository mutation generator."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import random
import shutil
import subprocess
from typing import Iterable, Sequence

from murmurations.utils.canonical import canonical_id


_SOURCE_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".go", ".h", ".hpp", ".java", ".js", ".jsx",
    ".py", ".rs", ".ts", ".tsx", ".zig",
}
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
    sandbox_id: str | None = None
    sandbox_snapshot: str | None = None


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
class MutationCandidate:
    relative_path: str
    line_number: int
    kind: str
    original_line: str
    mutated_line: str
    source: str = "deterministic"
    targeted_test_argv: tuple[str, ...] = ()

    @property
    def fingerprint(self) -> str:
        return mutation_fingerprint(
            self.relative_path,
            self.line_number,
            self.kind,
            self.original_line,
            self.mutated_line,
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
    candidate_source: str = "deterministic"

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


def enumerate_mutation_candidates(root: str | Path) -> list[MutationCandidate]:
    root_path = Path(root).resolve()
    out: list[MutationCandidate] = []
    for path in root_path.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in _SOURCE_EXTENSIONS:
            continue
        relative_parts = path.relative_to(root_path).parts
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
                    out.append(
                        MutationCandidate(
                            relative_path=str(path.relative_to(root_path)),
                            line_number=index + 1,
                            kind=kind,
                            original_line=line,
                            mutated_line=mutated,
                        )
                    )
    return out


def partition_mutation_candidates(
    candidates: Iterable[MutationCandidate],
    *,
    partition_id: int = 0,
    partition_count: int = 1,
) -> list[MutationCandidate]:
    if partition_count <= 0:
        raise ValueError("partition_count must be positive")
    if partition_id < 0 or partition_id >= partition_count:
        raise ValueError("partition_id must be in [0, partition_count)")
    return [
        candidate
        for candidate in candidates
        if int(candidate.fingerprint[:16], 16) % partition_count == partition_id
    ]


def infer_targeted_test_argv(
    root: str | Path,
    candidate: MutationCandidate,
    verifier_argv: Sequence[str],
) -> tuple[str, ...]:
    root_path = Path(root).resolve()
    verifier = tuple(str(item) for item in verifier_argv)

    if "pytest" in verifier:
        source_stem = Path(candidate.relative_path).stem.lower()
        matches: list[str] = []
        for base in ("tests", "test"):
            test_root = root_path / base
            if not test_root.is_dir():
                continue
            for path in test_root.rglob("test*.py"):
                if source_stem and source_stem in path.stem.lower():
                    matches.append(str(path.relative_to(root_path)))
        if matches:
            executable = verifier[0]
            prefix = [executable, "-m", "pytest"] if "-m" in verifier else [executable]
            return tuple(prefix + ["-q", sorted(matches)[0]])

    if len(verifier) >= 2 and verifier[:2] == ("go", "test"):
        relative_dir = Path(candidate.relative_path).parent
        if str(relative_dir) not in ("", "."):
            return ("go", "test", f"./{relative_dir.as_posix()}")

    return ()


def reset_mutation_workspace(
    source_root: str | Path,
    workspace_root: str | Path,
) -> Path:
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
    return workspace


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
    clean_verification: Verification | None = None,
    candidates: Sequence[MutationCandidate] | None = None,
    partition_id: int = 0,
    partition_count: int = 1,
    triage_runner=None,
) -> Mutation:
    """Copy a clean repo and retain a unique mutation caught by its verifier."""

    source = Path(source_root).resolve()
    workspace = reset_mutation_workspace(source, workspace_root)

    run_verify = verify if verify_runner is None else verify_runner
    clean = clean_verification
    if clean is None:
        clean = run_verify(workspace, verifier_argv, timeout_seconds)
    if not clean.passed:
        raise RuntimeError(
            "source repository verifier does not pass; cannot establish mutation ground truth"
        )

    excluded = excluded_fingerprints or set()
    candidate_pool = (
        list(candidates)
        if candidates is not None
        else enumerate_mutation_candidates(workspace)
    )
    candidate_pool = partition_mutation_candidates(
        candidate_pool,
        partition_id=partition_id,
        partition_count=partition_count,
    )
    rng = random.Random(seed)
    semantic = [candidate for candidate in candidate_pool if candidate.source != "deterministic"]
    deterministic = [candidate for candidate in candidate_pool if candidate.source == "deterministic"]
    rng.shuffle(semantic)
    rng.shuffle(deterministic)
    candidate_pool = (
        semantic + deterministic
        if seed % 2 == 0
        else deterministic + semantic
    )
    attempted = 0
    for candidate in candidate_pool:
        fingerprint = candidate.fingerprint
        if fingerprint in excluded:
            continue
        if attempted >= max_attempts:
            break
        attempted += 1

        path = workspace / candidate.relative_path
        index = candidate.line_number - 1
        try:
            lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        except (OSError, UnicodeDecodeError):
            continue
        if index >= len(lines) or lines[index] != candidate.original_line:
            continue
        lines[index] = candidate.mutated_line
        path.write_text("".join(lines), encoding="utf-8")

        targeted_test_argv = (
            candidate.targeted_test_argv
            or infer_targeted_test_argv(workspace, candidate, verifier_argv)
        )
        if (
            targeted_test_argv
            and tuple(targeted_test_argv) != tuple(verifier_argv)
            and triage_runner is not None
        ):
            triage = triage_runner(
                workspace,
                targeted_test_argv,
                timeout_seconds,
            )
            if triage.passed:
                lines[index] = candidate.original_line
                path.write_text("".join(lines), encoding="utf-8")
                continue

        broken = run_verify(workspace, verifier_argv, timeout_seconds)
        if not broken.passed:
            return Mutation(
                relative_path=candidate.relative_path,
                line_number=candidate.line_number,
                kind=candidate.kind,
                original_line=candidate.original_line,
                mutated_line=candidate.mutated_line,
                clean_verification=clean,
                broken_verification=broken,
                candidate_source=candidate.source,
            )
        lines[index] = candidate.original_line
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
