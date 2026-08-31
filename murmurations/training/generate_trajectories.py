"""Generate verifier-grounded Murmurations repair episodes from repositories."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
from typing import Any

from murmurations.training.environments.episodes import make_oracle_bootstrap_episode
from murmurations.training.environments.mutations import inject_verified_mutation
from murmurations.training.environments.repositories import RepoCatalog, RepoRecord, checkout_repository
from murmurations.training.operators import default_operator_registry, detect_test_command
from murmurations.utils.canonical import canonical_id


def _safe(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)


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
        return [
            (repo, repo_index, local_index)
            for repo_index, repo in enumerate(catalog.records)
            for local_index in range(episodes_per_repo)
        ]
    requested = 10 if episodes is None else episodes
    if requested <= 0:
        raise ValueError("episodes must be positive")
    return [
        (catalog.sample(seed + index), -1, index)
        for index in range(requested)
    ]


def generate_trajectory_corpus(
    catalog_path: str | Path,
    output_path: str | Path,
    *,
    cache_dir: str | Path = ".cache/murmurations/repos",
    work_dir: str | Path = ".cache/murmurations/work",
    episodes: int | None = None,
    episodes_per_repo: int | None = None,
    seed: int = 17,
    timeout_seconds: int = 120,
    max_attempts: int = 64,
    generation_retries: int = 4,
    failures_path: str | Path | None = None,
    enrichment_operators: tuple[str, ...] = (),
    max_enrichment_calls: int = 0,
    sandbox_runner=None,
) -> dict[str, Any]:
    if sandbox_runner is None:
        raise RuntimeError(
            "dynamic corpus generation requires the configured Daytona sandbox"
        )
    catalog = RepoCatalog.from_jsonl(catalog_path)
    schedule = _schedule(
        catalog,
        episodes=episodes,
        episodes_per_repo=episodes_per_repo,
        seed=seed,
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

    used: dict[str, set[str]] = defaultdict(set)
    repo_stats: dict[str, dict[str, int]] = defaultdict(
        lambda: {"requested": 0, "written": 0, "failed": 0}
    )
    failures: list[dict[str, Any]] = []
    written = 0

    with output.open("w", encoding="utf-8") as handle:
        for global_index, (repo, repo_index, local_index) in enumerate(schedule):
            repo_stats[repo.name]["requested"] += 1
            source: Path | None = None
            verifier: list[str] | None = None
            last_error: Exception | None = None

            try:
                source = checkout_repository(repo, cache_dir)
                verifier = detect_test_command(source)
                if verifier is None:
                    raise RuntimeError("no supported repository test command detected")
            except Exception as exc:
                last_error = exc

            if source is not None and verifier is not None:
                for retry in range(max(1, generation_retries)):
                    attempt_seed = (
                        seed
                        + (repo_index if repo_index >= 0 else global_index) * 1_000_003
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
                        record["mutation"]["fingerprint"] = canonical_id(
                            {
                                "repository_identity": repo.identity,
                                "mutation": mutation.fingerprint,
                            }
                        )
                        record["generation"] = {
                            "seed": attempt_seed,
                            "repo_episode_index": local_index,
                            "global_episode_index": global_index,
                        }
                        handle.write(json.dumps(record, sort_keys=True) + "\n")
                        used[repo.name].add(mutation.fingerprint)
                        written += 1
                        repo_stats[repo.name]["written"] += 1
                        last_error = None
                        break
                    except Exception as exc:
                        last_error = exc

            if last_error is not None:
                repo_stats[repo.name]["failed"] += 1
                failures.append(
                    {
                        "repository": repo.name,
                        "repo_episode_index": local_index,
                        "global_episode_index": global_index,
                        "error": str(last_error),
                    }
                )

    with failures_output.open("w", encoding="utf-8") as handle:
        for failure in failures:
            handle.write(json.dumps(failure, sort_keys=True) + "\n")

    requested = len(schedule)
    return {
        "requested": requested,
        "written": written,
        "failed": requested - written,
        "success_rate": written / max(1, requested),
        "unique_mutations": sum(len(values) for values in used.values()),
        "repositories": dict(sorted(repo_stats.items())),
        "failures": str(failures_output),
        "output": str(output),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True, help="JSONL repository catalog")
    parser.add_argument("--output", required=True, help="Episode JSONL output")
    parser.add_argument("--cache-dir", default=".cache/murmurations/repos")
    parser.add_argument("--work-dir", default=".cache/murmurations/work")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--episodes", type=int, default=None)
    group.add_argument("--episodes-per-repo", type=int, default=None)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--timeout-seconds", type=int, default=120)
    parser.add_argument("--max-attempts", type=int, default=64)
    parser.add_argument("--generation-retries", type=int, default=4)
    parser.add_argument("--failures", default=None)
    parser.add_argument("--enrichment-operator", action="append", default=[])
    parser.add_argument("--max-enrichment-calls", type=int, default=0)
    args = parser.parse_args()

    report = generate_trajectory_corpus(
        args.catalog,
        args.output,
        cache_dir=args.cache_dir,
        work_dir=args.work_dir,
        episodes=args.episodes,
        episodes_per_repo=args.episodes_per_repo,
        seed=args.seed,
        timeout_seconds=args.timeout_seconds,
        max_attempts=args.max_attempts,
        generation_retries=args.generation_retries,
        failures_path=args.failures,
        enrichment_operators=tuple(args.enrichment_operator),
        max_enrichment_calls=args.max_enrichment_calls,
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    if report["written"] == 0:
        raise SystemExit("no valid episodes were generated")


if __name__ == "__main__":
    main()
