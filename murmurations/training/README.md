# Murmurations training

The default first-serious-corpus path is:

```text
1. language / operation / argument heads
2. EXECUTE + operator-reference supervision
3. Python Operator Retrieval (OR)
4. import successful execution-grounded SWE-smith trajectories
5. deterministic command/tool -> semantic-operator compilation
6. optional local/Blackwell semantic-label augmentation
7. trajectory-only QA + train/eval materialization
8. train the 500M model
9. benchmark
```

Native Daytona execution remains available for a small held-out calibration set;
it is not the bulk shard-000 data factory.

## End-to-end smoke test

This creates a tiny local repository, verifies it, injects a caught source
mutation, creates train/eval episodes, materializes rows, and trains a 512-token
smoke tokenizer:

```sh
python -m murmurations.training.make_smoke_fixture
python -m unittest discover -s murmurations -p 'test_*.py'
accelerate launch -m murmurations.training.train \
  --config murmurations/training/configs/smoke.yaml
```

Then evaluate the final smoke checkpoint:

```sh
python -m murmurations.benchmarking.run heads \
  --checkpoint murmurations/training/runs/smoke/final \
  --tokenizer murmurations/models/murmuration-500m-v0/tokenizer \
  --data data/murmurations/smoke-eval.jsonl

python -m murmurations.benchmarking.run or \
  --episodes data/murmurations/smoke-episodes.jsonl

python -m murmurations.benchmarking.run replay \
  --trace data/murmurations/smoke-episodes.jsonl
```

## First serious corpus shard

Shard-000 no longer generates its bulk trajectory supervision by synthesizing
hundreds of new bugs. It imports **resolved SWE-smith agent trajectories** from
the pinned SWE-smith raw trajectory corpus and deterministically compiles
their real tool calls and observations into Murmurations event DAGs.

The source is pinned in `shard-000.yaml`:

- dataset: `neulab/agent-data-collection`
- configuration: `swe-smith`
- split: `raw`
- revision: `17f755bd6c6588d98a91ae6512576d9772919ab2`
- source license: MIT

The importer streams `full_raw.jsonl` rather than downloading the full multi-GB
artifact. The raw split is used deliberately because it preserves SWE-smith's
`resolved`, `instance_id`, and `traj_id` metadata across ADP schema revisions.
It accepts only records whose source metadata says `resolved=true`,
excludes any repository already used by the static 60-repository code catalog,
and stops only after all configured trajectory-volume and repository-diversity
targets are met.

Install only the import-path dependencies and smoke-test the pipeline:

```sh
python3 -m pip install -r murmurations/requirements-import.txt

rm -rf data/murmurations/shard-000

python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml \
  --smoke
```

Then build the serious trajectory shard:

```sh
rm -rf data/murmurations/shard-000

python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml
```

Import mode does not clone or materialize the static repository catalog, does
not construct a Daytona client, and has no code-row QA gate. The catalog named
by `exclude_catalog` is read only to keep imported trajectory repositories
disjoint from separately-managed code pretraining data.

No Daytona credentials, snapshot, Docker/Lima environment, or LLM endpoint is
required for the default build.

The importer handles SWE-smith's native tool-call, XML-function-call, and
triple-backtick action renderings, deduplicates repeated renderings by `traj_id`,
and preserves source execution evidence without pretending it was executed by
Murmurations. For every imported tool call it records the original
tool name, exact tool arguments, terminal command when present, and linked
observation. It then maps the action to a stable semantic operator such as
`repo.search`, `repo.tests`, `type.check`, `package.metadata`,
`docs.lookup`. File edits and otherwise-unclassified terminal calls remain grounded
`EXECUTE` events with their exact source tool call, but intentionally carry no
operator-pointer label because those capabilities are not in the runtime
retrieval registry.

A typical source interaction:

```text
terminal {"command":"cd /testbed && pytest -q"}
→ "42 passed"
```

becomes:

```text
QUERY repo.tests
→ EXECUTE repo.tests
   TOOL=terminal
   COMMAND=cd /testbed && pytest -q
→ EVIDENCE "42 passed"
```

Agent messages are retained as CLAIM/PROPOSE supervision, successful source
termination becomes ACCEPT, and all event parent references are verified by the
same Merkle-DAG machinery as native Murmurations episodes.

Shard-000 currently requires at least 500 resolved trajectories, 10,000
materialized trajectory rows, 20 imported repositories, 1,000 grounded external
EXECUTE events, and observed `repo.search` + `repo.tests` operator coverage.
These are trajectory-only gates. Static code/language rows are managed and
validated separately.

### Optional Blackwell semantic annotation

Deterministic conversion is sufficient to build shard-000. A local
OpenAI-compatible model can optionally refine non-authoritative semantic fields
without touching commands, outputs, success labels, ActionFrames, or event IDs.

Enable `generation.semantic_annotation.enabled` in `shard-000.yaml`, then set:

```sh
export MURMURATIONS_ANNOTATOR_BASE_URL=http://127.0.0.1:8000/v1
export MURMURATIONS_ANNOTATOR_MODEL=<local-model-name>
```

The annotator may refine `retrieval_query` and attach labels such as
localization, hypothesis, repair, verification, and prior supporting evidence.
A query rewrite is rejected if it would remove the already-grounded operator
from Operator Retrieval's candidate set.

### Native execution calibration

Daytona remains useful, but it is no longer the bulk corpus generator. The
native verifier-grounded generator is retained for small calibration/evaluation
sets where we specifically want traces produced by Murmurations' own execution
adapter. Those traces should be treated as held-out validation or later corpus
augmentation rather than a prerequisite for training the first serious model.

## Repository catalog

Large-scale generation uses a JSONL catalog of **pinned, permissively licensed**
repositories. A row is:

```json
{"name":"example","url":"https://github.com/example/project.git","commit":"0123456789abcdef","license":"MIT","language":"python"}
```

For already-cloned sources, use an absolute `path` instead of `url`.
The initial allowlist is MIT, Apache-2.0, BSD-2/3-Clause, ISC, 0BSD, CC0-1.0,
and Unlicense.

A pinned commit is required so train/eval provenance is reproducible.

## Build ordinary code/document windows

These rows train the language head while the structured operation is `NOOP`:

```sh
python -m murmurations.training.materialize_code \
  --catalog data/murmurations/repos.jsonl \
  --train-output data/murmurations/pretrain-train.jsonl \
  --eval-output data/murmurations/pretrain-eval.jsonl
```

The split is repository-level, not row-level.

## Native Daytona calibration / augmentation

The original dynamic repair generator is retained for small native calibration
or later augmentation sets. It requires the configured Daytona snapshot. It is
not used by shard-000 import mode and is not required before the first 500M
training run.

For each persistent partition worker the generator:

1. shares one read-only pinned host checkout across partitions of a repository;
2. creates one ephemeral Daytona sandbox and prepares dependencies/build state once;
3. establishes one clean canonical verifier pass for that worker;
4. mixes deterministic and LLM semantic source candidates;
5. assigns candidates to disjoint fingerprint partitions so same-repo workers cannot duplicate work;
6. optionally runs a deterministic narrow pytest/Go triage command to reject obvious misses cheaply;
7. admits a mutation only when the full canonical verifier changes from pass to fail;
8. records actual repo/search/docs/compiler/test operator evidence;
9. applies the known inverse source line;
10. requires the full canonical verifier to pass again before the episode may be journaled;
11. repeats up to four requests in the already-prepared sandbox until its burst ends or global shard targets are met.

The LLM never supplies executable commands or trusted evidence. Failed
mutations and failed repairs are discarded instead of mislabeled. Shard-000
uses four fingerprint partitions per eligible repository, exposes up to 128
independent worker lanes, and lets Daytona quota plus live host-disk capacity
choose the actual concurrency. QA additionally requires at least 100
verifier-accepted LLM-origin mutations.

## Materialize trajectories

```sh
python -m murmurations.training.materialize \
  --episodes data/murmurations/episodes.jsonl \
  --train-output data/murmurations/trajectory-train.jsonl \
  --eval-output data/murmurations/trajectory-eval.jsonl
```

Materialization keeps every direct parent in context and fills remaining context
budget with recent state. Operator references and BLAKE3 parent IDs are pointer
targets and therefore must occur verbatim in the input window.

## Train the tokenizer

Train one tokenizer over both streams:

```sh
python -m murmurations.training.tokenizer \
  --input \
    data/murmurations/pretrain-train.jsonl \
    data/murmurations/shard-000/trajectory-train.jsonl \
  --output murmurations/models/murmuration-500m-v0/tokenizer \
  --vocab-size 32768
```

## Train the 500M baseline

The main config consumes both JSONL streams:

```sh
accelerate config
accelerate launch -m murmurations.training.train \
  --config murmurations/training/configs/murmuration-500m-v0.yaml
```

The model is **504,455,199 trainable parameters** with a 32,768-token
vocabulary: width 1,024, 28 blocks, 16 attention heads, 4,096-wide SwiGLU,
RoPE/RMSNorm, tied language projection, operation classification, and structured
argument/operator/parent grounding through a 128-dimensional learned bilinear pointer space.

The loss combines language CE, operation CE, argument kind/span CE,
operator-pointer CE, parent-pointer/count CE, and confidence calibration.

The generated corpus is local/ignored by Git. Model weights remain outside
normal Git history.
