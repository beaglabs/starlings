# Benchmarking

Murmurations keeps three evaluation layers separate:

1. **model competence** — language/code likelihood, operation selection, typed
   argument grounding, parent pointers, and confidence calibration;
2. **protocol integrity** — canonical identity, direct-parent closure,
   Merkle-DAG acyclicity, and replayability;
3. **environment outcome** — whether an emitted candidate actually compiles,
   passes tests, survives hidden/property tests, or meets another executable
   success condition.

Keeping these separate prevents fluent language from hiding broken provenance,
or perfect provenance plumbing from being mistaken for task competence.

## Head benchmark

```sh
python -m murmurations.benchmarking.run heads \\
  --checkpoint murmurations/training/runs/murmuration-500m-v0/final \\
  --tokenizer murmurations/models/murmuration-500m-v0/tokenizer \\
  --data data/murmurations/heldout.jsonl \\
  --device auto
```

Metrics include language NLL/perplexity, operation accuracy, argument-kind and
span accuracy, parent pointers/count, and confidence MAE.

## Replay benchmark

```sh
python -m murmurations.benchmarking.run replay --trace run/frames.jsonl
```

A replay trace is append-only and parent-closed. The command fails on identity
mismatch, missing parents, or cycles.

## Coding-repair outcome benchmark

The scoring backend accepts a YAML file of explicit argv commands. It does not
invoke a shell and it does not prescribe how the candidate was produced.

```yaml
tasks:
  - id: zig-regression
    cwd: .
    timeout_seconds: 120
    commands:
      - [zig, test, src/root.zig]
      - [zig, build, test]
```

Score a candidate workspace:

```sh
python -m murmurations.benchmarking.run coding \\
  --spec benchmarks/zig.yaml \\
  --candidate-root /tmp/candidate
```

This is intentionally compatible with normal transformer inference, the
protocol-native baseline, later multi-agent populations, and later local-k=7
micro-dynamics. All can be judged by the same external verifier.

## System-level metrics to add to traces

Full Starlings episodes should also record success versus test-time compute:
operation count, compiler/test calls, challenges resolved, retractions,
delegations, unique evidence, active logical agents, active micro-agent
fraction, recurrent ticks, wall time, and final outcome. These are properties
of the emergent system, not of a particular benchmark workflow.
