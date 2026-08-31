"""Pragmatic operator adapters used by dynamic Murmurations training environments."""

from __future__ import annotations

import ast
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Sequence

from murmurations.training.operator_retrieval import OperatorDescriptor, OperatorRegistry


_TEXT_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".h", ".hpp", ".go", ".java", ".js", ".jsx",
    ".md", ".py", ".rs", ".toml", ".ts", ".tsx", ".txt", ".yaml", ".yml", ".zig",
}
_SKIP_DIRS = {".git", ".venv", "node_modules", "target", "zig-cache", ".zig-cache"}


@dataclass(frozen=True)
class OperatorResult:
    ok: bool
    text: str
    exit_code: int | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


def detect_test_command(root: str | Path) -> list[str] | None:
    root = Path(root)
    if (root / "build.zig").exists():
        return ["zig", "build", "test"]
    if (root / "Cargo.toml").exists():
        return ["cargo", "test", "--quiet"]
    if (root / "go.mod").exists():
        return ["go", "test", "./..."]
    if (root / "pyproject.toml").exists() or (root / "pytest.ini").exists():
        return [sys.executable, "-m", "pytest", "-q"]
    if (root / "tests").is_dir():
        return [sys.executable, "-m", "unittest", "discover", "-s", "tests"]
    if (root / "gradlew").exists():
        return ["./gradlew", "test", "--no-daemon"]
    if (root / "mvnw").exists():
        return ["./mvnw", "test", "-q"]
    if (root / "pom.xml").exists():
        return ["mvn", "test", "-q"]
    package = root / "package.json"
    if package.exists():
        try:
            payload = json.loads(package.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}
        if "test" in payload.get("scripts", {}):
            return ["npm", "test", "--silent"]
    return None


def detect_check_command(root: str | Path) -> list[str] | None:
    root = Path(root)
    if (root / "build.zig").exists():
        return ["zig", "build"]
    if (root / "Cargo.toml").exists():
        return ["cargo", "check", "--quiet"]
    if (root / "go.mod").exists():
        return ["go", "test", "./..."]
    if (root / "pyproject.toml").exists() or any(root.glob("*.py")):
        return [sys.executable, "-m", "compileall", "-q", "."]
    if (root / "gradlew").exists():
        return ["./gradlew", "classes", "--no-daemon"]
    if (root / "mvnw").exists():
        return ["./mvnw", "test", "-q", "-DskipTests"]
    if (root / "pom.xml").exists():
        return ["mvn", "test", "-q", "-DskipTests"]
    return None


def default_operator_registry(root: str | Path) -> OperatorRegistry:
    root = Path(root)
    operators = [
        OperatorDescriptor(
            name="repo.search",
            description="Search repository source and documentation for text or symbols.",
            kind="python",
            tags=("search", "source", "symbol", "repository"),
            requires=("repo",),
            provides=("search.matches",),
            cost_millis=5,
        ),
        OperatorDescriptor(
            name="ast.python.symbols",
            description="Parse a Python file and return functions, classes, and referenced names.",
            kind="python",
            tags=("ast", "python", "symbol", "parse"),
            requires=("repo",),
            provides=("ast.symbols",),
            cost_millis=5,
        ),
        OperatorDescriptor(
            name="docs.search",
            description="Search repository documentation and package manifests.",
            kind="python",
            tags=("docs", "documentation", "package", "api"),
            requires=("repo",),
            provides=("docs.matches",),
            cost_millis=5,
        ),
    ]
    if detect_check_command(root):
        operators.append(
            OperatorDescriptor(
                name="repo.check",
                description="Run the repository compiler or fast static build check.",
                kind="subprocess",
                tags=("compiler", "build", "check"),
                requires=("repo",),
                provides=("check.result",),
                cost_millis=500,
            )
        )
    if detect_test_command(root):
        operators.append(
            OperatorDescriptor(
                name="repo.tests",
                description="Run the repository test suite and return exit status and output.",
                kind="subprocess",
                tags=("test", "tests", "verify", "compiler"),
                requires=("repo",),
                provides=("test.result",),
                cost_millis=1000,
            )
        )
    return OperatorRegistry(operators)


def _iter_text_files(root: Path):
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in _TEXT_EXTENSIONS:
            continue
        if any(part in _SKIP_DIRS for part in path.parts):
            continue
        yield path


def _search(root: Path, query: str, *, docs_only: bool, limit: int = 40) -> OperatorResult:
    pattern = re.compile(re.escape(query), re.IGNORECASE)
    matches: list[str] = []
    for path in _iter_text_files(root):
        rel = path.relative_to(root)
        if docs_only:
            docsish = (
                path.suffix.lower() in {".md", ".txt", ".toml", ".yaml", ".yml"}
                or "docs" in {part.lower() for part in rel.parts}
                or path.name.lower() in {"package.json", "pyproject.toml", "cargo.toml", "build.zig.zon"}
            )
            if not docsish:
                continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            if pattern.search(line):
                matches.append(f"{rel}:{line_no}:{line.strip()[:300]}")
                if len(matches) >= limit:
                    return OperatorResult(True, "\n".join(matches), metadata={"matches": len(matches)})
    return OperatorResult(True, "\n".join(matches), metadata={"matches": len(matches)})


def _python_ast(root: Path, argument: str) -> OperatorResult:
    relative, _, requested = argument.partition("::")
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return OperatorResult(False, "path escapes repository")
    if path.suffix != ".py" or not path.is_file():
        return OperatorResult(False, f"not a Python source file: {relative}")
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (OSError, UnicodeDecodeError, SyntaxError) as exc:
        return OperatorResult(False, f"AST parse failed: {exc}")

    rows: list[str] = []
    for node in ast.walk(tree):
        name = None
        kind = type(node).__name__
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            name = node.name
        elif isinstance(node, ast.Name):
            name = node.id
        if name is None:
            continue
        if requested and requested.lower() not in name.lower():
            continue
        line = getattr(node, "lineno", 0)
        rows.append(f"{kind}:{name}:{line}")
    rows = sorted(set(rows))[:200]
    return OperatorResult(True, "\n".join(rows), metadata={"symbols": len(rows)})


def _run(root: Path, argv: Sequence[str], timeout_seconds: int) -> OperatorResult:
    try:
        completed = subprocess.run(
            list(argv),
            cwd=root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except FileNotFoundError:
        return OperatorResult(False, f"command not found: {argv[0]}")
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        return OperatorResult(False, output[-8000:], metadata={"timeout": True})
    return OperatorResult(
        completed.returncode == 0,
        completed.stdout[-8000:],
        exit_code=completed.returncode,
        metadata={"argv": list(argv)},
    )


def execute_operator(
    name: str,
    argument: str,
    root: str | Path,
    *,
    timeout_seconds: int = 120,
) -> OperatorResult:
    root = Path(root).resolve()
    if name == "repo.search":
        return _search(root, argument, docs_only=False)
    if name == "docs.search":
        return _search(root, argument, docs_only=True)
    if name == "ast.python.symbols":
        return _python_ast(root, argument)
    if name == "repo.tests":
        command = detect_test_command(root)
        return (
            OperatorResult(False, "no test command detected")
            if command is None
            else _run(root, command, timeout_seconds)
        )
    if name == "repo.check":
        command = detect_check_command(root)
        return (
            OperatorResult(False, "no check command detected")
            if command is None
            else _run(root, command, timeout_seconds)
        )
    raise KeyError(f"unknown training operator: {name}")
