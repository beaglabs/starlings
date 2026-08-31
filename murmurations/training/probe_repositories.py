"""Probe pinned repositories for clean verifier eligibility."""

from __future__ import annotations

import argparse
import errno
import json
from pathlib import Path
import shutil
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


def _checkpoint_path(report_path: str | Path | None) -> Path | None:
    if report_path is None:
        return None
    target = Path(report_path)
    return target.with_name(target.name + ".checkpoint.jsonl")


def _load_checkpoint(
    checkpoint: Path | None,
    catalog: RepoCatalog,
) -> dict[tuple[str, str], dict[str, Any]]:
    if checkpoint is None or not checkpoint.exists():
        return {}
    allowed = {(record.name, record.commit) for record in catalog.records}
    rows: dict[tuple[str, str], dict[str, Any]] = {}
    with checkpoint.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            key = (str(row.get("repository") or ""), str(row.get("commit") or ""))
            if key in allowed:
                rows[key] = row
    return rows


def _append_checkpoint(checkpoint: Path | None, row: dict[str, Any]) -> None:
    if checkpoint is None:
        return
    checkpoint.parent.mkdir(parents=True, exist_ok=True)
    with checkpoint.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
        handle.flush()


def _write_outputs(
    *,
    catalog: RepoCatalog,
    results: list[dict[str, Any]],
    report_path: str | Path | None,
    eligible_catalog_path: str | Path | None,
) -> dict[str, Any]:
    eligible_keys = {
        (str(row.get("repository") or ""), str(row.get("commit") or ""))
        for row in results
        if row.get("passed")
    }
    eligible_records = [
        record
        for record in catalog.records
        if (record.name, record.commit) in eligible_keys
    ]
    by_language: dict[str, dict[str, int]] = {}
    for row in results:
        language = str(row.get("language") or "unknown")
        stats = by_language.setdefault(language, {"total": 0, "eligible": 0})
        stats["total"] += 1
        if row.get("passed"):
            stats["eligible"] += 1
    report = {
        "repositories": len(catalog.records),
        "completed": len(results),
        "eligible": len(eligible_records),
        "eligibility_rate": len(eligible_records) / max(1, len(results)),
        "by_language": dict(sorted(by_language.items())),
        "results": results,
    }
    if report_path is not None:
        target = Path(report_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".tmp")
        tmp.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(target)
    if eligible_catalog_path is not None:
        target = Path(eligible_catalog_path)
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".tmp")
        with tmp.open("w", encoding="utf-8") as handle:
            for record in eligible_records:
                handle.write(json.dumps(_record_dict(record), sort_keys=True) + "\n")
        tmp.replace(target)
    return report


def probe_repository_catalog(
    catalog_path: str | Path,
    *,
    cache_dir: str | Path = ".cache/murmurations/repos",
    timeout_seconds: int = 180,
    report_path: str | Path | None = None,
    eligible_catalog_path: str | Path | None = None,
    sandbox_runner=None,
    prune_checkouts: bool = False,
) -> dict[str, Any]:
    catalog = RepoCatalog.from_jsonl(catalog_path)
    checkpoint = _checkpoint_path(report_path)
    completed = _load_checkpoint(checkpoint, catalog)
    results: list[dict[str, Any]] = [
        completed[(record.name, record.commit)]
        for record in catalog.records
        if (record.name, record.commit) in completed
    ]

    if sandbox_runner is None:
        raise RuntimeError("repository eligibility probing requires Daytona")

    if completed:
        print(
            f"[probe] resuming completed={len(completed)}/{len(catalog.records)}",
            flush=True,
        )

    for record in catalog.records:
        key = (record.name, record.commit)
        root: Path | None = None
        if key in completed:
            continue
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
            if not result.passed:
                row["error"] = "clean verifier failed"
        except Exception as exc:
            row.update({"passed": False, "error": str(exc)})
        row["seconds"] = round(time.monotonic() - started, 3)
        results.append(row)
        completed[key] = row
        try:
            _append_checkpoint(checkpoint, row)
        except OSError as exc:
            if (
                exc.errno != errno.ENOSPC
                or not prune_checkouts
                or record.path is not None
                or root is None
            ):
                raise
            shutil.rmtree(root, ignore_errors=True)
            root = None
            _append_checkpoint(checkpoint, row)
        if prune_checkouts and record.path is None and root is not None and root.exists():
            shutil.rmtree(root, ignore_errors=True)
            root = None
        report = _write_outputs(
            catalog=catalog,
            results=results,
            report_path=report_path,
            eligible_catalog_path=eligible_catalog_path,
        )
        print(
            f"[probe] checkpoint completed={len(results)}/{len(catalog.records)} "
            f"eligible={report['eligible']}",
            flush=True,
        )

    report = _write_outputs(
        catalog=catalog,
        results=results,
        report_path=report_path,
        eligible_catalog_path=eligible_catalog_path,
    )
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
        prune_checkouts=True,
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
