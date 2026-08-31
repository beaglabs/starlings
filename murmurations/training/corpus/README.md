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

The build recipe requests 20 unique verifier-caught mutations per eligible
repository (1,200 episodes maximum before eligibility filtering). Each episode
can retrieve up to two terminal-backed evidence operators from
`type.check`, `package.metadata`, and `docs.lookup`; the subset and order
are seeded per episode rather than fixed. Repositories that cannot run a
supported clean verifier are excluded from dynamic generation and recorded in
the probe report. The shard is accepted only if the QA gates in
`shard-000.yaml` pass, including terminal-evidence coverage.

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


## Terminal evidence

Shard-000 deliberately trains terminal-backed evidence retrieval at two levels:

1. **Semantic capability selection** through Operator Retrieval:
   `type.check`, `package.metadata`, and `docs.lookup`.
2. **Concrete implementation evidence** through the exact argv executed by the
   adapter, rendered into later model state as `ARGV[event-id]: [...]`.

Examples include `cargo check --quiet`, `go list -m -json`, `go doc`,
Python `pydoc`, local TypeScript `tsc --noEmit`, and repository-native
Gradle/Maven/Zig compiler checks when available.

The model is therefore not required to memorize one command as the definition
of a capability. It learns the stable semantic operator and also observes which
local terminal command implemented that operator for the current repository.

The recipe requests at most two terminal enrichment calls per repair episode
and the QA report requires both terminal-operator diversity and concrete argv
evidence before the full shard passes.
