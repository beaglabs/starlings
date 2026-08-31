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

```sh
python -m murmurations.training.generate_trajectories \
  --catalog data/murmurations/repos.jsonl \
  --output data/murmurations/episodes.jsonl \
  --episodes 1000
```

For each successful episode the generator:

1. checks out/selects a pinned clean repository;
2. runs its supported verifier and requires a pass;
3. copies it into an isolated work directory;
4. tries controlled source mutations;
5. keeps only a mutation that changes the verifier to failure;
6. exposes repo/search/AST/docs/check/test operators through OR;
7. records an attributable bootstrap repair trajectory;
8. applies the known inverse mutation;
9. reruns the verifier and records the result.

Failed mutation attempts are discarded instead of mislabeled.

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

The model is **503,413,791 trainable parameters** with a 32,768-token
vocabulary: width 1,024, 28 blocks, 16 attention heads, 4,096-wide SwiGLU,
RoPE/RMSNorm, tied language projection, operation classification, and structured
argument/operator/parent grounding.

The loss combines language CE, operation CE, argument kind/span CE,
operator-pointer CE, parent-pointer/count CE, and confidence calibration.

The generated corpus is local/ignored by Git. Model weights remain outside
normal Git history.
