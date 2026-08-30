# ADR 0004 — Keep model-backed operators outside the deterministic authority boundary

## Status

Accepted — 2026-08-29.

## Context

ADR 0002 established an operator-neutral coordination core.

F4 tested that claim with live language-model-backed operators mixed with
frozen deterministic theta51 operators.

The live model emitted only proposed protocol interactions. The deterministic
runtime retained authority over:

- parsing;
- semantic validation;
- topology;
- state transitions;
- communication accounting;
- convergence;
- replay.

The canonical F4 experiment contained 86 population runs across ring/grid,
multiple environment seeds, multiple model sampling seeds, mixed/model-only
arms, and typed-unconstrained/CFG-constrained decoding.

Frozen evidence:

~~~text
summary SHA-256:
d263db94aee099c9ba47aa8eae60cf0ad49258fa6f299a5a9571fe6b545d2164

raw SHA-256:
bf2d791e8f37fc75c8fb423920a5737fa7a70b56599ad49d2274300256389530

GGUF SHA-256:
740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8
~~~

The primary heterogeneous arm achieved:

~~~text
mixed / ring / CFG:
  9/9 success

mixed / grid / CFG:
  9/9 success
~~~

with zero syntactically invalid CFG outputs.

The same model under typed-unconstrained decoding achieved:

~~~text
mixed / ring:
  6/9 success

mixed / grid:
  3/9 success
~~~

and produced substantial invalid and semantically rejected output.

Repeated successful semantic trajectory hashes also demonstrated multiple
solution paths from fixed initial states.

## Decision

Model-backed operators remain **outside** the deterministic authority boundary.

A model may:

- observe its local state;
- select or propose an interaction;
- act as a pluggable local policy.

A model may not directly:

- mutate coordination state;
- bypass protocol parsing;
- bypass semantic validation;
- choose authoritative delivery semantics;
- define accounting;
- declare success.

The required boundary is:

~~~text
model
  -> proposed interaction
  -> deterministic parser/validator
  -> deterministic Starlings transition
~~~

Invalid model output must be rejected and counted rather than repaired into a
valid action.

## Rationale

F4 validates the operator-neutral architecture without making the language
model part of the protocol core.

This preserves:

- replayability;
- auditable state transitions;
- deterministic protocol invariants;
- interchangeable operator implementations;
- failure attribution.

It also allows deterministic and model-backed operators to coexist in one
population without creating two execution semantics.

## CFG finding

F4 found a strong operational benefit from CFG-constrained decoding for the
tested Gemma model and action language:

~~~text
mixed CFG:
  ring 9/9
  grid 9/9

model-only CFG:
  ring 9/9
  grid 9/9
~~~

versus weaker or failed typed-unconstrained arms.

This ADR does **not** make CFG a universal architectural requirement.

Instead:

- grammar-constrained generation is a validated control mechanism for this
  model/protocol pair;
- future model adapters may use CFG or another mechanism;
- every adapter must still pass the same deterministic parse/semantic boundary.

## Consequences

- The Starlings protocol core remains model-provider-neutral.
- Model runtimes belong in adapters/experiment or application layers.
- Raw model completions are untrusted input.
- Model nondeterminism is measured outside the deterministic state-transition
  authority.
- Sampling seeds and environment seeds should remain separate experimental
  factors.
- Model artifacts used for evidence should be pinned by content hash.
- Trajectory diversity should be measured semantically, not by irrelevant raw
  wording differences.
- Mixed populations should include tests that require real contribution from
  model-backed operators rather than allowing deterministic peers to carry the
  entire outcome.

## Evidence

Detailed F4 evidence:

~~~text
docs/f4-heterogeneous-model-operators.md
~~~

Canonical verdict:

~~~text
F4 PASS: heterogeneous model-backed operator evidence complete
~~~
