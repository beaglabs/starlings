from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from murmurations.training.operators import (
    detect_check_command,
    detect_prepare_commands,
    detect_test_command,
)


class RepositoryPlanTests(unittest.TestCase):
    def test_cmake_projects_configure_with_ninja_and_verify_test_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "CMakeLists.txt").write_text(
                "cmake_minimum_required(VERSION 3.10)\n"
                "project(example LANGUAGES C)\n"
                "include(CTest)\n"
                "add_executable(example main.c)\n"
                "add_test(NAME example COMMAND example)\n",
                encoding="utf-8",
            )

            self.assertEqual(
                detect_prepare_commands(root)[0],
                [
                    "cmake",
                    "-S",
                    ".",
                    "-B",
                    ".murmurations-build",
                    "-G",
                    "Ninja",
                    "-DBUILD_TESTING=ON",
                    "-DCMAKE_BUILD_TYPE=Debug",
                ],
            )
            self.assertEqual(
                detect_test_command(root),
                [
                    "cmake",
                    "--build",
                    ".murmurations-build",
                    "--target",
                    "test",
                    "--parallel",
                    "2",
                ],
            )
            self.assertEqual(
                detect_check_command(root),
                ["cmake", "--build", ".murmurations-build", "--parallel", "2"],
            )

    def test_python_dependency_group_adds_test_preparation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pyproject.toml").write_text(
                "[build-system]\n"
                'requires = ["setuptools>=61"]\n'
                'build-backend = "setuptools.build_meta"\n'
                "\n"
                "[project]\n"
                'name = "example"\n'
                'version = "0.1.0"\n'
                "\n"
                "[dependency-groups]\n"
                'test = ["pytest>=8", "pytest-mock"]\n',
                encoding="utf-8",
            )

            commands = detect_prepare_commands(root)
            self.assertIn(
                [
                    "python3",
                    "-m",
                    "pip",
                    "install",
                    "--break-system-packages",
                    "-e",
                    ".",
                ],
                commands,
            )
            self.assertIn(
                [
                    "python3",
                    "-m",
                    "pip",
                    "install",
                    "--break-system-packages",
                    "--group",
                    "test",
                ],
                commands,
            )

    def test_virtual_cargo_workspace_uses_first_non_internal_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Cargo.toml").write_text(
                "[workspace]\n"
                'members = ["corelib", "tests-integration", "examples"]\n',
                encoding="utf-8",
            )
            (root / "corelib").mkdir()
            (root / "corelib" / "Cargo.toml").write_text(
                "[package]\n"
                'name = "corelib"\n'
                'version = "0.1.0"\n',
                encoding="utf-8",
            )
            (root / "tests-integration").mkdir()
            (root / "tests-integration" / "Cargo.toml").write_text(
                "[package]\n"
                'name = "tests-integration"\n'
                'version = "0.1.0"\n',
                encoding="utf-8",
            )
            (root / "examples").mkdir()
            (root / "examples" / "Cargo.toml").write_text(
                "[package]\n"
                'name = "examples"\n'
                'version = "0.1.0"\n',
                encoding="utf-8",
            )

            self.assertEqual(
                detect_test_command(root),
                ["cargo", "test", "-p", "corelib", "--quiet"],
            )

    def test_maven_reactor_uses_primary_library_module(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pom.xml").write_text(
                '<project xmlns="http://maven.apache.org/POM/4.0.0">'
                "<modelVersion>4.0.0</modelVersion>"
                "<groupId>example</groupId>"
                "<artifactId>example-parent</artifactId>"
                "<version>1.0-SNAPSHOT</version>"
                "<packaging>pom</packaging>"
                "<modules>"
                "<module>core</module>"
                "<module>test-jpms</module>"
                "<module>examples</module>"
                "</modules>"
                "</project>",
                encoding="utf-8",
            )
            for module in ("core", "test-jpms", "examples"):
                module_dir = root / module
                module_dir.mkdir()
                (module_dir / "pom.xml").write_text(
                    '<project xmlns="http://maven.apache.org/POM/4.0.0">'
                    "<modelVersion>4.0.0</modelVersion>"
                    f"<artifactId>{module}</artifactId>"
                    "</project>",
                    encoding="utf-8",
                )

            self.assertEqual(
                detect_test_command(root),
                ["mvn", "test", "-q", "--projects", "core", "--also-make"],
            )
            self.assertIn(
                [
                    "mvn",
                    "-q",
                    "-DskipTests",
                    "dependency:go-offline",
                    "--projects",
                    "core",
                    "--also-make",
                ],
                detect_prepare_commands(root),
            )


if __name__ == "__main__":
    unittest.main()
