# Benchmarking

Murmurations benchmarks two things separately:

1. **model competence** — language/code likelihood, operation selection, typed
   argument grounding, parent pointers, and confidence calibration;
2. **protocol integrity** — canonical identity, direct-parent closure,
   Merkle-DAG acyclicity, and replayability.

Keeping them separate prevents a good language model from hiding broken
provenance semantics, or perfect provenance plumbing from being mistaken for
reasoning quality.

## Head benchmark

Consolidate a distributed checkpoint to a single `model.safetensors` (or
`pytorch_model.bin`) and keep its `model_config.json` beside it:

```sh
python -m murmurations.benchmarking.run heads \\
  --checkpoint murmurations/training/runs/murmuration-500m-v0/final \\
  --tokenizer murmurations/models/murmuration-500m-v0/tokenizer \\
  --data data/murmurations/heldout.jsonl \\
  --device auto
```

Reported metrics include:

- language NLL/perplexity;
- operation accuracy;
- argument-kind accuracy;
- argument start/end pointer accuracy;
- parent-pointer and parent-count accuracy;
- confidence MAE.

## Replay benchmark

A replay JSONL contains one canonical action frame per line, optionally with its
claimed `id`:

```json
{"id":"b3:...","frame":{"operation":"CLAIM","argument_kind":"TEXT","argument":"x","parents":[],"confidence_permille":900}}
```

Run:

```sh
python -m murmurations.benchmarking.run replay --trace run/frames.jsonl
```

The command fails on identity mismatch, missing parents, or cycles.

## Next benchmark layers

The next adapters should evaluate full environment episodes rather than only
teacher-forced heads: compiler/test-driven coding repair, distractor-heavy tool
selection, challenge/retraction quality, delegation efficiency, active-agent
fraction, and success-vs-test-time-compute. Those should use the same immutable
trace format rather than inventing benchmark-specific orchestration.
