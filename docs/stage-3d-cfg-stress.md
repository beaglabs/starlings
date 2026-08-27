# Stage 3D — CFG stress and generalization validation

Stage 3D tests whether the Stage 3C context-free grammar generalizes beyond the six deterministic workflow examples from which it was derived.

## Goals

The stress suite asks four separate questions:

1. Does the grammar accept unseen valid compositions?
2. Does parsing preserve the exact terminal sequence?
3. Does the grammar reject independently guaranteed-invalid mutations?
4. Do the Stage 3C encoding savings survive a much broader composition distribution?

## Exhaustive composition test

Every ordered three-interaction combination of the seven current grammar productions is generated and round-tripped:

```text
7 × 7 × 7 = 343 combinations
```

Claim batches use varying spans so recursive productions are exercised alongside the fixed workflow productions.

Each generated session must:

- parse successfully;
- reconstruct to the exact original terminal sequence;
- stay within the same bounded, allocation-free runtime assumptions as the rest of Starlings.

## Seeded generalization stress

The seeded generator creates sessions containing at least two interactions and up to the Stage 3C 64-terminal bound.

Production choices and claim-batch spans vary from seed to seed. The final interaction is deliberately non-ClaimBatch so certain malformed mutations can be guaranteed invalid without using the parser itself as the oracle.

The default tests currently exercise:

- 512 generated sessions for validity and mutation rejection;
- 1,024 generated sessions for encoding-distribution analysis.

All generation is deterministic and reproducible from the seed.

## Mutation validation

Stage 3D does **not** assume every arbitrary edit is invalid. Some edits can transform one valid production into another, such as:

```text
PROPOSE ACCEPT → PROPOSE REJECT
```

Those are not counted as rejection tests.

Instead, each generated session receives four mutations whose invalidity is independently guaranteed by the grammar construction:

1. append an orphan `ACCEPT`;
2. prepend an orphan `REJECT`;
3. remove the required final terminal from a non-ClaimBatch interaction;
4. swap the first two terminals of the final non-ClaimBatch interaction.

The parser should reject every such mutation.

## Round-trip validation

A separate reconstruction function expands parsed productions back into terminals.

For every accepted generated session:

```text
generated terminals
      ↓
CFG parse
      ↓
production sequence + spans
      ↓
reconstruction
      ↓
exact original terminals
```

This catches parsers that accept the right language but lose information needed to reproduce the original protocol sequence.

## Encoding distribution

The fair Stage 3C comparison is preserved.

Only the bytes that differ between:

- explicit terminal-kind encoding; and
- CFG production structure

are compared.

The stress statistics track:

- total typed kind bytes;
- total CFG structure bytes;
- aggregate savings;
- savings in permille;
- positive-savings sessions;
- equal-savings sessions;
- negative-savings sessions;
- minimum per-session savings;
- maximum per-session savings.

This prevents a favorable aggregate result from hiding a large population of regressions.

## Promotion posture

Stage 3D is a stronger validation gate, but it still does not by itself make CFGs a required Starlings architectural component.

A strong Stage 3D result would establish that the current grammar:

- generalizes compositionally within the deterministic protocol domain;
- rejects structurally malformed traffic;
- round-trips without information loss;
- retains measurable representation savings outside the original six workflows.

The remaining major gap before architectural promotion is model-backed constrained generation: whether real heterogeneous AI operators produce more valid, efficient, or reliable communication when generation is grammar-constrained.
