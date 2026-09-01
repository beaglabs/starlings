"""Generate verifier-grounded Murmurations repair episodes from repositories."""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass
import hashlib
from collections import defaultdict, deque
import json
import math
import os
from pathlib import Path
import re
import shutil
import threading
from typing import Any

import yaml

from murmurations.training.daytona import DaytonaCorpusRunner
from murmurations.training.environments.episodes import make_oracle_bootstrap_episode
from murmurations.training.environments.mutations import (
    MutationCandidate,
    enumerate_mutation_candidates,
    inject_verified_mutation,
    mutation_fingerprint,
    reset_mutation_workspace,
)
from murmurations.training.environments.repositories import (
    RepoCatalog,
    RepoRecord,
    checkout_repository,
)
from murmurations.training.operators import default_operator_registry, detect_test_command
from murmurations.utils.canonical import canonical_id


_TERMINAL_OPERATORS = {"type.check", "package.metadata", "docs.lookup"}


_DAYTONA_VCPU_USD_PER_HOUR = 0.0504
_DAYTONA_MEMORY_USD_PER_GIB_HOUR = 0.0162
_DAYTONA_STORAGE_USD_PER_GIB_HOUR = 0.000108


@dataclass(frozen=True)
class _GenerationOutcome:
    repository: RepoRecord
    local_index: int
    global_index: int
    record: dict[str, Any] | None = None
    raw_fingerprint: str | None = None
    error: str | None = None


def _safe(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)


def _balanced_repositories(catalog: RepoCatalog) -> list[RepoRecord]:
    groups: dict[str, deque[RepoRecord]] = defaultdict(deque)
    for record in catalog.records:
        groups[record.language or "unknown"].append(record)
    order: list[RepoRecord] = []
    languages = sorted(groups)
    while True:
        progressed = False
        for language in languages:
            if groups[language]:
                order.append(groups[language].popleft())
                progressed = True
        if not progressed:
            return order


def _prioritized_repositories(
    order: list[RepoRecord],
    *,
    required_languages: set[str],
    present_languages: set[str],
) -> list[RepoRecord]:
    missing = required_languages - present_languages
    if not missing:
        return list(order)
    return [
        *[repo for repo in order if (repo.language or "unknown") in missing],
        *[repo for repo in order if (repo.language or "unknown") not in missing],
    ]


def _semantic_candidate_identity(path: str | Path | None) -> str | None:
    if path is None:
        return None
    target = Path(path)
    if not target.exists():
        raise FileNotFoundError(
            f"configured semantic candidate file does not exist: {target}"
        )
    return hashlib.sha256(target.read_bytes()).hexdigest()


def _load_semantic_candidates(
    path: str | Path | None,
    *,
    catalog: RepoCatalog,
) -> dict[str, tuple[MutationCandidate, ...]]:
    if path is None:
        return {}
    allowed = {record.name: record for record in catalog.records}
    grouped: dict[str, list[MutationCandidate]] = defaultdict(list)
    seen: set[tuple[str, str]] = set()
    for line_no, row in enumerate(_iter_jsonl(Path(path)) or (), 1):
        repository = str(row.get("repository") or "")
        if repository not in allowed:
            raise ValueError(
                f"{path}:{line_no}: semantic candidate repository is outside catalog: "
                f"{repository}"
            )
        record = allowed[repository]
        commit = str(row.get("commit") or record.commit)
        if commit != record.commit:
            raise ValueError(
                f"{path}:{line_no}: semantic candidate commit does not match pinned catalog"
            )
        candidate = MutationCandidate(
            relative_path=str(row["path"]),
            line_number=int(row["line"]),
            kind=str(row.get("kind") or "llm_semantic"),
            original_line=str(row["original_line"]),
            mutated_line=str(row["mutated_line"]),
            source=str(row.get("source") or "llm"),
            targeted_test_argv=(),
        )
        key = (repository, candidate.fingerprint)
        if key in seen:
            continue
        seen.add(key)
        grouped[repository].append(candidate)
    return {
        repository: tuple(candidates)
        for repository, candidates in grouped.items()
    }


def _host_disk_capacity(
    path: str | Path,
    *,
    max_workers: int,
    reserve_gib: float,
    per_worker_gib: float,
) -> dict[str, Any]:
    if reserve_gib < 0:
        raise ValueError("host_disk_reserve_gib must be non-negative")
    if per_worker_gib <= 0:
        raise ValueError("host_disk_per_worker_gib must be positive")
    root = Path(path).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    free_bytes = shutil.disk_usage(root).free
    gib = float(1024 ** 3)
    usable_gib = max(0.0, free_bytes / gib - reserve_gib)
    workers = min(max_workers, int(usable_gib // per_worker_gib))
    if workers <= 0:
        raise RuntimeError(
            "insufficient host disk for concurrent corpus generation: "
            f"free={free_bytes / gib:.2f}GiB reserve={reserve_gib:.2f}GiB "
            f"per_worker={per_worker_gib:.2f}GiB"
        )
    return {
        "free_gib": free_bytes / gib,
        "reserve_gib": reserve_gib,
        "per_worker_gib": per_worker_gib,
        "workers": workers,
    }


def _daytona_budget_plan(
    sandbox_runner,
    *,
    requested_limit: int,
    generation_retries: int,
    budget_usd: float | None,
    budget_safety_fraction: float,
) -> dict[str, Any]:
    provenance = sandbox_runner.provenance()
    snapshot = dict(provenance.get("snapshot_info") or {})
    cpu = float(snapshot.get("cpu") or 0)
    memory = float(snapshot.get("memory_gib") or 0)
    disk = float(snapshot.get("disk_gib") or 0)
    ttl_minutes = int(provenance.get("ttl_minutes") or 45)
    hourly = (
        cpu * _DAYTONA_VCPU_USD_PER_HOUR
        + memory * _DAYTONA_MEMORY_USD_PER_GIB_HOUR
        + disk * _DAYTONA_STORAGE_USD_PER_GIB_HOUR
    )
    attempt_ceiling = hourly * ttl_minutes / 60.0
    request_ceiling = attempt_ceiling * max(1, generation_retries)
    plan: dict[str, Any] = {
        "budget_usd": budget_usd,
        "budget_safety_fraction": budget_safety_fraction,
        "sandbox_hourly_usd_ceiling": hourly,
        "attempt_usd_ceiling": attempt_ceiling,
        "request_usd_ceiling": request_ceiling,
        "configured_requested_limit": requested_limit,
        "requested_limit": requested_limit,
    }
    if budget_usd is None:
        plan["theoretical_max_spend_usd"] = requested_limit * request_ceiling
        return plan
    if budget_usd <= 0:
        raise ValueError("budget_usd must be positive")
    if not 0 < budget_safety_fraction <= 1:
        raise ValueError("budget_safety_fraction must be in (0, 1]")
    usable_budget = budget_usd * budget_safety_fraction
    budget_limit = (
        math.floor(usable_budget / request_ceiling)
        if request_ceiling > 0
        else requested_limit
    )
    plan["usable_budget_usd"] = usable_budget
    plan["budget_requested_limit"] = budget_limit
    plan["requested_limit"] = min(requested_limit, budget_limit)
    plan["theoretical_max_spend_usd"] = (
        plan["requested_limit"] * request_ceiling
    )
    if int(plan["requested_limit"]) <= 0:
        raise RuntimeError("Daytona budget cannot fund one worst-case generation request")
    return plan


def _generate_repo_burst(
    *,
    repo: RepoRecord,
    slots: list[tuple[int, int]],
    excluded_fingerprints: set[str],
    source: Path,
    work_root: Path,
    repo_index: int,
    seed: int,
    timeout_seconds: int,
    max_attempts: int,
    generation_retries: int,
    enrichment_operators: tuple[str, ...],
    max_enrichment_calls: int,
    sandbox_runner,
    signature: str,
    partition_id: int = 0,
    partition_count: int = 1,
    semantic_candidates: tuple[MutationCandidate, ...] = (),
    stop_event: threading.Event | None = None,
) -> list[_GenerationOutcome]:
    outcomes: list[_GenerationOutcome] = []
    local_used = set(excluded_fingerprints)
    worker_runner = (
        sandbox_runner.worker()
        if hasattr(sandbox_runner, "worker")
        else sandbox_runner
    )
    workspace = work_root / _safe(repo.name) / f"partition-{partition_id:03d}"
    try:
        verifier = detect_test_command(source)
        if verifier is None:
            raise RuntimeError("no supported repository test command detected")

        deterministic = enumerate_mutation_candidates(source)
        candidate_pool = tuple(deterministic) + tuple(semantic_candidates)
        if not candidate_pool:
            raise RuntimeError("repository has no mutation candidates")

        reset_mutation_workspace(source, workspace)
        with worker_runner.workspace(
            workspace,
            repo,
            plan_root=source,
        ) as remote:
            clean = remote.verify(workspace, verifier, timeout_seconds)
            if not clean.passed:
                raise RuntimeError(
                    "source repository verifier does not pass in persistent worker"
                )

            for local_index, global_index in slots:
                if stop_event is not None and stop_event.is_set():
                    break
                last_error: Exception | None = None
                for retry in range(max(1, generation_retries)):
                    attempt_seed = (
                        seed
                        + repo_index * 1_000_003
                        + local_index * 101
                        + retry
                    )
                    try:
                        mutation = inject_verified_mutation(
                            source,
                            workspace,
                            verifier,
                            seed=attempt_seed,
                            timeout_seconds=timeout_seconds,
                            max_attempts=max_attempts,
                            excluded_fingerprints=local_used,
                            verify_runner=remote.verify,
                            clean_verification=clean,
                            candidates=candidate_pool,
                            partition_id=partition_id,
                            partition_count=partition_count,
                            triage_runner=remote.verify,
                        )
                        registry = default_operator_registry(workspace)
                        episode = make_oracle_bootstrap_episode(
                            repo,
                            workspace,
                            mutation,
                            registry,
                            timeout_seconds=timeout_seconds,
                            episode_seed=attempt_seed,
                            enrichment_operators=enrichment_operators,
                            max_enrichment_calls=max_enrichment_calls,
                            command_runner=remote.run_operator,
                        )
                        record = episode.record()
                        raw_fingerprint = mutation.fingerprint
                        record["mutation"]["fingerprint"] = canonical_id(
                            {
                                "repository_identity": repo.identity,
                                "mutation": raw_fingerprint,
                            }
                        )
                        record["generation"] = {
                            "signature": signature,
                            "seed": attempt_seed,
                            "repo_episode_index": local_index,
                            "global_episode_index": global_index,
                            "raw_mutation_fingerprint": raw_fingerprint,
                            "candidate_partition": partition_id,
                            "candidate_partitions": partition_count,
                            "candidate_source": mutation.candidate_source,
                        }
                        local_used.add(raw_fingerprint)
                        outcomes.append(
                            _GenerationOutcome(
                                repository=repo,
                                local_index=local_index,
                                global_index=global_index,
                                record=record,
                                raw_fingerprint=raw_fingerprint,
                            )
                        )
                        break
                    except Exception as exc:
                        last_error = exc
                else:
                    assert last_error is not None
                    outcomes.append(
                        _GenerationOutcome(
                            repository=repo,
                            local_index=local_index,
                            global_index=global_index,
                            error=str(last_error),
                        )
                    )
    except Exception as exc:
        completed = {(item.local_index, item.global_index) for item in outcomes}
        for local_index, global_index in slots:
            if (local_index, global_index) in completed:
                continue
            outcomes.append(
                _GenerationOutcome(
                    repository=repo,
                    local_index=local_index,
                    global_index=global_index,
                    error=str(exc),
                )
            )
    finally:
        shutil.rmtree(workspace, ignore_errors=True)
    return outcomes


def _schedule(
    catalog: RepoCatalog,
    *,
    episodes: int | None,
    episodes_per_repo: int | None,
    seed: int,
) -> list[tuple[RepoRecord, int, int]]:
    if episodes_per_repo is not None:
        if episodes_per_repo <= 0:
            raise ValueError("episodes_per_repo must be positive")
        repo_index = {record.name: index for index, record in enumerate(catalog.records)}
        order = _balanced_repositories(catalog)
        return [
            (repo, repo_index[repo.name], local_index)
            for local_index in range(episodes_per_repo)
            for repo in order
        ]
    requested = 10 if episodes is None else episodes
    if requested <= 0:
        raise ValueError("episodes must be positive")
    return [
        (catalog.sample(seed + index), -1, index)
        for index in range(requested)
    ]


def _repair_jsonl_tail(path: Path) -> None:
    if not path.exists() or path.stat().st_size == 0:
        return
    with path.open("rb+") as handle:
        handle.seek(-1, os.SEEK_END)
        if handle.read(1) == b"\n":
            return
        handle.seek(0)
        payload = handle.read()
        last_newline = payload.rfind(b"\n")
        handle.truncate(last_newline + 1 if last_newline >= 0 else 0)


def _iter_jsonl(path: Path):
    if not path.exists():
        return
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid JSONL") from exc


def _append_jsonl(handle, row: dict[str, Any]) -> None:
    handle.write(json.dumps(row, sort_keys=True) + "\n")
    handle.flush()
    os.fsync(handle.fileno())


def _raw_mutation_fingerprint(record: dict[str, Any]) -> str:
    mutation = dict(record.get("mutation") or {})
    return mutation_fingerprint(
        str(mutation.get("path") or ""),
        int(mutation.get("line") or 0),
        str(mutation.get("kind") or ""),
        str(mutation.get("original_line") or ""),
        str(mutation.get("mutated_line") or ""),
    )


def _episode_metrics(record: dict[str, Any]) -> dict[str, Any]:
    terminal_events = 0
    terminal_types: set[str] = set()
    argv_events = 0
    for event in record.get("events") or []:
        frame = dict(event.get("frame") or {})
        operator = str(frame.get("operator_ref") or "")
        if operator in _TERMINAL_OPERATORS:
            terminal_events += 1
            terminal_types.add(operator)
        environment = dict(event.get("environment") or {})
        argv = environment.get("argv")
        if isinstance(argv, list) and argv:
            argv_events += 1
    return {
        "trajectory_rows": len(record.get("events") or []),
        "terminal_operator_events": terminal_events,
        "terminal_operator_types": terminal_types,
        "terminal_argv_events": argv_events,
    }


def _execution_identity(sandbox_runner) -> dict[str, Any]:
    provenance = (
        sandbox_runner.provenance()
        if hasattr(sandbox_runner, "provenance")
        else {"runtime": type(sandbox_runner).__name__}
    )
    snapshot_info = dict(provenance.get("snapshot_info") or {})
    planner = Path(__file__).with_name("repository_plan.py")
    return {
        "runtime": provenance.get("runtime"),
        "snapshot": provenance.get("snapshot"),
        "snapshot_id": snapshot_info.get("id"),
        "planner_sha256": hashlib.sha256(planner.read_bytes()).hexdigest(),
    }


def _generation_signature(
    catalog: RepoCatalog,
    *,
    seed: int,
    max_attempts: int,
    generation_retries: int,
    enrichment_operators: tuple[str, ...],
    max_enrichment_calls: int,
    mode: dict[str, Any],
    execution_identity: dict[str, Any] | None = None,
) -> str:
    return canonical_id(
        {
            "version": 3,
            "catalog": [record.identity for record in catalog.records],
            "seed": seed,
            "max_attempts": max_attempts,
            "generation_retries": generation_retries,
            "enrichment_operators": list(enrichment_operators),
            "max_enrichment_calls": max_enrichment_calls,
            "mode": mode,
            "execution_identity": execution_identity or {},
        }
    )


def _empty_metrics() -> dict[str, Any]:
    return {
        "requested": 0,
        "written": 0,
        "failed": 0,
        "trajectory_rows": 0,
        "terminal_operator_events": 0,
        "terminal_operator_types": set(),
        "terminal_argv_events": 0,
        "dynamic_repositories": set(),
        "dynamic_languages": set(),
        "candidate_sources": {},
    }


def _load_journal(
    output: Path,
    failures_output: Path,
    *,
    signature: str,
    catalog: RepoCatalog,
) -> tuple[
    dict[str, set[str]],
    dict[str, dict[str, int]],
    dict[str, int],
    set[tuple[str, int]],
    int,
    dict[str, Any],
]:
    _repair_jsonl_tail(output)
    _repair_jsonl_tail(failures_output)
    allowed = {record.name for record in catalog.records}
    used: dict[str, set[str]] = defaultdict(set)
    repo_stats: dict[str, dict[str, int]] = defaultdict(
        lambda: {"requested": 0, "written": 0, "failed": 0}
    )
    next_local: dict[str, int] = defaultdict(int)
    processed: set[tuple[str, int]] = set()
    next_global = 0
    metrics = _empty_metrics()

    def claim_slot(repository: str, local_index: int, global_index: int) -> None:
        nonlocal next_global
        if repository not in allowed:
            raise RuntimeError(
                f"generation journal contains repository outside catalog: {repository}"
            )
        key = (repository, local_index)
        if key in processed:
            raise RuntimeError(
                f"duplicate generation journal slot: {repository}#{local_index}"
            )
        processed.add(key)
        next_local[repository] = max(next_local[repository], local_index + 1)
        next_global = max(next_global, global_index + 1)

    for record in _iter_jsonl(output) or ():
        generation = dict(record.get("generation") or {})
        if str(generation.get("signature") or "") != signature:
            raise RuntimeError(
                "existing episode journal was produced by an incompatible generation plan"
            )
        repository = str((record.get("repository") or {}).get("name") or "")
        local_index = int(generation.get("repo_episode_index", -1))
        global_index = int(generation.get("global_episode_index", -1))
        if local_index < 0 or global_index < 0:
            raise RuntimeError("existing episode journal lacks resumable generation indices")
        claim_slot(repository, local_index, global_index)
        raw_fingerprint = str(generation.get("raw_mutation_fingerprint") or "")
        if not raw_fingerprint:
            raw_fingerprint = _raw_mutation_fingerprint(record)
        used[repository].add(raw_fingerprint)
        repo_stats[repository]["requested"] += 1
        repo_stats[repository]["written"] += 1
        metrics["requested"] += 1
        metrics["written"] += 1
        metrics["dynamic_repositories"].add(repository)
        language = str((record.get("repository") or {}).get("language") or "unknown")
        metrics["dynamic_languages"].add(language)
        candidate_source = str(generation.get("candidate_source") or "deterministic")
        metrics["candidate_sources"][candidate_source] = (
            int(metrics["candidate_sources"].get(candidate_source, 0)) + 1
        )
        episode_metrics = _episode_metrics(record)
        metrics["trajectory_rows"] += int(episode_metrics["trajectory_rows"])
        metrics["terminal_operator_events"] += int(
            episode_metrics["terminal_operator_events"]
        )
        metrics["terminal_operator_types"].update(
            episode_metrics["terminal_operator_types"]
        )
        metrics["terminal_argv_events"] += int(
            episode_metrics["terminal_argv_events"]
        )

    for failure in _iter_jsonl(failures_output) or ():
        if str(failure.get("generation_signature") or "") != signature:
            raise RuntimeError(
                "existing failure journal was produced by an incompatible generation plan"
            )
        repository = str(failure.get("repository") or "")
        local_index = int(failure.get("repo_episode_index", -1))
        global_index = int(failure.get("global_episode_index", -1))
        if local_index < 0 or global_index < 0:
            raise RuntimeError("existing failure journal lacks resumable generation indices")
        claim_slot(repository, local_index, global_index)
        repo_stats[repository]["requested"] += 1
        repo_stats[repository]["failed"] += 1
        metrics["requested"] += 1
        metrics["failed"] += 1

    return used, repo_stats, next_local, processed, next_global, metrics


def _target_status(metrics: dict[str, Any], targets: dict[str, Any]) -> dict[str, bool]:
    requested = int(metrics["requested"])
    written = int(metrics["written"])
    success_rate = written / max(1, requested)
    candidate_sources = dict(metrics.get("candidate_sources") or {})
    return {
        "unique_mutations": written >= int(targets.get("unique_mutations", 0)),
        "trajectory_rows": int(metrics["trajectory_rows"])
        >= int(targets.get("trajectory_rows", 0)),
        "dynamic_repositories": len(metrics["dynamic_repositories"])
        >= int(targets.get("dynamic_repositories", 0)),
        "required_dynamic_languages": set(
            str(language)
            for language in (targets.get("required_dynamic_languages") or [])
        ).issubset(metrics["dynamic_languages"]),
        "semantic_mutations": int(candidate_sources.get("llm", 0))
        >= int(targets.get("semantic_mutations", 0)),
        "terminal_operator_events": int(metrics["terminal_operator_events"])
        >= int(targets.get("terminal_operator_events", 0)),
        "terminal_operator_types": len(metrics["terminal_operator_types"])
        >= int(targets.get("terminal_operator_types", 0)),
        "terminal_argv_events": int(metrics["terminal_argv_events"])
        >= int(targets.get("terminal_argv_events", 0)),
        "success_rate": (
            requested > 0
            and success_rate >= float(targets.get("success_rate", 0.0))
        ),
    }


def _targets_met(metrics: dict[str, Any], targets: dict[str, Any]) -> bool:
    return all(_target_status(metrics, targets).values())


def generate_trajectory_corpus(
    catalog_path: str | Path,
    output_path: str | Path,
    *,
    cache_dir: str | Path = ".cache/murmurations/repos",
    work_dir: str | Path = ".cache/murmurations/work",
    episodes: int | None = None,
    episodes_per_repo: int | None = None,
    targets: dict[str, Any] | None = None,
    max_requests_per_repo: int = 80,
    max_successes_per_repo: int = 50,
    burst_per_repo: int = 4,
    max_requested_episodes: int | None = None,
    seed: int = 17,
    timeout_seconds: int = 120,
    max_attempts: int = 64,
    generation_retries: int = 4,
    failures_path: str | Path | None = None,
    enrichment_operators: tuple[str, ...] = (),
    max_enrichment_calls: int = 0,
    sandbox_runner=None,
    prune_checkouts: bool = False,
    concurrency: int | None = None,
    max_concurrency: int = 125,
    budget_usd: float | None = None,
    budget_safety_fraction: float = 0.90,
    host_disk_reserve_gib: float = 2.0,
    host_disk_per_worker_gib: float = 0.5,
    partitions_per_repo: int = 1,
    semantic_candidates_path: str | Path | None = None,
) -> dict[str, Any]:
    if sandbox_runner is None:
        raise RuntimeError(
            "dynamic corpus generation requires the configured Daytona sandbox"
        )
    if targets is not None and (episodes is not None or episodes_per_repo is not None):
        raise ValueError("target generation is mutually exclusive with fixed episode counts")
    if max_requests_per_repo <= 0 or max_successes_per_repo <= 0:
        raise ValueError("per-repository generation caps must be positive")
    if burst_per_repo <= 0:
        raise ValueError("burst_per_repo must be positive")
    if concurrency is not None and concurrency <= 0:
        raise ValueError("concurrency must be positive")
    if max_concurrency <= 0:
        raise ValueError("max_concurrency must be positive")
    if partitions_per_repo <= 0:
        raise ValueError("partitions_per_repo must be positive")

    catalog = RepoCatalog.from_jsonl(catalog_path)
    semantic_candidates = (
        _load_semantic_candidates(
            semantic_candidates_path,
            catalog=catalog,
        )
        if targets is not None
        else {}
    )
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    work_root = Path(work_dir)
    work_root.mkdir(parents=True, exist_ok=True)
    failures_output = (
        Path(failures_path)
        if failures_path is not None
        else output.with_suffix(".failures.jsonl")
    )
    failures_output.parent.mkdir(parents=True, exist_ok=True)

    mode = (
        {
            "kind": "targets",
            "max_requests_per_repo": max_requests_per_repo,
            "max_successes_per_repo": max_successes_per_repo,
            "burst_per_repo": burst_per_repo,
            "partitions_per_repo": partitions_per_repo,
            "semantic_candidates_sha256": _semantic_candidate_identity(
                semantic_candidates_path
            ),
        }
        if targets is not None
        else {
            "kind": "fixed",
            "episodes": episodes,
            "episodes_per_repo": episodes_per_repo,
        }
    )
    signature = _generation_signature(
        catalog,
        seed=seed,
        max_attempts=max_attempts,
        generation_retries=generation_retries,
        enrichment_operators=enrichment_operators,
        max_enrichment_calls=max_enrichment_calls,
        mode=mode,
        execution_identity=_execution_identity(sandbox_runner),
    )
    (
        used,
        repo_stats,
        next_local,
        processed,
        next_global,
        metrics,
    ) = _load_journal(
        output,
        failures_output,
        signature=signature,
        catalog=catalog,
    )
    resumed_requested = int(metrics["requested"])
    repo_index = {record.name: index for index, record in enumerate(catalog.records)}

    def record_failure(
        handle,
        repo: RepoRecord,
        *,
        local_index: int,
        global_index: int,
        error: Exception,
    ) -> None:
        row = {
            "generation_signature": signature,
            "repository": repo.name,
            "repo_episode_index": local_index,
            "global_episode_index": global_index,
            "error": str(error),
        }
        _append_jsonl(handle, row)
        processed.add((repo.name, local_index))
        next_local[repo.name] = max(next_local[repo.name], local_index + 1)
        repo_stats[repo.name]["requested"] += 1
        repo_stats[repo.name]["failed"] += 1
        metrics["requested"] += 1
        metrics["failed"] += 1

    def apply_outcome(
        episode_handle,
        failure_handle,
        outcome: _GenerationOutcome,
    ) -> None:
        repo = outcome.repository
        if outcome.record is None:
            row = {
                "generation_signature": signature,
                "repository": repo.name,
                "repo_episode_index": outcome.local_index,
                "global_episode_index": outcome.global_index,
                "error": str(outcome.error or "generation failed"),
            }
            _append_jsonl(failure_handle, row)
            processed.add((repo.name, outcome.local_index))
            next_local[repo.name] = max(
                next_local[repo.name], outcome.local_index + 1
            )
            repo_stats[repo.name]["requested"] += 1
            repo_stats[repo.name]["failed"] += 1
            metrics["requested"] += 1
            metrics["failed"] += 1
            return

        _append_jsonl(episode_handle, outcome.record)
        processed.add((repo.name, outcome.local_index))
        next_local[repo.name] = max(
            next_local[repo.name], outcome.local_index + 1
        )
        if outcome.raw_fingerprint:
            used[repo.name].add(outcome.raw_fingerprint)
        repo_stats[repo.name]["requested"] += 1
        repo_stats[repo.name]["written"] += 1
        metrics["requested"] += 1
        metrics["written"] += 1
        metrics["dynamic_repositories"].add(repo.name)
        metrics["dynamic_languages"].add(repo.language or "unknown")
        generation = dict(outcome.record.get("generation") or {})
        candidate_source = str(generation.get("candidate_source") or "deterministic")
        metrics["candidate_sources"][candidate_source] = (
            int(metrics["candidate_sources"].get(candidate_source, 0)) + 1
        )
        episode_metrics = _episode_metrics(outcome.record)
        metrics["trajectory_rows"] += int(episode_metrics["trajectory_rows"])
        metrics["terminal_operator_events"] += int(
            episode_metrics["terminal_operator_events"]
        )
        metrics["terminal_operator_types"].update(
            episode_metrics["terminal_operator_types"]
        )
        metrics["terminal_argv_events"] += int(
            episode_metrics["terminal_argv_events"]
        )

    def generate_slot(
        episode_handle,
        failure_handle,
        repo: RepoRecord,
        source: Path,
        verifier: list[str],
        *,
        local_index: int,
        global_index: int,
    ) -> None:
        last_error: Exception | None = None
        for retry in range(max(1, generation_retries)):
            attempt_seed = (
                seed
                + repo_index[repo.name] * 1_000_003
                + local_index * 101
                + retry
            )
            workspace = (
                work_root
                / _safe(repo.name)
                / f"episode-{local_index:06d}"
            )
            try:
                with sandbox_runner.workspace(
                    workspace,
                    repo,
                    plan_root=source,
                ) as remote:
                    mutation = inject_verified_mutation(
                        source,
                        workspace,
                        verifier,
                        seed=attempt_seed,
                        timeout_seconds=timeout_seconds,
                        max_attempts=max_attempts,
                        excluded_fingerprints=used[repo.name],
                        verify_runner=remote.verify,
                    )
                    registry = default_operator_registry(workspace)
                    episode = make_oracle_bootstrap_episode(
                        repo,
                        workspace,
                        mutation,
                        registry,
                        timeout_seconds=timeout_seconds,
                        episode_seed=attempt_seed,
                        enrichment_operators=enrichment_operators,
                        max_enrichment_calls=max_enrichment_calls,
                        command_runner=remote.run_operator,
                    )
                record = episode.record()
                raw_fingerprint = mutation.fingerprint
                record["mutation"]["fingerprint"] = canonical_id(
                    {
                        "repository_identity": repo.identity,
                        "mutation": raw_fingerprint,
                    }
                )
                record["generation"] = {
                    "signature": signature,
                    "seed": attempt_seed,
                    "repo_episode_index": local_index,
                    "global_episode_index": global_index,
                    "raw_mutation_fingerprint": raw_fingerprint,
                }
                _append_jsonl(episode_handle, record)
                processed.add((repo.name, local_index))
                next_local[repo.name] = max(next_local[repo.name], local_index + 1)
                used[repo.name].add(raw_fingerprint)
                repo_stats[repo.name]["requested"] += 1
                repo_stats[repo.name]["written"] += 1
                metrics["requested"] += 1
                metrics["written"] += 1
                metrics["dynamic_repositories"].add(repo.name)
                metrics["dynamic_languages"].add(repo.language or "unknown")
                episode_metrics = _episode_metrics(record)
                metrics["trajectory_rows"] += int(episode_metrics["trajectory_rows"])
                metrics["terminal_operator_events"] += int(
                    episode_metrics["terminal_operator_events"]
                )
                metrics["terminal_operator_types"].update(
                    episode_metrics["terminal_operator_types"]
                )
                metrics["terminal_argv_events"] += int(
                    episode_metrics["terminal_argv_events"]
                )
                return
            except Exception as exc:
                last_error = exc
            finally:
                shutil.rmtree(workspace, ignore_errors=True)

        assert last_error is not None
        record_failure(
            failure_handle,
            repo,
            local_index=local_index,
            global_index=global_index,
            error=last_error,
        )

    output.touch(exist_ok=True)
    failures_output.touch(exist_ok=True)
    with (
        output.open("a", encoding="utf-8") as episode_handle,
        failures_output.open("a", encoding="utf-8") as failure_handle,
    ):
        if targets is None:
            schedule = _schedule(
                catalog,
                episodes=episodes,
                episodes_per_repo=episodes_per_repo,
                seed=seed,
            )
            for repo, _repo_index, local_index in schedule:
                if (repo.name, local_index) in processed:
                    continue
                global_index = next_global
                next_global += 1
                source: Path | None = None
                try:
                    source = checkout_repository(repo, cache_dir)
                    verifier = detect_test_command(source)
                    if verifier is None:
                        raise RuntimeError(
                            "no supported repository test command detected"
                        )
                    generate_slot(
                        episode_handle,
                        failure_handle,
                        repo,
                        source,
                        verifier,
                        local_index=local_index,
                        global_index=global_index,
                    )
                except Exception as exc:
                    record_failure(
                        failure_handle,
                        repo,
                        local_index=local_index,
                        global_index=global_index,
                        error=exc,
                    )
                finally:
                    if (
                        prune_checkouts
                        and source is not None
                        and repo.path is None
                        and source.exists()
                    ):
                        shutil.rmtree(source, ignore_errors=True)
        else:
            configured_requested = (
                len(catalog.records) * max_requests_per_repo
                if max_requested_episodes is None
                else max_requested_episodes
            )
            if configured_requested <= 0:
                raise ValueError("max_requested_episodes must be positive")
            budget_plan = _daytona_budget_plan(
                sandbox_runner,
                requested_limit=configured_requested,
                generation_retries=generation_retries,
                budget_usd=budget_usd,
                budget_safety_fraction=budget_safety_fraction,
            )
            maximum_requested = int(budget_plan["requested_limit"])
            maximum_partition_workers = len(catalog.records) * partitions_per_repo
            requested_workers = min(
                maximum_partition_workers,
                concurrency if concurrency is not None else max_concurrency,
            )
            if hasattr(sandbox_runner, "concurrency_capacity"):
                capacity = sandbox_runner.concurrency_capacity(requested_workers)
                worker_count = int(capacity["workers"])
            else:
                capacity = {
                    "source": "configured_max",
                    "requested_max_workers": requested_workers,
                    "workers": requested_workers,
                }
                worker_count = requested_workers
            order = _balanced_repositories(catalog)
            required_languages = {
                str(language)
                for language in (targets.get("required_dynamic_languages") or [])
            }

            source_roots: dict[str, Path] = {}
            try:
                for repo in order:
                    source_roots[repo.name] = checkout_repository(repo, cache_dir)

                host_capacity = _host_disk_capacity(
                    work_root,
                    max_workers=worker_count,
                    reserve_gib=host_disk_reserve_gib,
                    per_worker_gib=host_disk_per_worker_gib,
                )
                worker_count = max(
                    1,
                    min(
                        worker_count,
                        int(host_capacity["workers"]),
                        maximum_partition_workers,
                    ),
                )
                print(
                    f"[generation] concurrency workers={worker_count} "
                    f"partitions_per_repo={partitions_per_repo} "
                    f"daytona_source={capacity.get('source')} "
                    f"host_free_gib={host_capacity['free_gib']:.2f} "
                    f"budget_ceiling_usd={budget_plan['theoretical_max_spend_usd']:.2f}",
                    flush=True,
                )

                scheduled_requests = int(metrics["requested"])
                stop_event = threading.Event()
                reserved_requests: dict[str, int] = defaultdict(int)
                in_flight_keys: set[tuple[str, int]] = set()
                futures: dict[Any, tuple[RepoRecord, int, int]] = {}

                with ThreadPoolExecutor(max_workers=worker_count) as executor:
                    while futures or (
                        not _targets_met(metrics, targets)
                        and scheduled_requests < maximum_requested
                    ):
                        if not _targets_met(metrics, targets):
                            prioritized = _prioritized_repositories(
                                order,
                                required_languages=required_languages,
                                present_languages=metrics["dynamic_languages"],
                            )
                            for repo in prioritized:
                                if len(futures) >= worker_count:
                                    break
                                stats = repo_stats[repo.name]
                                for partition_id in range(partitions_per_repo):
                                    if len(futures) >= worker_count:
                                        break
                                    if scheduled_requests >= maximum_requested:
                                        break
                                    key = (repo.name, partition_id)
                                    if key in in_flight_keys:
                                        continue

                                    effective_requested = (
                                        stats["requested"] + reserved_requests[repo.name]
                                    )
                                    effective_successes = (
                                        stats["written"] + reserved_requests[repo.name]
                                    )
                                    remaining_requests = (
                                        max_requests_per_repo - effective_requested
                                    )
                                    remaining_successes = (
                                        max_successes_per_repo - effective_successes
                                    )
                                    slot_count = min(
                                        burst_per_repo,
                                        remaining_requests,
                                        remaining_successes,
                                        maximum_requested - scheduled_requests,
                                    )
                                    if slot_count <= 0:
                                        continue

                                    slots: list[tuple[int, int]] = []
                                    for _ in range(slot_count):
                                        local_index = next_local[repo.name]
                                        global_index = next_global
                                        next_local[repo.name] += 1
                                        next_global += 1
                                        scheduled_requests += 1
                                        reserved_requests[repo.name] += 1
                                        slots.append((local_index, global_index))

                                    future = executor.submit(
                                        _generate_repo_burst,
                                        repo=repo,
                                        slots=slots,
                                        excluded_fingerprints=set(used[repo.name]),
                                        source=source_roots[repo.name],
                                        work_root=work_root,
                                        repo_index=repo_index[repo.name],
                                        seed=seed,
                                        timeout_seconds=timeout_seconds,
                                        max_attempts=max_attempts,
                                        generation_retries=generation_retries,
                                        enrichment_operators=enrichment_operators,
                                        max_enrichment_calls=max_enrichment_calls,
                                        sandbox_runner=sandbox_runner,
                                        signature=signature,
                                        partition_id=partition_id,
                                        partition_count=partitions_per_repo,
                                        semantic_candidates=semantic_candidates.get(
                                            repo.name, ()
                                        ),
                                        stop_event=stop_event,
                                    )
                                    futures[future] = (
                                        repo,
                                        partition_id,
                                        slot_count,
                                    )
                                    in_flight_keys.add(key)

                        if not futures:
                            break

                        done, _ = wait(futures, return_when=FIRST_COMPLETED)
                        for future in done:
                            repo, partition_id, slot_count = futures.pop(future)
                            in_flight_keys.discard((repo.name, partition_id))
                            reserved_requests[repo.name] -= slot_count
                            outcomes = future.result()
                            for outcome in outcomes:
                                apply_outcome(
                                    episode_handle,
                                    failure_handle,
                                    outcome,
                                )
                            if _targets_met(metrics, targets):
                                stop_event.set()
                            print(
                                f"[generation] checkpoint requested={metrics['requested']} "
                                f"written={metrics['written']} "
                                f"rows={metrics['trajectory_rows']} "
                                f"repos={len(metrics['dynamic_repositories'])} "
                                f"languages={len(metrics['dynamic_languages'])} "
                                f"in_flight={len(futures)}",
                                flush=True,
                            )
            finally:
                if prune_checkouts:
                    for repo in order:
                        source = source_roots.get(repo.name)
                        if (
                            source is not None
                            and repo.path is None
                            and source.exists()
                        ):
                            shutil.rmtree(source, ignore_errors=True)

    requested = int(metrics["requested"])
    written = int(metrics["written"])
    result: dict[str, Any] = {
        "generation_signature": signature,
        "resumed_requested": resumed_requested,
        "requested": requested,
        "written": written,
        "failed": int(metrics["failed"]),
        "success_rate": written / max(1, requested),
        "unique_mutations": written,
        "trajectory_rows": int(metrics["trajectory_rows"]),
        "dynamic_repositories": len(metrics["dynamic_repositories"]),
        "dynamic_languages": sorted(metrics["dynamic_languages"]),
        "candidate_sources": dict(sorted(metrics["candidate_sources"].items())),
        "terminal_operator_events": int(metrics["terminal_operator_events"]),
        "terminal_operator_types": len(metrics["terminal_operator_types"]),
        "terminal_argv_events": int(metrics["terminal_argv_events"]),
        "repositories": dict(sorted(repo_stats.items())),
        "failures": str(failures_output),
        "output": str(output),
    }
    if targets is not None:
        result["concurrency"] = {
            "workers": worker_count,
            "capacity": capacity,
            "host_disk": host_capacity,
        }
        result["budget"] = budget_plan
        result["targets"] = targets
        result["target_status"] = _target_status(metrics, targets)
        result["targets_met"] = all(result["target_status"].values())
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--catalog", required=True, help="JSONL repository catalog")
    parser.add_argument("--output", required=True, help="Episode JSONL output")
    parser.add_argument("--cache-dir", default=".cache/murmurations/repos")
    parser.add_argument("--work-dir", default=".cache/murmurations/work")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--episodes", type=int, default=None)
    group.add_argument("--episodes-per-repo", type=int, default=None)
    parser.add_argument("--target-unique-mutations", type=int, default=None)
    parser.add_argument("--target-trajectory-rows", type=int, default=None)
    parser.add_argument("--target-dynamic-repositories", type=int, default=None)
    parser.add_argument("--max-requests-per-repo", type=int, default=80)
    parser.add_argument("--max-successes-per-repo", type=int, default=50)
    parser.add_argument("--burst-per-repo", type=int, default=4)
    parser.add_argument("--max-requested-episodes", type=int, default=None)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--timeout-seconds", type=int, default=120)
    parser.add_argument("--max-attempts", type=int, default=64)
    parser.add_argument("--generation-retries", type=int, default=4)
    parser.add_argument("--failures", default=None)
    parser.add_argument("--enrichment-operator", action="append", default=[])
    parser.add_argument("--max-enrichment-calls", type=int, default=0)
    parser.add_argument("--prune-checkouts", action="store_true")
    args = parser.parse_args()

    config = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    sandbox = DaytonaCorpusRunner.from_config(dict(config.get("sandbox") or {}))
    sandbox.validate_environment()
    targets = None
    if any(
        value is not None
        for value in (
            args.target_unique_mutations,
            args.target_trajectory_rows,
            args.target_dynamic_repositories,
        )
    ):
        targets = {
            "unique_mutations": int(args.target_unique_mutations or 0),
            "trajectory_rows": int(args.target_trajectory_rows or 0),
            "dynamic_repositories": int(args.target_dynamic_repositories or 0),
            "terminal_operator_events": 0,
            "terminal_operator_types": 0,
            "terminal_argv_events": 0,
            "success_rate": 0.0,
        }
    report = generate_trajectory_corpus(
        args.catalog,
        args.output,
        cache_dir=args.cache_dir,
        work_dir=args.work_dir,
        episodes=args.episodes,
        episodes_per_repo=args.episodes_per_repo,
        targets=targets,
        max_requests_per_repo=args.max_requests_per_repo,
        max_successes_per_repo=args.max_successes_per_repo,
        burst_per_repo=args.burst_per_repo,
        max_requested_episodes=args.max_requested_episodes,
        seed=args.seed,
        timeout_seconds=args.timeout_seconds,
        max_attempts=args.max_attempts,
        generation_retries=args.generation_retries,
        failures_path=args.failures,
        enrichment_operators=tuple(args.enrichment_operator),
        max_enrichment_calls=args.max_enrichment_calls,
        sandbox_runner=sandbox,
        prune_checkouts=args.prune_checkouts,
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    if report["written"] == 0:
        raise SystemExit("no valid episodes were generated")


if __name__ == "__main__":
    main()
