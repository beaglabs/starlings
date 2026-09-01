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

            commands = detect_prepare_commands(root)
            self.assertEqual(
                commands[0],
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
                commands[1],
                ["cmake", "--build", ".murmurations-build", "--parallel", "2"],
            )
            verifier = detect_test_command(root)
            self.assertEqual(verifier[:2], ["python3", "-c"])
            self.assertIn("cmake", verifier[2])
            self.assertIn("ctest", verifier[2])
            self.assertEqual(
                detect_check_command(root),
                ["cmake", "--build", ".murmurations-build", "--parallel", "2"],
            )

    def test_libuv_style_cmake_plan_disables_bench_and_tidy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "CMakeLists.txt").write_text(
                "project(libuv LANGUAGES C)\n"
                "option(LIBUV_BUILD_TESTS \"tests\" ON)\n"
                "option(LIBUV_BUILD_BENCH \"bench\" ON)\n"
                "option(ENABLE_CLANG_TIDY \"tidy\" ON)\n",
                encoding="utf-8",
            )
            configure = detect_prepare_commands(root)[0]
            self.assertIn("-DLIBUV_BUILD_TESTS=ON", configure)
            self.assertIn("-DLIBUV_BUILD_BENCH=OFF", configure)
            self.assertIn("-DENABLE_CLANG_TIDY=OFF", configure)

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
                ["python3", "-m", "venv", ".murmurations-venv"],
                commands,
            )
            self.assertIn(
                [
                    ".murmurations-venv/bin/python3",
                    "-m",
                    "pip",
                    "install",
                    "-e",
                    ".",
                ],
                commands,
            )
            self.assertIn(
                [
                    ".murmurations-venv/bin/python3",
                    "-m",
                    "pip",
                    "install",
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
            self.assertEqual(detect_prepare_commands(root), [])

    def test_python_plural_tests_group_is_selected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pyproject.toml").write_text(
                "[project]\nname='example'\nversion='0.1.0'\n"
                "[dependency-groups]\ntests=['pytest']\n",
                encoding="utf-8",
            )
            (root / "tests").mkdir()
            (root / "tests" / "test_example.py").write_text("def test_ok(): pass\n", encoding="utf-8")
            commands = detect_prepare_commands(root)
            self.assertIn(
                [
                    ".murmurations-venv/bin/python3", "-m", "pip", "install",
                    "--group", "tests",
                ],
                commands,
            )
            self.assertEqual(
                detect_test_command(root),
                [".murmurations-venv/bin/python3", "-m", "pytest", "-q"],
            )

    def test_pnpm_workspace_uses_pnpm(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "package.json").write_text(
                '{"name":"workspace","packageManager":"pnpm@10.34.5","scripts":{"test":"vitest run"}}',
                encoding="utf-8",
            )
            (root / "pnpm-lock.yaml").write_text("lockfileVersion: '9.0'\n", encoding="utf-8")
            self.assertIn(
                [
                    "npx", "--yes", "pnpm@10.34.5",
                    "install", "--frozen-lockfile",
                ],
                detect_prepare_commands(root),
            )
            self.assertEqual(
                detect_test_command(root),
                ["npx", "--yes", "pnpm@10.34.5", "run", "test"],
            )

    def test_pnpm_prefers_focused_unit_test_script(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "package.json").write_text(
                '{"name":"vite-like","packageManager":"pnpm@10.34.5",'
                '"devDependencies":{"typescript":"~6.0.2"},'
                '"scripts":{"build":"pnpm -r run build",'
                '"test":"pnpm test-unit && pnpm test-build",'
                '"test-unit":"vitest run"}}',
                encoding="utf-8",
            )
            (root / "pnpm-lock.yaml").write_text(
                "lockfileVersion: '9.0'\n",
                encoding="utf-8",
            )
            self.assertIn(
                ["npx", "--yes", "pnpm@10.34.5", "run", "build"],
                detect_prepare_commands(root),
            )
            self.assertEqual(
                detect_test_command(root),
                ["npx", "--yes", "pnpm@10.34.5", "run", "test-unit"],
            )

    def test_pnpm_uses_repository_declared_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "package.json").write_text(
                '{"name":"vitest-like","packageManager":"pnpm@11.24.0",'
                '"devDependencies":{"typescript":"^5.9.3"},'
                '"scripts":{"build":"pnpm -r run build",'
                '"test":"pnpm --filter test-unit test:threads",'
                '"test:ci:unit":"pnpm -r --filter test-unit run test"}}',
                encoding="utf-8",
            )
            (root / "pnpm-lock.yaml").write_text(
                "lockfileVersion: '9.0'\n",
                encoding="utf-8",
            )
            self.assertEqual(
                detect_prepare_commands(root)[0],
                [
                    "npx", "--yes", "pnpm@11.24.0",
                    "install", "--frozen-lockfile",
                ],
            )
            self.assertIn(
                ["npx", "--yes", "pnpm@11.24.0", "run", "build"],
                detect_prepare_commands(root),
            )
            self.assertEqual(
                detect_test_command(root),
                ["npx", "--yes", "pnpm@11.24.0", "run", "test:ci:unit"],
            )

    def test_zig_repository_uses_minimum_toolchain(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "build.zig").write_text(
                "pub fn build(_: anytype) void {}\n",
                encoding="utf-8",
            )
            (root / "build.zig.zon").write_text(
                '.{ .name = .example, .minimum_zig_version = "0.16.0" }\n',
                encoding="utf-8",
            )
            self.assertEqual(
                detect_prepare_commands(root),
                [["/opt/zig/0.16.0/zig", "build", "--fetch"]],
            )
            self.assertEqual(
                detect_test_command(root),
                ["/opt/zig/0.16.0/zig", "build", "test"],
            )
            self.assertEqual(
                detect_check_command(root),
                ["/opt/zig/0.16.0/zig", "build"],
            )

    def test_zig_project_does_not_take_cmake_prepare_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "build.zig").write_text(
                "pub fn build(_: anytype) void {}\n",
                encoding="utf-8",
            )
            (root / "build.zig.zon").write_text(
                '.{ .name = .example, .minimum_zig_version = '
                '"0.17.0-dev.292+fc1c83a36" }\n',
                encoding="utf-8",
            )
            (root / "CMakeLists.txt").write_text(
                "project(example)\n",
                encoding="utf-8",
            )
            commands = detect_prepare_commands(root)
            self.assertEqual(
                commands,
                [[
                    "/opt/zig/0.17.0-dev.292+fc1c83a36/zig",
                    "build",
                    "--fetch",
                ]],
            )


if __name__ == "__main__":
    unittest.main()
