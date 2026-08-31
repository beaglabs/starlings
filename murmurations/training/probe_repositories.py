"""Probe pinned repositories for clean verifier eligibility."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import shutil
import threading
import time
from typing import Any

import yaml

from murmurations.training.daytona import DaytonaCorpusRunner

from murmurations.training.environments.repositories import RepoCatalog, RepoRecord, checkout_repository
from murmurations.training.operators import detect_prepare_commands, detect_test_command


PROBE_PLAN_VERSION = 2


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
    *,
    probe_signature: str,
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
            if str(row.get("probe_signature") or "") != probe_signature:
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


def _ordered_results(
    catalog: RepoCatalog,
    completed: dict[tuple[str, str], dict[str, Any]],
) -> list[dict[str, Any]]:
    return [
        completed[(record.name, record.commit)]
        for record in catalog.records
        if (record.name, record.commit) in completed
    ]


def _probe_one(
    record: RepoRecord,
    *,
    cache_dir: str | Path,
    timeout_seconds: int,
    probe_signature: str,
    sandbox_runner,
    prune_checkouts: bool,
    checkout_gate,
) -> dict[str, Any]:
    started = time.monotonic()
    root: Path | None = None
    row: dict[str, Any] = {
        "probe_signature": probe_signature,
        "repository": record.name,
        "language": record.language,
        "license": record.license,
        "commit": record.commit,
    }
    try:
        with checkout_gate:
            root = checkout_repository(record, cache_dir)
            command = detect_test_command(root)
            if command is None:
                raise RuntimeError("no supported repository test command detected")
            prepare_commands = detect_prepare_commands(root)
            remote_root = root
            if prune_checkouts and record.path is None:
                shutil.rmtree(root, ignore_errors=True)
                root = None

        worker_runner = (
            sandbox_runner.worker()
            if hasattr(sandbox_runner, "worker")
            else sandbox_runner
        )
        with worker_runner.workspace(
            remote_root,
            record,
            plan_root=remote_root,
            prepare_commands=prepare_commands,
            sync_local_changes=False,
        ) as remote:
            result = remote.verify(remote_root, command, timeout_seconds)
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
    finally:
        row["seconds"] = round(time.monotonic() - started, 3)
        if (
            prune_checkouts
            and record.path is None
            and root is not None
            and root.exists()
        ):
            shutil.rmtree(root, ignore_errors=True)
    return row


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
    concurrency: int = 1,
    local_checkout_concurrency: int = 1,
) -> dict[str, Any]:
    catalog = RepoCatalog.from_jsonl(catalog_path)
    provenance = sandbox_runner.provenance() if sandbox_runner is not None else {}
    snapshot_info = dict(provenance.get("snapshot_info") or {})
    snapshot_identity = snapshot_info.get("id") or provenance.get("snapshot") or "unknown"
    probe_signature = f"v{PROBE_PLAN_VERSION}:{snapshot_identity}"
    checkpoint = _checkpoint_path(report_path)
    completed = _load_checkpoint(
        checkpoint,
        catalog,
        probe_signature=probe_signature,
    )
    if sandbox_runner is None:
        raise RuntimeError("repository eligibility probing requires Daytona")
    if concurrency <= 0:
        raise ValueError("probe concurrency must be positive")
    if local_checkout_concurrency <= 0:
        raise ValueError("probe local checkout concurrency must be positive")

    if completed:
        print(
            f"[probe] resuming completed={len(completed)}/{len(catalog.records)}",
            flush=True,
        )

    pending = [
        record
        for record in catalog.records
        if (record.name, record.commit) not in completed
    ]
    if pending:
        print(
            f"[probe] launching pending={len(pending)} concurrency={concurrency}",
            flush=True,
        )
        checkout_gate = threading.BoundedSemaphore(local_checkout_concurrency)
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = {
                executor.submit(
                    _probe_one,
                    record,
                    cache_dir=cache_dir,
                    timeout_seconds=timeout_seconds,
                    probe_signature=probe_signature,
                    sandbox_runner=sandbox_runner,
                    prune_checkouts=prune_checkouts,
                    checkout_gate=checkout_gate,
                ): record
                for record in pending
            }
            for future in as_completed(futures):
                record = futures[future]
                row = future.result()
                key = (record.name, record.commit)
                completed[key] = row
                _append_checkpoint(checkpoint, row)
                results = _ordered_results(catalog, completed)
                eligible_count = sum(1 for item in results if item.get("passed"))
                print(
                    f"[probe] checkpoint completed={len(results)}/{len(catalog.records)} "
                    f"eligible={eligible_count}",
                    flush=True,
                )

    results = _ordered_results(catalog, completed)
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
    parser.add_argument("--concurrency", type=int, default=None)
    parser.add_argument("--local-checkout-concurrency", type=int, default=None)
    args = parser.parse_args()
    config = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    sandbox = DaytonaCorpusRunner.from_config(dict(config.get("sandbox") or {}))
    sandbox.validate_environment()
    concurrency = (
        args.concurrency
        if args.concurrency is not None
        else int(config.get("probe_concurrency", 1))
    )
    local_checkout_concurrency = (
        args.local_checkout_concurrency
        if args.local_checkout_concurrency is not None
        else int(config.get("probe_local_checkout_concurrency", 1))
    )
    report = probe_repository_catalog(
        args.catalog,
        cache_dir=args.cache_dir,
        timeout_seconds=args.timeout_seconds,
        report_path=args.report,
        eligible_catalog_path=args.eligible_catalog,
        sandbox_runner=sandbox,
        prune_checkouts=True,
        concurrency=concurrency,
        local_checkout_concurrency=local_checkout_concurrency,
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
