# Murmurations benchmarking

Evaluation keeps four layers separate:

1. **model competence** — language likelihood, operation selection, argument
   grounding, operator pointers, parent pointers, confidence;
2. **Operator Retrieval** — whether the needed operator was exposed in the
   bounded retrieved set and at what rank;
3. **protocol integrity** — canonical identity, parent closure, DAG acyclicity,
   and replay;
4. **environment outcome** — compiler/test/hidden-verifier success.

## Head benchmark

```sh
python -m murmurations.benchmarking.run heads \
  --checkpoint murmurations/training/runs/murmuration-500m-v0/final \
  --tokenizer murmurations/models/murmuration-500m-v0/tokenizer \
  --data data/murmurations/trajectory-eval.jsonl
```

Metrics include operation accuracy, argument kind/start/end, true joint argument
span exact match, operator-pointer accuracy, parent-pointer/count accuracy,
confidence MAE, and language NLL/perplexity.

## OR benchmark

Generated episodes retain the actual bounded candidate set visible at every
operator-bearing action:

```sh
python -m murmurations.benchmarking.run or \
  --episodes data/murmurations/episodes.jsonl
```

This reports retrieval recall@k and MRR over actions with an operator reference.

## Replay benchmark

The replay evaluator accepts either flat action-frame JSONL or generated episode
JSONL and verifies the canonical action DAG:

```sh
python -m murmurations.benchmarking.run replay \
  --trace data/murmurations/episodes.jsonl
```

It fails on identity mismatch, missing parents, or cycles.

## Coding outcome benchmark

Executable candidate scoring remains independent of how a patch was produced:

```yaml
tasks:
  - id: zig-regression
    cwd: .
    timeout_seconds: 120
    commands:
      - [zig, test, src/root.zig]
      - [zig, build, test]
```

```sh
python -m murmurations.benchmarking.run coding \
  --spec benchmarks/zig.yaml \
  --candidate-root /tmp/candidate
```

For scientific comparisons, use the same held-out repositories and verifiers
for a conventional 500M baseline, protocol-native model, +OR, +operator
execution, later populations, and only then local-k=7 dynamics. Report success
alongside test-time compute and operator counts.
