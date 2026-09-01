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

The full build is target-driven. Each eligible repository is bounded to 80
requests and 50 accepted mutations, while generation stops as soon as all shard
targets are satisfied. Each episode can retrieve up to two terminal-backed
evidence operators from `type.check`, `package.metadata`, and `docs.lookup`;
the subset and order are seeded per episode rather than fixed. Repositories that
cannot run a supported clean verifier are excluded from dynamic generation and
recorded in the probe report. The shard is accepted only if the QA gates in
`shard-000.yaml` pass, including all-language dynamic coverage, terminal
evidence, at least 500 unique mutations, at least 10,000 trajectory rows, and at
least 100 verifier-accepted LLM semantic mutations.

Run a small remote dynamic probe from the local corpus builder first:

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


## Daytona execution boundary

Static source/document materialization remains local and read-only. Every
repository command used for eligibility, mutation verification, terminal-backed
evidence, or repaired verification runs remotely in Daytona.

Prepare the pinned snapshot once:

```sh
python3 -m pip install -r murmurations/requirements.txt
export DAYTONA_API_KEY=...
export DAYTONA_API_URL=https://app.daytona.io/api
python3 -m murmurations.training.prepare_daytona \
  --name murmurations-corpus-v1-2cpu \
  --cpu 2 --memory-gib 4 --disk-gib 10
```

The snapshot is built remotely from `corpus/daytona/Dockerfile` and includes
the corpus toolchains for Python, Rust, Go, Node, Java, Zig, and C/C++. Zig
repositories resolve `minimum_zig_version` to pinned toolchains in
`/opt/zig/<version>/zig` (including the shard's 0.16.0 and pinned 0.17-dev
requirements). pnpm workspaces execute with the version declared by each
repository, and CMake verifiers rebuild before CTest so source mutations are
actually recompiled. The eligibility probe uses the configured bounded
concurrency (8 for shard-000),
with one independent Daytona client/sandbox lifecycle per worker and durable
checkpointing after each completed repository. Eligibility planning is executed
inside the Daytona sandbox using the same portable repository-plan module as
full generation, so the host does not clone or cache repositories during a
probe. Shard-000 targets Daytona's US region. Eligibility probes remain one sandbox
per repository. Full generation instead uses persistent partition workers: each
worker clones the pinned commit, prepares dependencies once, establishes a clean
verifier once, and evaluates a burst of fingerprint-partitioned mutation
candidates in the same sandbox. Four partitions per eligible repository expose
up to 128 independent lanes; the configured 2-vCPU/4-GiB snapshot lets a Tier-3
250-vCPU pool reach roughly 125 simultaneous workers when host capacity also
permits it.

The model sees the stable semantic operator plus exact logical argv, exit code,
and output. Daytona API details are provenance only and are not a learned tool
interface. Shard QA requires every terminal-bearing episode event to be
attributed to Daytona.

The serious shard additionally hard-gates dynamic language coverage across all
nine catalog language groups. Probe and generation resume identities include
the repository planner digest, so changing toolchain or verifier planning
invalidates stale eligibility/generation state automatically.
