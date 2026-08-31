"""Generate verifier-grounded Murmurations repair episodes from dynamic repositories."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from murmurations.training.environments.episodes import make_oracle_bootstrap_episode
from murmurations.training.environments.mutations import inject_verified_mutation
from murmurations.training.environments.repositories import RepoCatalog, checkout_repository
from murmurations.training.operators import default_operator_registry, detect_test_command


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True, help="JSONL repository catalog")
    parser.add_argument("--output", required=True, help="Episode JSONL output")
    parser.add_argument("--cache-dir", default=".cache/murmurations/repos")
    parser.add_argument("--work-dir", default=".cache/murmurations/work")
    parser.add_argument("--episodes", type=int, default=10)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--timeout-seconds", type=int, default=120)
    parser.add_argument("--max-attempts", type=int, default=64)
    args = parser.parse_args()

    catalog = RepoCatalog.from_jsonl(args.catalog)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    work_root = Path(args.work_dir)
    work_root.mkdir(parents=True, exist_ok=True)

    written = 0
    failures: list[dict[str, str]] = []
    with output.open("w", encoding="utf-8") as handle:
        for index in range(args.episodes):
            repo = catalog.sample(args.seed + index)
            try:
                source = checkout_repository(repo, args.cache_dir)
                verifier = detect_test_command(source)
                if verifier is None:
                    raise RuntimeError("no supported repository test command detected")
                workspace = work_root / f"episode-{index:06d}"
                mutation = inject_verified_mutation(
                    source,
                    workspace,
                    verifier,
                    seed=args.seed + index,
                    timeout_seconds=args.timeout_seconds,
                    max_attempts=args.max_attempts,
                )
                registry = default_operator_registry(workspace)
                episode = make_oracle_bootstrap_episode(
                    repo,
                    workspace,
                    mutation,
                    registry,
                    timeout_seconds=args.timeout_seconds,
                )
                handle.write(json.dumps(episode.record(), sort_keys=True) + "\n")
                written += 1
            except Exception as exc:
                failures.append({"repository": repo.name, "error": str(exc)})

    print(
        json.dumps(
            {
                "requested": args.episodes,
                "written": written,
                "failed": len(failures),
                "failures": failures[:20],
                "output": str(output),
            },
            indent=2,
            sort_keys=True,
        )
    )
    if written == 0:
        raise SystemExit("no valid episodes were generated")


if __name__ == "__main__":
    main()
