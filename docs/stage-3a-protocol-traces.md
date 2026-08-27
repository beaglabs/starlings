# Stage 3A — Protocol Trace Corpus and Grammar-Validation Baseline

## Purpose

Stage 3A creates an empirical protocol corpus before Starlings attempts to design or validate a context-free grammar.

The question is not whether a grammar can be invented. The question is whether trusted Starlings workloads exhibit enough recurring protocol structure for a formal grammar to solve a measured problem.

## Corpus source

The corpus is generated from the existing deterministic coordination benchmark across:

- broadcast-all coordination
- centralized coordination
- point-to-point coordination
- partitioned information tasks
- overlapping/redundant information tasks
- multiple deterministic seeds

Each benchmark result snapshots the actual ordered runtime trace rather than reconstructing communication after execution.

Each corpus record contains:

- coordination strategy
- task shape
- seed
- logical sequence
- sender
- recipient
- message kind
- payload
- optional BLAKE3 causal reference
- logical clock

## Analysis baseline

Stage 3A measures:

- total runs and successful runs
- total trace events
- frequency of every protocol message kind
- number of protocol kinds actually observed
- recurring structural message shapes
- kind-to-kind transition diversity
- causal-reference usage
- current in-memory ABI representation cost
- a compact canonical serialization baseline

A structural message shape currently means:

`message kind × causal-reference presence`

Endpoint identities are intentionally excluded from the shape because sender/recipient IDs are routing data, not grammatical syntax.

## Compact serialization baseline

Before comparing against a future grammar, Starlings needs a deterministic non-grammar baseline.

The initial compact representation is:

```text
version:u8
sender:u32-le
recipient:u32-le
kind:u8
payload:u64-le
causal-present:u8
causal-id?:[32]u8
logical-clock:u64-le
```

This baseline is not proposed as the final protocol encoding. It exists so a future grammar must beat something more meaningful than Zig struct padding.

## Current expected finding

The trusted Stage 1 benchmark currently emits only `CLAIM` messages.

That is useful evidence.

It means the benchmark corpus is expected to show high repetition but low protocol-kind diversity. High repetition alone does **not** validate a CFG.

If the corpus contains only one grammatical operation, Starlings should expand its trusted workloads to exercise genuine multi-step protocol interactions before attempting CFG promotion.

Examples of future observed sequences might include:

```text
QUERY → CLAIM → EVIDENCE → ACCEPT
CLAIM → CHALLENGE → EVIDENCE → ACCEPT
PROPOSE → REJECT → PROPOSE → ACCEPT
DELEGATE → EVIDENCE → ACCEPT
```

These should emerge from deterministic tasks with defined semantics rather than being inserted solely to make the corpus look diverse.

## CFG admission criteria

A CFG experiment should begin only when the trace corpus demonstrates recurring multi-kind protocol structures and at least one measurable limitation that grammar constraints may address, such as:

- invalid protocol compositions
- ambiguous message sequences
- excessive representation size
- repeated multi-message structures that can be represented compositionally
- constrained-generation requirements for future model-backed operators

## CFG promotion criteria

A future grammar should be promoted only if it measurably improves one or more of:

- representation efficiency
- protocol validity
- deterministic parsing
- composability
- constrained generation correctness
- cross-operator consistency

without unacceptable loss of expressive power or task performance.

Stage 3A therefore produces evidence for the grammar decision; it does not assume that CFG is already validated.
