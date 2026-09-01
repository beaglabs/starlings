"""Deterministic repository execution planning shared by host and Daytona."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import tomllib
from typing import Any


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
        if leaf.startswith((
            "test-", "tests-", "benchmark", "benchmarks", "example", "examples",
        )):
            continue
        if (root / value / "pom.xml").exists():
            candidates.append(value)
    return candidates[0] if candidates else None


def _python_test_dependency_group(root: Path) -> str | None:
    path = root / "pyproject.toml"
    if not path.exists():
        return None
    payload = _load_toml(path)
    groups = payload.get("dependency-groups") or {}
    if not isinstance(groups, dict):
        return None
    for name in ("tests", "test"):
        if name in groups:
            return name
    return None


def _python_bin(_root: Path) -> str:
    return ".murmurations-venv/bin/python3"


def _package_payload(root: Path) -> dict[str, Any]:
    package = root / "package.json"
    if not package.exists():
        return {}
    try:
        return json.loads(package.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _package_manager(root: Path) -> str:
    payload = _package_payload(root)
    declared = str(payload.get("packageManager") or "")
    if declared.startswith("pnpm@") or (root / "pnpm-lock.yaml").exists():
        return "pnpm"
    return "npm"


def _package_manager_prefix(root: Path) -> list[str]:
    if _package_manager(root) != "pnpm":
        return ["npm"]
    declared = str(_package_payload(root).get("packageManager") or "")
    if declared.startswith("pnpm@") and len(declared) > len("pnpm@"):
        return ["npx", "--yes", declared]
    return ["pnpm"]


def _minimum_zig_version(root: Path) -> str | None:
    zon = root / "build.zig.zon"
    if not zon.exists():
        return None
    try:
        text = zon.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    match = __import__("re").search(
        r'\.minimum_zig_version\s*=\s*"([^"]+)"',
        text,
    )
    return match.group(1) if match else None


def _zig_bin(root: Path) -> str:
    version = _minimum_zig_version(root)
    return f"/opt/zig/{version}/zig" if version else "zig"


_CMAKE_VERIFY_CODE = (
    "import subprocess,sys;"
    "cmds=[['cmake','--build','.murmurations-build','--parallel','2'],"
    "['ctest','--test-dir','.murmurations-build','--output-on-failure']];"
    "\nfor cmd in cmds:"
    "\n p=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);"
    "\n sys.stdout.write(p.stdout or '');"
    "\n if p.returncode: sys.exit(p.returncode)"
)


def _cmake_configure_command(root: Path) -> list[str]:
    command = [
        "cmake", "-S", ".", "-B", ".murmurations-build", "-G", "Ninja",
        "-DBUILD_TESTING=ON", "-DCMAKE_BUILD_TYPE=Debug",
    ]
    try:
        text = (root / "CMakeLists.txt").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        text = ""
    if "LIBUV_BUILD_TESTS" in text:
        command.extend([
            "-DLIBUV_BUILD_TESTS=ON",
            "-DLIBUV_BUILD_BENCH=OFF",
            "-DENABLE_CLANG_TIDY=OFF",
        ])
    if "DISABLE_TESTS" in text:
        command.append("-DDISABLE_TESTS=OFF")
    return command


def detect_test_command(root: str | Path) -> list[str] | None:
    root = Path(root)
    if (root / "build.zig").exists():
        return [_zig_bin(root), "build", "test"]
    if (root / "CMakeLists.txt").exists():
        return ["python3", "-c", _CMAKE_VERIFY_CODE]
    if (root / "Cargo.toml").exists():
        primary = _cargo_primary_package(root)
        if primary:
            return ["cargo", "test", "-p", primary, "--quiet"]
        return ["cargo", "test", "--quiet"]
    if (root / "go.mod").exists():
        return ["go", "test", "./..."]
    if (
        (root / "pytest.ini").exists()
        or _pyproject_uses_pytest(root)
        or (root / "conftest.py").exists()
    ):
        return [_python_bin(root), "-m", "pytest", "-q"]
    tests_dir = root / "tests"
    if tests_dir.is_dir() and any(tests_dir.rglob("test*.py")):
        if (tests_dir / "conftest.py").exists() or (root / "pyproject.toml").exists():
            return [_python_bin(root), "-m", "pytest", "-q"]
        return [_python_bin(root), "-m", "unittest", "discover", "-s", "tests"]
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
        payload = _package_payload(root)
        scripts = dict(payload.get("scripts") or {})
        if _package_manager(root) == "pnpm":
            prefix = _package_manager_prefix(root)
            if "test:unit" in scripts:
                return prefix + ["run", "test:unit"]
            if "test-unit" in scripts:
                return prefix + ["run", "test-unit"]
            if "test" in scripts:
                return prefix + ["run", "test"]
        elif "test" in scripts:
            return ["npm", "test", "--silent"]
    return None


def detect_prepare_commands(root: str | Path) -> list[list[str]]:
    """Return deterministic dependency-preparation commands for a pinned repo."""
    root = Path(root)
    commands: list[list[str]] = []

    if (root / ".gitmodules").exists():
        commands.append(["git", "submodule", "update", "--init", "--recursive"])

    if (root / "CMakeLists.txt").exists() and not (root / "build.zig").exists():
        commands.append(_cmake_configure_command(root))
        commands.append([
            "cmake", "--build", ".murmurations-build", "--parallel", "2",
        ])

    if (root / "build.zig").exists():
        commands.append([_zig_bin(root), "build", "--fetch"])

    if (root / "Cargo.toml").exists():
        command = ["cargo", "fetch"]
        if (root / "Cargo.lock").exists():
            command.append("--locked")
        commands.append(command)

    if (root / "go.mod").exists():
        commands.append(["go", "mod", "download"])

    package = root / "package.json"
    if package.exists():
        manager = _package_manager(root)
        if manager == "pnpm":
            commands.append(
                _package_manager_prefix(root)
                + ["install", "--frozen-lockfile"]
            )
        elif (root / "package-lock.json").exists() or (root / "npm-shrinkwrap.json").exists():
            commands.append(["npm", "ci", "--no-audit", "--no-fund"])
        else:
            commands.append(["npm", "install", "--no-audit", "--no-fund"])

    is_python_repo = (root / "pyproject.toml").exists() or (root / "requirements.txt").exists()
    if is_python_repo:
        python = _python_bin(root)
        commands.append(["python3", "-m", "venv", ".murmurations-venv"])
        commands.append([python, "-m", "pip", "install", "--upgrade", "pip"])
        if (root / "requirements.txt").exists():
            commands.append([python, "-m", "pip", "install", "-r", "requirements.txt"])
        if (root / "pyproject.toml").exists():
            commands.append([python, "-m", "pip", "install", "-e", "."])
            test_group = _python_test_dependency_group(root)
            if test_group is not None:
                commands.append([python, "-m", "pip", "install", "--group", test_group])

    return commands


def detect_check_command(root: str | Path) -> list[str] | None:
    root = Path(root)
    if (root / "build.zig").exists():
        return [_zig_bin(root), "build"]
    if (root / "CMakeLists.txt").exists():
        return ["cmake", "--build", ".murmurations-build", "--parallel", "2"]
    if (root / "Cargo.toml").exists():
        return ["cargo", "check", "--quiet"]
    if (root / "go.mod").exists():
        return ["go", "test", "-run", "^$", "./..."]
    if (root / "pyproject.toml").exists() or any(root.glob("*.py")):
        return [_python_bin(root), "-m", "compileall", "-q", "."]
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
            manager = _package_manager(root)
            if manager == "pnpm":
                return _package_manager_prefix(root) + ["exec", "tsc", "--noEmit"]
            return ["npx", "--no-install", "tsc", "--noEmit"]
    return None


def plan_repository(root: str | Path) -> dict[str, Any]:
    root = Path(root)
    return {
        "prepare_commands": detect_prepare_commands(root),
        "test_command": detect_test_command(root),
        "check_command": detect_check_command(root),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()
    print(json.dumps(plan_repository(args.root), sort_keys=True))


if __name__ == "__main__":
    main()
