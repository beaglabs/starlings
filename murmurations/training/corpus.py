"""Corpus-shard statistics, provenance digests, and hard QA gates."""

from __future__ import annotations

from collections import Counter
import hashlib
import json
from pathlib import Path
from typing import Any, Iterable

from murmurations.training.environments.repositories import RepoCatalog


def iter_jsonl(path: str | Path) -> Iterable[dict[str, Any]]:
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid JSONL") from exc


def file_digest(path: str | Path) -> dict[str, Any]:
    target = Path(path)
    digest = hashlib.sha256()
    rows = 0
    size = 0
    with target.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
            size += len(block)
            rows += block.count(b"
")
    return {"sha256": digest.hexdigest(), "bytes": size, "lines": rows}


def _row_stats(paths: list[str | Path]) -> dict[str, Any]:
    rows = 0
    operations: Counter[str] = Counter()
    argument_kinds: Counter[str] = Counter()
    source_types: Counter[str] = Counter()
    repositories: Counter[str] = Counter()
    repository_ids: set[str] = set()
    languages: Counter[str] = Counter()
    licenses: Counter[str] = Counter()

    for path in paths:
        for row in iter_jsonl(path):
            rows += 1
            operations[str(row.get("operation", "NOOP"))] += 1
            argument = row.get("argument") or {}
            argument_kinds[str(argument.get("kind", "NONE"))] += 1
            provenance = row.get("provenance") or {}
            source_types[str(provenance.get("source_type", "trajectory"))] += 1
            repo = provenance.get("repository")
            if repo:
                repositories[str(repo)] += 1
            repo_id = provenance.get("repository_identity")
            if repo_id:
                repository_ids.add(str(repo_id))
            language = provenance.get("language")
            if language:
                languages[str(language)] += 1
            license_name = provenance.get("license")
            if license_name:
                licenses[str(license_name)] += 1

    return {
        "rows": rows,
        "operations": dict(sorted(operations.items())),
        "argument_kinds": dict(sorted(argument_kinds.items())),
        "source_types": dict(sorted(source_types.items())),
        "repositories": dict(sorted(repositories.items())),
        "repository_identities": sorted(repository_ids),
        "languages": dict(sorted(languages.items())),
        "licenses": dict(sorted(licenses.items())),
    }


def _episode_stats(path: str | Path) -> dict[str, Any]:
    episodes = 0
    events = 0
    repositories: Counter[str] = Counter()
    languages: Counter[str] = Counter()
    licenses: Counter[str] = Counter()
    operations: Counter[str] = Counter()
    operator_refs: Counter[str] = Counter()
    mutation_kinds: Counter[str] = Counter()
    fingerprints: Counter[str] = Counter()

    for episode in iter_jsonl(path):
        episodes += 1
        repository = episode.get("repository") or {}
        repositories[str(repository.get("name", "unknown"))] += 1
        languages[str(repository.get("language", "unknown"))] += 1
        licenses[str(repository.get("license", "unknown"))] += 1
        mutation = episode.get("mutation") or {}
        mutation_kinds[str(mutation.get("kind", "unknown"))] += 1
        fingerprint = mutation.get("fingerprint")
        if fingerprint:
            fingerprints[str(fingerprint)] += 1

        for event in episode.get("events", []):
            events += 1
            frame = event.get("frame") or {}
            operations[str(frame.get("operation", "unknown"))] += 1
            operator = frame.get("operator_ref")
            if operator:
                operator_refs[str(operator)] += 1

    duplicates = {
        fingerprint: count
        for fingerprint, count in fingerprints.items()
        if count > 1
    }
    return {
        "episodes": episodes,
        "events": events,
        "repositories": dict(sorted(repositories.items())),
        "languages": dict(sorted(languages.items())),
        "licenses": dict(sorted(licenses.items())),
        "operations": dict(sorted(operations.items())),
        "operator_refs": dict(sorted(operator_refs.items())),
        "mutation_kinds": dict(sorted(mutation_kinds.items())),
        "unique_mutations": len(fingerprints),
        "duplicate_mutations": duplicates,
    }


def validate_corpus_shard(
    *,
    catalog_path: str | Path,
    episodes_path: str | Path,
    code_train_path: str | Path,
    code_eval_path: str | Path,
    trajectory_train_path: str | Path,
    trajectory_eval_path: str | Path,
    generation_report: dict[str, Any],
    quality: dict[str, Any],
) -> dict[str, Any]:
    catalog = RepoCatalog.from_jsonl(catalog_path)
    catalog_languages = Counter(record.language or "unknown" for record in catalog.records)
    catalog_licenses = Counter(record.license for record in catalog.records)

    episodes = _episode_stats(episodes_path)
    train = _row_stats([code_train_path, trajectory_train_path])
    evaluation = _row_stats([code_eval_path, trajectory_eval_path])
    code_stats = _row_stats([code_train_path, code_eval_path])
    trajectory_stats = _row_stats([trajectory_train_path, trajectory_eval_path])

    train_ids = set(train["repository_identities"])
    eval_ids = set(evaluation["repository_identities"])
    leakage = sorted(train_ids & eval_ids)

    files = {
        "catalog": file_digest(catalog_path),
        "episodes": file_digest(episodes_path),
        "code_train": file_digest(code_train_path),
        "code_eval": file_digest(code_eval_path),
        "trajectory_train": file_digest(trajectory_train_path),
        "trajectory_eval": file_digest(trajectory_eval_path),
    }

    gates = {
        "catalog_repositories": len(catalog.records)
        >= int(quality.get("min_catalog_repositories", 1)),
        "generation_success_rate": float(generation_report.get("success_rate", 0.0))
        >= float(quality.get("min_generation_success_rate", 0.0)),
        "eligible_repositories": int(
            generation_report.get("eligible_repositories", len(episodes["repositories"]))
        )
        >= int(quality.get("min_eligible_repositories", 1)),
        "dynamic_repositories": len(episodes["repositories"])
        >= int(quality.get("min_dynamic_repositories", 1)),
        "unique_mutations": int(episodes["unique_mutations"])
        >= int(quality.get("min_unique_mutations", 1)),
        "code_rows": int(code_stats["rows"])
        >= int(quality.get("min_code_rows", 1)),
        "trajectory_rows": int(trajectory_stats["rows"])
        >= int(quality.get("min_trajectory_rows", 1)),
        "no_split_leakage": not leakage,
        "no_duplicate_mutations": not episodes["duplicate_mutations"],
    }

    return {
        "passed": all(gates.values()),
        "gates": gates,
        "catalog": {
            "repositories": len(catalog.records),
            "languages": dict(sorted(catalog_languages.items())),
            "licenses": dict(sorted(catalog_licenses.items())),
        },
        "generation": generation_report,
        "episodes": episodes,
        "rows": {
            "train": train,
            "eval": evaluation,
            "code": code_stats,
            "trajectory": trajectory_stats,
        },
        "split_leakage": leakage,
        "files": files,
    }
