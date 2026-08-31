# Murmurations training

The training path is:

```text
1. language / operation / argument heads
2. EXECUTE + operator-reference supervision
3. Python Operator Retrieval (OR)
4. dynamic permissive repository sampling
5. repo / AST / docs / compiler / test operators
6. verifier-grounded trajectory generation
7. train/eval materialization
8. train the 500M model
9. benchmark
```

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

The committed shard-000 recipe uses 60 public repositories pinned to exact
commits across Python, Rust, Go, JavaScript/TypeScript, C/C++, Zig, and Java.
Static code/document windows use the full catalog. Dynamic repair episodes use
only repositories whose clean verifier passes in an ephemeral Daytona sandbox
created from the pinned `murmurations-corpus-v1` snapshot. Serious corpus
generation never executes repository commands on the host.

Install the pinned Daytona SDK, configure your Daytona credentials, and prepare
the corpus snapshot once. This can be run directly from macOS; no Lima, Docker,
or local language toolchains are required:

```sh
python3 -m pip install -r murmurations/requirements.txt
export DAYTONA_API_KEY=...
export DAYTONA_API_URL=https://app.daytona.io/api
python3 -m murmurations.training.prepare_daytona --replace
```

Eligibility probing is checkpointed per repository and shard-000 runs up to
eight Daytona probe sandboxes concurrently in the US target region. Probe
planning and repository checkout happen entirely inside Daytona; the host only
reads the catalog and writes checkpoint/report files. Re-running the same probe
resumes compatible snapshot/plan checkpoints instead of repeating completed
repositories.

Then run the small stratified probe/build:

```sh
python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml \
  --limit-repositories 7 \
  --episodes-per-repo 2
```

The 7-repo subset is selected across languages rather than taking the first
seven catalog rows. Inspect:

```sh
cat data/murmurations/shard-000/repo-probe.json
cat data/murmurations/shard-000/qa-report.json
```

If the probe passes, remove the probe output and build the full shard:

```sh
rm -rf data/murmurations/shard-000

python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml
```

The full recipe requests 20 unique verifier-caught mutations per eligible repo,
with hard QA gates for pinned permissive provenance, clean-verifier eligibility,
generation yield, unique mutations, static/trajectory row counts, repository
train/eval isolation, duplicate mutation rejection, and exact static-window
deduplication. Generated files include SHA-256 digests in the QA report.

### Terminal-backed evidence in shard-000

Dynamic trajectories can retrieve semantic operators backed by argv-only
commands executed inside the episode's Daytona sandbox:

- `type.check` — compiler/type-checker diagnostics;
- `package.metadata` — local manifest/package/dependency metadata;
- `docs.lookup` — local language/package documentation where a safe local CLI
  is available.

The exact argv, exit code, and output are recorded as episode evidence. The
model sees the stable semantic operator descriptor rather than a shell string.
Up to two of these operators are selected in seeded variable order per episode,
so the recipe does not encode a mandatory terminal-tool workflow. Shard QA
requires actual terminal-operator coverage.

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

## Generate dynamic repair trajectories

Dynamic repair trajectories are a serious-corpus operation and are generated
through `build_shard`, which requires the configured Daytona snapshot. The
low-level trajectory generator is not a host-execution path.

For each successful episode the generator:

1. checks out/selects the pinned repository locally for static inspection only;
2. creates one ephemeral Daytona sandbox from the pinned corpus snapshot;
3. clones and checks out the exact repository commit remotely;
4. runs deterministic ecosystem preparation inside that sandbox;
5. runs the clean verifier remotely and requires a pass;
6. tries controlled source mutations locally and synchronizes only changed source files;
7. keeps only a mutation that changes the remote verifier to failure;
8. exposes repo/search/AST/docs/check/test operators through OR;
9. executes terminal-backed operators inside the same Daytona sandbox;
10. applies the known inverse mutation and reruns the remote verifier.

Failed mutation attempts are discarded instead of mislabeled. The sandbox is
deleted when the episode ends, and shard QA fails if terminal argv evidence is
not attributed to Daytona.

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
    data/murmurations/trajectory-train.jsonl \
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
