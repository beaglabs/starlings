"""Pragmatic operator adapters used by dynamic Murmurations training environments."""

from __future__ import annotations

import ast
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib
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


def _pyproject_uses_pytest(root: Path) -> bool:
    path = root / "pyproject.toml"
    if not path.exists():
        return False
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return False
    return "[tool.pytest.ini_options]" in text


def _load_toml(path: Path) -> dict[str, Any]:
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
        return {}


def _cargo_primary_package(root: Path) -> str | None:
    manifest = root / "Cargo.toml"
    if not manifest.exists():
        return None
    payload = _load_toml(manifest)
    if payload.get("package"):
        return None
    workspace = payload.get("workspace") or {}
    members = workspace.get("members") or []
    for member in members:
        if not isinstance(member, str) or "*" in member:
            continue
        leaf = Path(member).name.lower()
        if leaf.startswith((
            "bench", "example", "stress", "test-", "tests-", "fuzz", "tools",
        )):
            continue
        member_manifest = root / member / "Cargo.toml"
        member_payload = _load_toml(member_manifest)
        package = member_payload.get("package") or {}
        name = package.get("name")
        if name:
            return str(name)
    return None


def _maven_primary_module(root: Path) -> str | None:
    pom = root / "pom.xml"
    if not pom.exists():
        return None
    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(pom)
    except (OSError, ET.ParseError):
        return None
    element = tree.getroot()
    namespace = element.tag.split("}")[0].strip("{") if "}" in element.tag else ""
    prefix = f"{{{namespace}}}" if namespace else ""
    modules = element.find(f"{prefix}modules")
    if modules is None:
        return None
    candidates: list[str] = []
    for child in modules.findall(f"{prefix}module"):
        value = (child.text or "").strip()
        if not value:
            continue
        leaf = Path(value).name.lower()
        if leaf.startswith(("test-", "tests-", "benchmark", "benchmarks", "example", "examples")):
            continue
        if (root / value / "pom.xml").exists():
            candidates.append(value)
    return candidates[0] if candidates else None


def _has_python_test_dependency_group(root: Path) -> bool:
    path = root / "pyproject.toml"
    if not path.exists():
        return False
    payload = _load_toml(path)
    groups = payload.get("dependency-groups") or {}
    return isinstance(groups, dict) and "test" in groups


def detect_test_command(root: str | Path) -> list[str] | None:
    root = Path(root)
    if (root / "build.zig").exists():
        return ["zig", "build", "test"]
    if (root / "CMakeLists.txt").exists():
        return [
            "ctest",
            "--build-and-test",
            ".",
            ".murmurations-build",
            "--build-generator",
            "Ninja",
            "--build-noclean",
            "--build-options",
            "-DBUILD_TESTING=ON",
            "-DCMAKE_BUILD_TYPE=Debug",
            "--test-command",
            "ctest",
            "--output-on-failure",
        ]
    if (root / "Cargo.toml").exists():
        primary = _cargo_primary_package(root)
        if primary:
            return ["cargo", "test", "-p", primary, "--quiet"]
        return ["cargo", "test", "--quiet"]
    if (root / "go.mod").exists():
        return ["go", "test", "./..."]
    if (root / "pytest.ini").exists() or _pyproject_uses_pytest(root):
        return [sys.executable, "-m", "pytest", "-q"]
    tests_dir = root / "tests"
    if tests_dir.is_dir() and any(tests_dir.rglob("test*.py")):
        return [sys.executable, "-m", "unittest", "discover", "-s", "tests"]
    if (root / "gradlew").exists():
        return ["./gradlew", "test", "--no-daemon"]
    if (root / "mvnw").exists():
        return ["./mvnw", "test", "-q"]
    if (root / "pom.xml").exists():
        primary = _maven_primary_module(root)
        if primary:
            return ["mvn", "test", "-q", "--projects", primary, "--also-make"]
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


def detect_prepare_commands(root: str | Path) -> list[list[str]]:
    """Return deterministic dependency-preparation commands for a pinned repo."""
    root = Path(root)
    commands: list[list[str]] = []

    if (root / "CMakeLists.txt").exists():
        commands.append([
            "cmake", "-S", ".", "-B", ".murmurations-build", "-G", "Ninja",
            "-DBUILD_TESTING=ON", "-DCMAKE_BUILD_TYPE=Debug",
        ])

    if (root / "Cargo.toml").exists():
        command = ["cargo", "fetch"]
        if (root / "Cargo.lock").exists():
            command.append("--locked")
        commands.append(command)

    if (root / "go.mod").exists():
        commands.append(["go", "mod", "download"])

    package = root / "package.json"
    if package.exists():
        if (root / "package-lock.json").exists() or (root / "npm-shrinkwrap.json").exists():
            commands.append(["npm", "ci", "--no-audit", "--no-fund"])
        else:
            commands.append(["npm", "install", "--no-audit", "--no-fund"])

    if (root / "requirements.txt").exists():
        commands.append(["python3", "-m", "pip", "install", "--break-system-packages", "-r", "requirements.txt"])
    if (root / "pyproject.toml").exists():
        commands.append(["python3", "-m", "pip", "install", "--break-system-packages", "-e", "."])
        if _has_python_test_dependency_group(root):
            commands.append([
                "python3", "-m", "pip", "install", "--break-system-packages",
                "--group", "test",
            ])

    if (root / "gradlew").exists():
        commands.append(["./gradlew", "dependencies", "--no-daemon"])
    elif (root / "mvnw").exists():
        command = ["./mvnw", "-q", "-DskipTests", "dependency:go-offline"]
        primary = _maven_primary_module(root)
        if primary:
            command.extend(["--projects", primary, "--also-make"])
        commands.append(command)
    elif (root / "pom.xml").exists():
        command = ["mvn", "-q", "-DskipTests", "dependency:go-offline"]
        primary = _maven_primary_module(root)
        if primary:
            command.extend(["--projects", primary, "--also-make"])
        commands.append(command)

    return commands


def detect_check_command(root: str | Path) -> list[str] | None:
    root = Path(root)
    if (root / "build.zig").exists():
        return ["zig", "build"]
    if (root / "CMakeLists.txt").exists():
        return ["cmake", "--build", ".murmurations-build", "--parallel", "2"]
    if (root / "Cargo.toml").exists():
        return ["cargo", "check", "--quiet"]
    if (root / "go.mod").exists():
        return ["go", "test", "-run", "^$", "./..."]
    if (root / "pyproject.toml").exists() or any(root.glob("*.py")):
        return [sys.executable, "-m", "compileall", "-q", "."]
    if (root / "gradlew").exists():
        return ["./gradlew", "classes", "--no-daemon"]
    if (root / "mvnw").exists():
        return ["./mvnw", "test", "-q", "-DskipTests"]
    if (root / "pom.xml").exists():
        return ["mvn", "test", "-q", "-DskipTests"]
    package = root / "package.json"
    if package.exists():
        try:
            payload = json.loads(package.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            payload = {}
        dependencies = dict(payload.get("dependencies") or {})
        dependencies.update(payload.get("devDependencies") or {})
        if "typescript" in dependencies or (root / "tsconfig.json").exists():
            return ["npx", "--no-install", "tsc", "--noEmit"]
    return None


def detect_package_metadata_command(root: str | Path) -> list[str] | None:
    root = Path(root)
    if (root / "Cargo.toml").exists():
        return ["cargo", "metadata", "--format-version", "1", "--no-deps"]
    if (root / "go.mod").exists():
        return ["go", "list", "-m", "-json"]
    if (root / "package.json").exists():
        return [
            "npm",
            "pkg",
            "get",
            "name",
            "version",
            "type",
            "dependencies",
            "devDependencies",
        ]
    if (root / "pyproject.toml").exists():
        script = (
            "import json,tomllib,pathlib;"
            "d=tomllib.loads(pathlib.Path('pyproject.toml').read_text());"
            "p=d.get('project',{});"
            "print(json.dumps({k:p.get(k) for k in "
            "('name','version','requires-python','dependencies','optional-dependencies') "
            "if k in p},sort_keys=True))"
        )
        return [sys.executable, "-c", script]
    if (root / "pom.xml").exists():
        script = (
            "import json,xml.etree.ElementTree as E,pathlib;"
            "r=E.parse('pom.xml').getroot();"
            "ns=r.tag.split('}')[0].strip('{') if '}' in r.tag else '';"
            "q=(lambda n:r.find(('{'+ns+'}' if ns else '')+n));"
            "v=(lambda n:(q(n).text.strip() if q(n) is not None and q(n).text else None));"
            "print(json.dumps({'groupId':v('groupId'),'artifactId':v('artifactId'),"
            "'version':v('version')},sort_keys=True))"
        )
        return [sys.executable, "-c", script]
    if (root / "build.zig.zon").exists():
        script = (
            "import json,pathlib,re;"
            "s=pathlib.Path('build.zig.zon').read_text();"
            "g=lambda k:(re.search(r'\\.'+k+r'\\s*=\\s*([^,\\n]+)',s).group(1).strip() "
            "if re.search(r'\\.'+k+r'\\s*=\\s*([^,\\n]+)',s) else None);"
            "print(json.dumps({'name':g('name'),'version':g('version')},sort_keys=True))"
        )
        return [sys.executable, "-c", script]
    return None


def _docs_backend(root: Path) -> str | None:
    if (root / "go.mod").exists():
        return "go"
    if (root / "pyproject.toml").exists() or any(root.glob("*.py")):
        return "python"
    return None


def detect_docs_lookup_command(root: str | Path, query: str) -> list[str] | None:
    root = Path(root)
    backend = _docs_backend(root)
    if backend == "go":
        return ["go", "doc", query]
    if backend == "python":
        return [sys.executable, "-m", "pydoc", query]
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
                name="type.check",
                description="Run the local compiler or type checker and return semantic diagnostics.",
                kind="subprocess",
                tags=("type", "types", "compiler", "diagnostics", "check"),
                requires=("repo",),
                provides=("type.diagnostics",),
                cost_millis=500,
                metadata={"backend": "terminal_argv"},
            )
        )
    if detect_package_metadata_command(root):
        operators.append(
            OperatorDescriptor(
                name="package.metadata",
                description="Inspect local package identity, version, dependencies, and manifest metadata.",
                kind="subprocess",
                tags=("package", "dependency", "dependencies", "metadata", "manifest"),
                requires=("repo",),
                provides=("package.metadata",),
                cost_millis=25,
                metadata={"backend": "terminal_argv"},
            )
        )
    if _docs_backend(root):
        operators.append(
            OperatorDescriptor(
                name="docs.lookup",
                description="Look up local language or package documentation for a module, package, or symbol.",
                kind="subprocess",
                tags=("docs", "documentation", "api", "symbol", "package"),
                requires=("repo",),
                provides=("docs.lookup",),
                cost_millis=50,
                metadata={"backend": "terminal_argv"},
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
                metadata={"backend": "terminal_argv"},
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
                or path.name.lower() in {
                    "package.json", "pyproject.toml", "cargo.toml",
                    "build.zig.zon", "pom.xml", "go.mod"
                }
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


def _run(
    root: Path,
    argv: Sequence[str],
    timeout_seconds: int,
    command_runner=None,
) -> OperatorResult:
    if command_runner is not None:
        return command_runner(root, argv, timeout_seconds)
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
        return OperatorResult(False, f"command not found: {argv[0]}", metadata={"argv": list(argv)})
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        return OperatorResult(
            False,
            output[-8000:],
            metadata={"timeout": True, "argv": list(argv)},
        )
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
    command_runner=None,
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
            else _run(root, command, timeout_seconds, command_runner)
        )
    if name in {"type.check", "repo.check"}:
        command = detect_check_command(root)
        return (
            OperatorResult(False, "no type/compiler check command detected")
            if command is None
            else _run(root, command, timeout_seconds, command_runner)
        )
    if name == "package.metadata":
        command = detect_package_metadata_command(root)
        return (
            OperatorResult(False, "no package metadata command detected")
            if command is None
            else _run(root, command, timeout_seconds, command_runner)
        )
    if name == "docs.lookup":
        command = detect_docs_lookup_command(root, argument)
        return (
            OperatorResult(False, "no local documentation command detected")
            if command is None
            else _run(root, command, timeout_seconds, command_runner)
        )
    raise KeyError(f"unknown training operator: {name}")
