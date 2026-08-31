"""Build and validate a reproducible Murmurations corpus shard."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import yaml

from murmurations.training.corpus import validate_corpus_shard
from murmurations.training.environments.repositories import RepoCatalog
from murmurations.training.generate_trajectories import generate_trajectory_corpus
from murmurations.training.materialize import materialize_file
from murmurations.training.materialize_code import materialize_repository_code


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "
", encoding="utf-8")


def _catalog_for_run(
    source_path: str | Path,
    output_dir: Path,
    limit_repositories: int | None,
) -> Path:
    source = Path(source_path)
    if limit_repositories is None:
        return source
    catalog = RepoCatalog.from_jsonl(source)
    if limit_repositories <= 0:
        raise ValueError("limit_repositories must be positive")
    selected = catalog.records[:limit_repositories]
    path = output_dir / "catalog-subset.jsonl"
    with path.open("w", encoding="utf-8") as handle:
        for record in selected:
            row = {
                "name": record.name,
                "commit": record.commit,
                "license": record.license,
                "language": record.language,
                "url": record.url,
                "path": record.path,
            }
            handle.write(json.dumps(row, sort_keys=True) + "
")
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
    catalog_path = _catalog_for_run(
        config["catalog"], output_dir, limit_repositories
    )

    cache_dir = config.get("cache_dir", ".cache/murmurations/repos")
    work_dir = config.get("work_dir", ".cache/murmurations/work")
    eval_fraction = float(config.get("eval_fraction", 0.1))

    paths = {
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

    code = materialize_repository_code(
        catalog_path,
        paths["code_train"],
        paths["code_eval"],
        cache_dir=cache_dir,
        eval_fraction=eval_fraction,
        chunk_chars=int(config.get("code_chunk_chars", 6000)),
        max_files_per_repo=int(config.get("max_files_per_repo", 2000)),
    )

    requested_per_repo = (
        episodes_per_repo
        if episodes_per_repo is not None
        else int(config.get("episodes_per_repo", 20))
    )
    generation = generate_trajectory_corpus(
        catalog_path,
        paths["episodes"],
        cache_dir=cache_dir,
        work_dir=work_dir,
        episodes_per_repo=requested_per_repo,
        seed=int(config.get("seed", 17)),
        timeout_seconds=int(config.get("timeout_seconds", 120)),
        max_attempts=int(config.get("max_mutation_attempts", 64)),
        generation_retries=int(config.get("generation_retries", 4)),
        failures_path=paths["failures"],
    )
    _write_json(paths["generation_report"], generation)

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
        expected_successes = max(
            1,
            math.ceil(limit_repositories * requested_per_repo * probe_success),
        )
        expected_dynamic_repos = max(
            1,
            math.ceil(limit_repositories * probe_success),
        )
        quality["min_catalog_repositories"] = min(
            int(quality.get("min_catalog_repositories", 1)),
            limit_repositories,
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

    manifest = {
        "version": 1,
        "name": config.get("name", output_dir.name),
        "config": config,
        "catalog": str(catalog_path),
        "code": code,
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
