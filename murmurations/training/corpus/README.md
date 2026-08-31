# Murmurations corpus shards

This directory contains committed **recipes and pinned repository catalogs**.
Generated corpora remain under `data/murmurations/` and are intentionally not
committed.

## shard-000

The first serious shard uses 60 public repositories pinned to exact commits on
2026-08-31. Every catalog entry has a GitHub-reported SPDX identifier in the
Murmurations permissive allowlist.

Language composition:

- Python: 14
- Rust: 10
- Go: 10
- JavaScript/TypeScript: 9
- C/C++: 6
- Zig: 5
- Java: 6

The build recipe requests 20 unique verifier-caught mutations per repository
(1,200 episodes maximum). Repositories that cannot run a supported verifier in
the local environment are recorded in `episode-failures.jsonl`; the shard is
accepted only if the QA gates in `shard-000.yaml` pass.

Run a small local probe first:

```sh
python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml \
  --limit-repositories 5 \
  --episodes-per-repo 2
```

Then build the full shard:

```sh
python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml
```

Outputs include static code train/eval JSONL, episode JSONL, materialized
trajectory train/eval JSONL, generation failures, SHA-256 file digests, and a
hard-gated QA report.
