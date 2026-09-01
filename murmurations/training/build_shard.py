"""Build and validate a reproducible Murmurations corpus shard."""

from __future__ import annotations

import argparse
from collections import defaultdict, deque
import json
import math
from pathlib import Path
import shutil
from typing import Any

import yaml

from murmurations.training.corpus import validate_corpus_shard
from murmurations.training.environments.repositories import RepoCatalog, RepoRecord
from murmurations.training.generate_trajectories import generate_trajectory_corpus
from murmurations.training.materialize import materialize_file
from murmurations.training.materialize_code import materialize_repository_code
from murmurations.training.probe_repositories import load_probe_artifacts, probe_repository_catalog
from murmurations.training.daytona import DaytonaCorpusRunner




def _log(message: str) -> None:
    print(f"[corpus] {message}", flush=True)


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _record_dict(record: RepoRecord) -> dict[str, Any]:
    return {
        "name": record.name,
        "commit": record.commit,
        "license": record.license,
        "language": record.language,
        "url": record.url,
        "path": record.path,
    }


def _select_stratified(catalog: RepoCatalog, limit: int) -> list[RepoRecord]:
    if limit <= 0:
        raise ValueError("limit_repositories must be positive")
    if limit >= len(catalog.records):
        return list(catalog.records)

    groups: dict[str, deque[RepoRecord]] = defaultdict(deque)
    for record in catalog.records:
        groups[record.language or "unknown"].append(record)

    selected: list[RepoRecord] = []
    languages = sorted(groups)
    while len(selected) < limit:
        progressed = False
        for language in languages:
            if groups[language] and len(selected) < limit:
                selected.append(groups[language].popleft())
                progressed = True
        if not progressed:
            break
    return selected


def _catalog_for_run(
    source_path: str | Path,
    output_dir: Path,
    limit_repositories: int | None,
) -> Path:
    source = Path(source_path)
    if limit_repositories is None:
        return source
    catalog = RepoCatalog.from_jsonl(source)
    selected = _select_stratified(catalog, limit_repositories)
    path = output_dir / "catalog-subset.jsonl"
    with path.open("w", encoding="utf-8") as handle:
        for record in selected:
            handle.write(json.dumps(_record_dict(record), sort_keys=True) + "\n")
    return path


def _copy_artifact(source: Path, target: Path) -> None:
    if source.resolve() == target.resolve():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def _full_generation_targets(quality: dict[str, Any]) -> dict[str, Any]:
    return {
        "unique_mutations": int(quality.get("min_unique_mutations", 0)),
        "trajectory_rows": int(quality.get("min_trajectory_rows", 0)),
        "dynamic_repositories": int(quality.get("min_dynamic_repositories", 0)),
        "required_dynamic_languages": [
            str(language)
            for language in (quality.get("required_dynamic_languages") or [])
        ],
        "terminal_operator_events": int(quality.get("min_terminal_operator_events", 0)),
        "terminal_operator_types": int(quality.get("min_terminal_operator_types", 0)),
        "terminal_argv_events": int(quality.get("min_terminal_argv_events", 0)),
        "success_rate": float(quality.get("min_generation_success_rate", 0.0)),
    }


def build_shard(
    config_path: str | Path,
    *,
    limit_repositories: int | None = None,
    episodes_per_repo: int | None = None,
) -> dict[str, Any]:
    config = yaml.safe_load(Path(config_path).read_text(encoding="utf-8"))
    output_dir = Path(config["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    sandbox_config = dict(config.get("sandbox") or {})
    if not sandbox_config:
        raise RuntimeError("serious corpus generation requires a Daytona sandbox config")
    sandbox = DaytonaCorpusRunner.from_config(sandbox_config)
    _log("validating Daytona snapshot")
    sandbox.validate_environment()
    catalog_path = _catalog_for_run(
        config["catalog"], output_dir, limit_repositories
    )

    cache_dir = config.get("cache_dir", ".cache/murmurations/repos")
    work_dir = config.get("work_dir", ".cache/murmurations/work")
    eval_fraction = float(config.get("eval_fraction", 0.1))
    timeout_seconds = int(config.get("timeout_seconds", 120))
    quality = dict(config.get("quality") or {})

    paths = {
        "eligible_catalog": output_dir / "eligible-repos.jsonl",
        "probe_report": output_dir / "repo-probe.json",
        "episodes": output_dir / "episodes.jsonl",
        "failures": output_dir / "episode-failures.jsonl",
        "code_train": output_dir / "code-train.jsonl",
        "code_eval": output_dir / "code-eval.jsonl",
        "trajectory_train": output_dir / "trajectory-train.jsonl",
        "trajectory_eval": output_dir / "trajectory-eval.jsonl",
        "generation_report": output_dir / "generation-report.json",
        "qa_report": output_dir / "qa-report.json",
        "manifest": output_dir / "manifest.json",
    }

    # Dynamic episodes use only repositories whose clean verifier passes inside
    # the pinned Daytona corpus snapshot. Reuse a complete standalone probe only
    # when its exact catalog and snapshot/plan signature still match.
    probe = None
    probe_cache = dict(config.get("probe_cache") or {})
    if limit_repositories is None and probe_cache:
        cached_report = Path(str(probe_cache.get("report") or ""))
        cached_eligible = Path(str(probe_cache.get("eligible_catalog") or ""))
        if cached_report.exists() and cached_eligible.exists():
            _log("validating cached clean-verifier probe")
            try:
                probe = load_probe_artifacts(
                    catalog_path,
                    cached_report,
                    cached_eligible,
                    sandbox_runner=sandbox,
                )
            except (RuntimeError, ValueError):
                _log("cached clean-verifier probe is stale; recomputing")
                probe = None
            else:
                _copy_artifact(cached_report, paths["probe_report"])
                _copy_artifact(cached_eligible, paths["eligible_catalog"])
                _log(
                    f"reused probe eligible={probe['eligible']}/{probe['repositories']} "
                    f"rate={probe['eligibility_rate']:.3f}"
                )

    if probe is None:
        _log("probing clean-verifier eligibility in Daytona")
        probe = probe_repository_catalog(
            catalog_path,
            cache_dir=cache_dir,
            timeout_seconds=timeout_seconds,
            report_path=paths["probe_report"],
            eligible_catalog_path=paths["eligible_catalog"],
            sandbox_runner=sandbox,
            concurrency=int(config.get("probe_concurrency", 1)),
        )
        _log(
            f"probe complete eligible={probe['eligible']}/{probe['repositories']} "
            f"rate={probe['eligibility_rate']:.3f}"
        )
    if int(probe["eligible"]) == 0:
        raise RuntimeError("no repositories passed the clean-verifier eligibility probe")

    if limit_repositories is None:
        required_languages = {
            str(language)
            for language in (quality.get("required_dynamic_languages") or [])
        }
        eligible_catalog = RepoCatalog.from_jsonl(paths["eligible_catalog"])
        eligible_languages = {
            record.language or "unknown" for record in eligible_catalog.records
        }
        missing_languages = sorted(required_languages - eligible_languages)
        if missing_languages:
            raise RuntimeError(
                "clean-verifier eligibility is missing required dynamic languages: "
                + ", ".join(missing_languages)
            )

    # Static code/document windows use every pinned permissive repository.
    _log("materializing static code/document windows")
    code = materialize_repository_code(
        catalog_path,
        paths["code_train"],
        paths["code_eval"],
        cache_dir=cache_dir,
        eval_fraction=eval_fraction,
        chunk_chars=int(config.get("code_chunk_chars", 6000)),
        max_files_per_repo=int(config.get("max_files_per_repo", 2000)),
        prune_checkouts=True,
        concurrency=(
            None
            if str(generation_config.get("concurrency", "auto")).lower() == "auto"
            else int(generation_config["concurrency"])
        ),
        max_concurrency=int(generation_config.get("max_concurrency", 125)),
        budget_usd=(
            float(generation_config["budget_usd"])
            if generation_config.get("budget_usd") is not None
            else None
        ),
        budget_safety_fraction=float(
            generation_config.get("budget_safety_fraction", 0.90)
        ),
        host_disk_reserve_gib=float(
            generation_config.get("host_disk_reserve_gib", 2.0)
        ),
        host_disk_per_worker_gib=float(
            generation_config.get("host_disk_per_worker_gib", 0.5)
        ),
    )

    _log(
        f"static materialization complete rows="
        f"{int(code.get('train_rows', 0)) + int(code.get('eval_rows', 0))}"
    )

    enrichment = dict(config.get("terminal_evidence") or {})
    enrichment_operators = tuple(enrichment.get("operators") or ())
    max_enrichment_calls = (
        int(enrichment.get("max_calls_per_episode", 0))
        if bool(enrichment.get("enabled", False))
        else 0
    )
    generation_config = dict(config.get("generation") or {})
    target_mode = (
        limit_repositories is None
        and episodes_per_repo is None
        and str(generation_config.get("mode", "targets")) == "targets"
    )
    requested_per_repo = None
    targets = None
    if target_mode:
        targets = _full_generation_targets(quality)
        _log(
            "generating repair trajectories to targets "
            f"mutations>={targets['unique_mutations']} "
            f"rows>={targets['trajectory_rows']} "
            f"dynamic_repos>={targets['dynamic_repositories']}"
        )
    else:
        requested_per_repo = (
            episodes_per_repo
            if episodes_per_repo is not None
            else int(generation_config.get("fixed_episodes_per_repo", 2))
        )
        _log(
            f"generating repair trajectories repos={probe['eligible']} "
            f"episodes_per_repo={requested_per_repo}"
        )

    generation = generate_trajectory_corpus(
        paths["eligible_catalog"],
        paths["episodes"],
        cache_dir=cache_dir,
        work_dir=work_dir,
        episodes_per_repo=requested_per_repo,
        targets=targets,
        max_requests_per_repo=int(generation_config.get("max_requests_per_repo", 80)),
        max_successes_per_repo=int(generation_config.get("max_successes_per_repo", 50)),
        burst_per_repo=int(generation_config.get("burst_per_repo", 4)),
        max_requested_episodes=(
            int(generation_config["max_requested_episodes"])
            if generation_config.get("max_requested_episodes") is not None
            else None
        ),
        seed=int(config.get("seed", 17)),
        timeout_seconds=timeout_seconds,
        max_attempts=int(config.get("max_mutation_attempts", 64)),
        generation_retries=int(config.get("generation_retries", 4)),
        failures_path=paths["failures"],
        enrichment_operators=enrichment_operators,
        max_enrichment_calls=max_enrichment_calls,
        sandbox_runner=sandbox,
        prune_checkouts=True,
    )
    _log(
        f"trajectory generation complete written={generation['written']} "
        f"requested={generation['requested']} rate={generation['success_rate']:.3f}"
    )
    if generation.get("concurrency"):
        _log(
            f"generation concurrency workers="
            f"{generation['concurrency']['workers']} "
            f"source={generation['concurrency']['capacity'].get('source')}"
        )
    if generation.get("budget"):
        _log(
            f"generation budget theoretical_ceiling_usd="
            f"{generation['budget']['theoretical_max_spend_usd']:.2f}"
        )
    generation["eligible_repositories"] = int(probe["eligible"])
    generation["catalog_repositories"] = int(probe["repositories"])
    _write_json(paths["generation_report"], generation)

    _log("materializing trajectory rows")
    trajectory = materialize_file(
        paths["episodes"],
        paths["trajectory_train"],
        paths["trajectory_eval"],
        eval_fraction=eval_fraction,
        max_context_chars=int(config.get("max_context_chars", 12000)),
    )

    if limit_repositories is not None:
        probe_success = float(quality.get("min_generation_success_rate", 0.0))
        eligible_for_probe = max(1, int(probe["eligible"]))
        expected_successes = max(
            1,
            math.ceil(eligible_for_probe * requested_per_repo * probe_success),
        )
        expected_dynamic_repos = max(
            1,
            math.ceil(eligible_for_probe * probe_success),
        )
        quality["min_catalog_repositories"] = min(
            int(quality.get("min_catalog_repositories", 1)),
            limit_repositories,
        )
        quality["min_eligible_repositories"] = min(
            int(quality.get("min_eligible_repositories", 1)),
            eligible_for_probe,
        )
        quality["min_dynamic_repositories"] = min(
            int(quality.get("min_dynamic_repositories", 1)),
            expected_dynamic_repos,
        )
        quality["min_unique_mutations"] = min(
            int(quality.get("min_unique_mutations", 1)),
            expected_successes,
        )
        quality["min_code_rows"] = 1
        quality["min_trajectory_rows"] = max(1, expected_successes)
        if "min_terminal_operator_events" in quality:
            quality["min_terminal_operator_events"] = 1
        if "min_terminal_operator_types" in quality:
            quality["min_terminal_operator_types"] = 1
        if "min_terminal_argv_events" in quality:
            quality["min_terminal_argv_events"] = 1

        quality["required_dynamic_languages"] = []

    _log("running shard QA")
    qa = validate_corpus_shard(
        catalog_path=catalog_path,
        episodes_path=paths["episodes"],
        code_train_path=paths["code_train"],
        code_eval_path=paths["code_eval"],
        trajectory_train_path=paths["trajectory_train"],
        trajectory_eval_path=paths["trajectory_eval"],
        generation_report=generation,
        quality=quality,
    )
    _write_json(paths["qa_report"], qa)
    _log(f"QA complete passed={qa['passed']}")

    manifest = {
        "version": 1,
        "name": config.get("name", output_dir.name),
        "config": config,
        "sandbox": sandbox.provenance(),
        "catalog": str(catalog_path),
        "eligible_catalog": str(paths["eligible_catalog"]),
        "code": code,
        "probe": probe,
        "generation": generation,
        "trajectory": trajectory,
        "qa": qa,
    }
    _write_json(paths["manifest"], manifest)
    if not qa["passed"]:
        failed = [name for name, passed in qa["gates"].items() if not passed]
        raise RuntimeError("corpus shard failed QA gates: " + ", ".join(failed))
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--limit-repositories", type=int, default=None)
    parser.add_argument("--episodes-per-repo", type=int, default=None)
    args = parser.parse_args()
    manifest = build_shard(
        args.config,
        limit_repositories=args.limit_repositories,
        episodes_per_repo=args.episodes_per_repo,
    )
    print(
        json.dumps(
            {
                "name": manifest["name"],
                "passed": manifest["qa"]["passed"],
                "catalog_repositories": manifest["qa"]["catalog"]["repositories"],
                "eligible_repositories": manifest["probe"]["eligible"],
                "episodes": manifest["qa"]["episodes"]["episodes"],
                "code_rows": manifest["qa"]["rows"]["code"]["rows"],
                "trajectory_rows": manifest["qa"]["rows"]["trajectory"]["rows"],
                "output_dir": manifest["config"]["output_dir"],
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
