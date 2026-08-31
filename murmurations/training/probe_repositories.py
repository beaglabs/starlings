"""Probe pinned repositories for clean verifier eligibility."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import time
from typing import Any

import yaml

from murmurations.training.daytona import DaytonaCorpusRunner

from murmurations.training.environments.repositories import RepoCatalog, RepoRecord, checkout_repository
from murmurations.training.operators import detect_test_command


def _record_dict(record: RepoRecord) -> dict[str, Any]:
    return {
        "name": record.name,
        "commit": record.commit,
        "license": record.license,
        "language": record.language,
        "url": record.url,
        "path": record.path,
    }


def probe_repository_catalog(
    catalog_path: str | Path,
    *,
    cache_dir: str | Path = ".cache/murmurations/repos",
    timeout_seconds: int = 180,
    report_path: str | Path | None = None,
    eligible_catalog_path: str | Path | None = None,
    sandbox_runner=None,
) -> dict[str, Any]:
    catalog = RepoCatalog.from_jsonl(catalog_path)
    results: list[dict[str, Any]] = []
    eligible: list[RepoRecord] = []

    if sandbox_runner is None:
        raise RuntimeError("repository eligibility probing requires Daytona")

    for record in catalog.records:
        started = time.monotonic()
        row: dict[str, Any] = {
            "repository": record.name,
            "language": record.language,
            "license": record.license,
            "commit": record.commit,
        }
        try:
            root = checkout_repository(record, cache_dir)
            command = detect_test_command(root)
            if command is None:
                raise RuntimeError("no supported repository test command detected")
            with sandbox_runner.workspace(root, record, plan_root=root) as remote:
                result = remote.verify(root, command, timeout_seconds)
            row.update(
                {
                    "command": command,
                    "passed": result.passed,
                    "exit_code": result.exit_code,
                    "output_tail": result.output[-2000:],
                    "backend": result.backend,
                    "sandbox_argv": list(result.sandbox_argv),
                    "sandbox_id": result.sandbox_id,
                    "sandbox_snapshot": result.sandbox_snapshot,
                }
            )
            if result.passed:
                eligible.append(record)
            else:
                row["error"] = "clean verifier failed"
        except Exception as exc:
            row.update({"passed": False, "error": str(exc)})
        row["seconds"] = round(time.monotonic() - started, 3)
        results.append(row)

    by_language: dict[str, dict[str, int]] = {}
    for row in results:
        language = str(row.get("language") or "unknown")
        stats = by_language.setdefault(language, {"total": 0, "eligible": 0})
        stats["total"] += 1
        if row.get("passed"):
            stats["eligible"] += 1

    report = {
        "repositories": len(catalog.records),
        "eligible": len(eligible),
        "eligibility_rate": len(eligible) / max(1, len(catalog.records)),
        "by_language": dict(sorted(by_language.items())),
        "results": results,
    }

    if report_path is not None:
        target = Path(report_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    if eligible_catalog_path is not None:
        target = Path(eligible_catalog_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("w", encoding="utf-8") as handle:
            for record in eligible:
                handle.write(json.dumps(_record_dict(record), sort_keys=True) + "\n")

    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--cache-dir", default=".cache/murmurations/repos")
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--report", required=True)
    parser.add_argument("--eligible-catalog", required=True)
    args = parser.parse_args()
    config = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    sandbox = DaytonaCorpusRunner.from_config(dict(config.get("sandbox") or {}))
    sandbox.validate_environment()
    report = probe_repository_catalog(
        args.catalog,
        cache_dir=args.cache_dir,
        timeout_seconds=args.timeout_seconds,
        report_path=args.report,
        eligible_catalog_path=args.eligible_catalog,
        sandbox_runner=sandbox,
    )
    print(
        json.dumps(
            {
                "repositories": report["repositories"],
                "eligible": report["eligible"],
                "eligibility_rate": report["eligibility_rate"],
                "by_language": report["by_language"],
                "report": args.report,
                "eligible_catalog": args.eligible_catalog,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
