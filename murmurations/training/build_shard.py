"""Build and validate a reproducible Murmurations corpus shard."""

from __future__ import annotations

import argparse
from collections import defaultdict, deque
import json
import math
from pathlib import Path
from typing import Any

import yaml

from murmurations.training.corpus import validate_corpus_shard
from murmurations.training.environments.repositories import RepoCatalog, RepoRecord
from murmurations.training.generate_trajectories import generate_trajectory_corpus
from murmurations.training.materialize import materialize_file
from murmurations.training.materialize_code import materialize_repository_code
from murmurations.training.probe_repositories import probe_repository_catalog
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
    )

    _log(
        f"static materialization complete rows="
        f"{int(code.get('train_rows', 0)) + int(code.get('eval_rows', 0))}"
    )

    # Dynamic episodes use only repositories whose clean verifier passes inside
    # the pinned Daytona corpus snapshot. Repository code is never executed on
    # the corpus-generation host.
    _log("probing clean-verifier eligibility in Daytona")
    probe = probe_repository_catalog(
        catalog_path,
        cache_dir=cache_dir,
        timeout_seconds=timeout_seconds,
        report_path=paths["probe_report"],
        eligible_catalog_path=paths["eligible_catalog"],
        sandbox_runner=sandbox,
        concurrency=int(config.get("probe_concurrency", 1)),
        local_checkout_concurrency=int(
            config.get("probe_local_checkout_concurrency", 1)
        ),
    )
    _log(
        f"probe complete eligible={probe['eligible']}/{probe['repositories']} "
        f"rate={probe['eligibility_rate']:.3f}"
    )
    if int(probe["eligible"]) == 0:
        raise RuntimeError("no repositories passed the clean-verifier eligibility probe")

    requested_per_repo = (
        episodes_per_repo
        if episodes_per_repo is not None
        else int(config.get("episodes_per_repo", 20))
    )
    enrichment = dict(config.get("terminal_evidence") or {})
    enrichment_operators = tuple(enrichment.get("operators") or ())
    max_enrichment_calls = (
        int(enrichment.get("max_calls_per_episode", 0))
        if bool(enrichment.get("enabled", False))
        else 0
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
        seed=int(config.get("seed", 17)),
        timeout_seconds=timeout_seconds,
        max_attempts=int(config.get("max_mutation_attempts", 64)),
        generation_retries=int(config.get("generation_retries", 4)),
        failures_path=paths["failures"],
        enrichment_operators=enrichment_operators,
        max_enrichment_calls=max_enrichment_calls,
        sandbox_runner=sandbox,
    )
    _log(
        f"trajectory generation complete written={generation['written']} "
        f"requested={generation['requested']} rate={generation['success_rate']:.3f}"
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

    quality = dict(config.get("quality") or {})
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
