"""Command-backed scoring for coding-repair candidates.

The benchmark runner never generates a patch. It scores a candidate workspace
produced by Murmurations/Starlings using explicit argv commands from a YAML spec.
No shell is invoked.
"""

from __future__ import annotations

import subprocess
import time
from pathlib import Path
from typing import Any

import yaml


def evaluate_coding_candidate(spec_path: str | Path, candidate_root: str | Path) -> dict[str, Any]:
    spec = yaml.safe_load(Path(spec_path).read_text(encoding="utf-8"))
    if not isinstance(spec, dict) or not isinstance(spec.get("tasks"), list):
        raise ValueError("coding benchmark spec must contain a tasks list")

    root = Path(candidate_root).resolve()
    results: list[dict[str, Any]] = []
    passed = 0

    for task in spec["tasks"]:
        task_id = str(task["id"])
        relative_cwd = Path(str(task.get("cwd", ".")))
        cwd = (root / relative_cwd).resolve()
        if root not in cwd.parents and cwd != root:
            raise ValueError(f"task {task_id}: cwd escapes candidate root")
        timeout = float(task.get("timeout_seconds", 60.0))
        commands = task.get("commands") or []
        if not commands:
            raise ValueError(f"task {task_id}: no commands")

        task_ok = True
        command_results = []
        for argv in commands:
            if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
                raise TypeError(f"task {task_id}: each command must be a non-empty argv list")
            started = time.perf_counter()
            try:
                completed = subprocess.run(
                    argv,
                    cwd=cwd,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                    check=False,
                )
                elapsed_ms = (time.perf_counter() - started) * 1000.0
                command_ok = completed.returncode == 0
                command_results.append(
                    {
                        "argv": argv,
                        "returncode": completed.returncode,
                        "wall_ms": elapsed_ms,
                        "stdout_tail": completed.stdout[-4000:],
                        "stderr_tail": completed.stderr[-4000:],
                        "passed": command_ok,
                    }
                )
            except subprocess.TimeoutExpired as exc:
                elapsed_ms = (time.perf_counter() - started) * 1000.0
                command_ok = False
                command_results.append(
                    {
                        "argv": argv,
                        "returncode": None,
                        "wall_ms": elapsed_ms,
                        "stdout_tail": (exc.stdout or "")[-4000:] if isinstance(exc.stdout, str) else "",
                        "stderr_tail": (exc.stderr or "")[-4000:] if isinstance(exc.stderr, str) else "",
                        "passed": False,
                        "timeout": True,
                    }
                )
            task_ok = task_ok and command_ok
            if not command_ok and bool(task.get("stop_on_failure", True)):
                break

        if task_ok:
            passed += 1
        results.append({"id": task_id, "passed": task_ok, "commands": command_results})

    return {
        "tasks": len(results),
        "passed": passed,
        "pass_rate": passed / max(1, len(results)),
        "results": results,
    }
