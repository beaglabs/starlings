# Murmurations corpus shards

This directory contains committed recipes and pinned repository catalogs.
Generated corpora remain under `data/murmurations/` and are not committed.

## shard-000

Shard-000 combines two sources:

1. **Static multilingual code/document windows** from 60 permissively licensed
   repositories pinned to exact commits.
2. **Execution-grounded repair trajectories** imported from the standardized
   SWE-smith ATIF corpus.

The static catalog covers Python, Rust, Go, JavaScript/TypeScript, C/C++, Zig,
and Java. The imported SWE-smith trajectories are Python-focused and come from
real agent interactions on synthesized test-breaking software tasks.

The trajectory source is pinned to:

```text
neulab/agent-data-collection
config=swe-smith
split=std
revision=17f755bd6c6588d98a91ae6512576d9772919ab2
```

SWE-smith is MIT licensed. Import is streaming and resolved-only.

## Build

```sh
python3 -m pip install -r murmurations/requirements.txt
rm -rf data/murmurations/shard-000
python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml
```

The serious shard does **not** require Daytona.

For a small local smoke build:

```sh
python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml \
  --limit-repositories 5
```

## Conversion contract

The importer reads ATIF steps with linked tool calls and observations. For
source trajectories marked `resolved=true`, it deterministically maps actions
into the Murmurations protocol:

- user task/information → `OBSERVE`
- agent reasoning → `CLAIM`
- reasoning immediately preceding an edit → `PROPOSE`
- tool selection → `QUERY`
- actual source tool call → `EXECUTE`
- linked tool result → `EVIDENCE`
- successful source finish → `ACCEPT`

Semantic operator mapping includes:

- repository/file inspection and grep → `repo.search`
- test commands → `repo.tests`
- compiler/type/lint commands → `type.check`
- package/dependency inspection → `package.metadata`
- local documentation commands → `docs.lookup`

File edits and otherwise-unclassified repository commands are preserved as
direct `EXECUTE` events with exact tool-call provenance, but do not receive
an operator pointer because those capabilities are not exposed by the runtime
Operator Retrieval registry.

Imported EXECUTE events retain the exact source tool name, arguments, terminal
command when present, and observation. They are marked
`external_execution=true`; they are never mislabeled as Daytona executions.

## Hard gates

The full shard currently requires:

- at least 50 static catalog repositories;
- at least 20 imported trajectory repositories;
- Python trajectory coverage;
- at least 500 unique resolved trajectories;
- at least 10,000 static code rows;
- at least 10,000 trajectory rows;
- at least 1,000 grounded external EXECUTE events;
- no duplicate trajectory fingerprints;
- no train/eval repository-identity leakage.

Imported repositories that overlap the static catalog are excluded before
materialization to prevent cross-stream repository leakage.

Daytona-native trajectories are now calibration/evaluation material, not a
bulk-generation dependency for shard-000.
