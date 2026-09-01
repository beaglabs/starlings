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
created from the pinned `murmurations-corpus-v1-2cpu` snapshot. Serious corpus
generation never executes repository commands on the host.

Install the pinned Daytona SDK, configure your Daytona credentials, and prepare
the corpus snapshot once. This can be run directly from macOS; no Lima, Docker,
or local language toolchains are required:

```sh
python3 -m pip install -r murmurations/requirements.txt
export DAYTONA_API_KEY=...
export DAYTONA_API_URL=https://app.daytona.io/api
python3 -m murmurations.training.prepare_daytona \
  --name murmurations-corpus-v1-2cpu \
  --cpu 2 \
  --memory-gib 4 \
  --disk-gib 10
```

Eligibility probing is checkpointed per repository and shard-000 runs up to
eight Daytona probe sandboxes concurrently in the US target region. Probe
planning and repository checkout happen entirely inside Daytona; the host only
reads the catalog and writes checkpoint/report files. Re-running the same probe
resumes compatible snapshot/plan checkpoints instead of repeating completed
repositories. Because eligibility identity includes the snapshot ID, switching
from the 4-vCPU snapshot to the 2-vCPU snapshot intentionally requires a fresh
clean-verifier probe.

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

For the full hybrid shard, first produce a clean probe for the 2-vCPU snapshot:

```sh
python3 -m murmurations.training.probe_repositories \
  --config murmurations/training/corpus/shard-000.yaml \
  --catalog murmurations/training/corpus/shard-000-repos.jsonl \
  --report data/murmurations/shard-000-full-probe.json \
  --eligible-catalog data/murmurations/shard-000-eligible.jsonl
```

Then generate verifier-untrusted semantic candidates on Molab or any machine
running an OpenAI-compatible local code-model endpoint:

```sh
export MURMURATIONS_PROPOSER_BASE_URL=http://127.0.0.1:8000/v1
export MURMURATIONS_PROPOSER_MODEL=<local-code-model>

python3 -m murmurations.training.propose_mutations \
  --catalog data/murmurations/shard-000-eligible.jsonl \
  --output data/murmurations/shard-000-semantic-candidates.jsonl
```

The proposer is not trusted to produce labels, test results, repairs, or shell
commands. It emits exact one-line source edits only. The candidate file is
validated against pinned source lines and its SHA-256 digest becomes part of
the resumable generation identity.

Keep the configured standalone full-probe cache
(`data/murmurations/shard-000-full-probe.json` and
`data/murmurations/shard-000-eligible.jsonl`). The builder validates its exact
catalog, Daytona snapshot/planner signature, and semantic candidate digest
before reusing compatible state:

```sh
rm -rf data/murmurations/shard-000

python3 -m murmurations.training.build_shard \
  --config murmurations/training/corpus/shard-000.yaml
```

The full recipe is target-driven rather than fixed-count. Missing required
languages are scheduled first, then eligible repositories continue in balanced
round-robin bursts until the configured mutation, trajectory-row, dynamic
repository, terminal-evidence, language-coverage, and generation-yield targets
are satisfied, or bounded per-repository request/success caps are exhausted.
Shard-000 requires dynamic episodes from C, C++, Go, Java, JavaScript, Python,
Rust, TypeScript, and Zig. Episode and failure JSONL are append-only resumable
journals, and their generation signature includes the Daytona snapshot identity
plus repository-planner digest so verifier changes cannot silently reuse stale
episodes. Generated files include SHA-256 digests in the QA report.

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
