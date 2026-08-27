# Stage 3C — First protocol CFG candidate

Stage 3C introduces the first context-free grammar candidate for Starlings protocol composition and benchmarks it against the typed representation established in Stage 3A.

## Candidate grammar

```text
Session      ::= Interaction | Interaction Session
Interaction  ::= ClaimBatch
               | OBSERVE CLAIM
               | QUERY EVIDENCE
               | PROPOSE Decision
               | CHALLENGE RETRACT
               | DELEGATE QUERY EVIDENCE EVIDENCE
ClaimBatch   ::= CLAIM | CLAIM ClaimBatch
Decision     ::= ACCEPT | REJECT
```

The grammar is intentionally minimal. It captures only structures already observed in the trusted deterministic corpus.

## Validation questions

Stage 3C asks whether the grammar provides measurable value over a typed protocol representation:

1. Does it accept all valid Stage 3A/3B runs?
2. Does it reject malformed message compositions?
3. Can production tags replace repeated terminal-kind bytes?
4. Does the CFG reduce encoded size after controlling for ordinary run framing?
5. Does it support composition of multiple interactions into one session?

## Encoding baselines

Three byte counts are tracked.

### Canonical per-message baseline

The Stage 3A representation repeats a version and kind byte per message.

### Framed typed baseline

A fairer non-CFG comparison moves the version to a run header while retaining every message kind explicitly:

```text
version:u8
message_count:u8
message metadata + kind
...
```

Savings from this framing step are **not** credited to the grammar.

### CFG run encoding

```text
version:u8
production_count:u8
production tags
claim-batch spans when needed
message metadata without per-message version or kind
```

Terminal kinds are reconstructed from grammar productions.

The relevant CFG result is the delta between `framed_typed_bytes` and `cfg_bytes`, not the larger delta against the older per-message canonical baseline.

## Current promotion standard

Passing Stage 3C tests does not automatically make CFG support required architecture.

Promotion should require a meaningful combination of:

- valid-corpus coverage;
- malformed-composition rejection;
- deterministic parsing;
- measurable savings over the framed typed baseline;
- useful composability;
- later, improved constrained generation with model-backed operators.

This first experiment can justify continued CFG work without yet justifying permanent architectural promotion.
