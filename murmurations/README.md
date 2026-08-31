# Murmurations

Murmurations is the experimental model-training and evaluation package for a
compact Starlings-native policy.

The central hypothesis is that a ~500M parameter model can spend its capacity on
**reasoning inside a structured computational environment**, rather than learning
agent conventions as prose after pretraining.

The model has one shared causal transformer backbone and three output surfaces:

```text
                         shared transformer
                    /          |           \\
                   /           |            \\
          language head   operation head   argument head
          code / prose     OBSERVE ...      kind / span /
                                          parents / confidence
```

The operation vocabulary is native:

`OBSERVE`, `QUERY`, `CLAIM`, `EVIDENCE`, `PROPOSE`, `ACCEPT`,
`REJECT`, `CHALLENGE`, `RETRACT`, and `DELEGATE`.

Protocol contributions are not assigned identities by the model. The argument
head points at typed context and parent references. The host canonicalizes the
action frame, computes a domain-separated BLAKE3 identity, enforces parent
closure, and inserts the contribution into a Merkle-DAG. This makes provenance
attributable and replayable from the first training stage.

A population description can supply the nine formal context slots
`P = (A, G, X, M, F, Π, C, Φ, J)`. Murmurations treats these slots as a typed,
canonical context container; their deeper formal semantics remain owned by
Starlings rather than hard-coded into the neural model.

## Layout

- `training/` — tokenizer, ~500M model, datasets, loss, and Accelerate recipe.
- `models/` — versioned model manifests/configuration. Large weights stay out of
  normal Git history.
- `utils/` — protocol frames, canonical encoding, BLAKE3 IDs, Merkle-DAGs, and
  population-context loading.
- `benchmarking/` — protocol/head evaluation, provenance/replay checks, and a
  generic benchmark runner.

## Scope of v0

v0 trains the **macro policy** first: protocol actions, evidence discipline,
argument grounding, ancestry, and language/code generation. The proposed
parameter-agent `k=7` micro-dynamics are intentionally an ablation after a strong
fixed-transformer baseline exists. A tiny universal local law cannot be evaluated
meaningfully until the protocol-native baseline is measurable.
