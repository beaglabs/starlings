# Stage 3B — Deterministic protocol workflows

Stage 3B expands the Stage 3A trace corpus with deterministic workflows that require the typed protocol vocabulary to perform real coordination steps.

## Purpose

Stage 3A established a trustworthy trace/corpus baseline, but the original benchmark emits only `CLAIM`. That corpus is useful for measuring repetition and encoding cost, but it is too narrow to justify a context-free grammar.

Stage 3B adds protocol diversity without manufacturing arbitrary message labels. Each message kind is exercised because a deterministic workflow requires it.

## Workflows

### Observation synthesis

`OBSERVE -> CLAIM`

An analyst receives an observation and emits the corresponding claim.

### Information request

`QUERY -> EVIDENCE`

A requester asks for a fact mask and a knowledge holder returns the matching evidence.

### Proposal acceptance

`PROPOSE -> ACCEPT`

An evaluator accepts a proposal whose payload is contained by its allowed state.

### Proposal rejection

`PROPOSE -> REJECT`

An evaluator rejects a proposal containing material outside its allowed state.

### Challenge and retraction

`CHALLENGE -> RETRACT`

A claimant retracts the challenged portion of its current claim state.

### Delegation

`DELEGATE -> QUERY -> EVIDENCE -> EVIDENCE`

A coordinator delegates an information request, the delegate queries a specialist, the specialist returns evidence, and the delegate forwards it to the coordinator.

## Corpus changes

The expanded corpus combines:

- the Stage 3A benchmark traces;
- all six Stage 3B workflows;
- deterministic seed variation;
- explicit `run_id` boundaries;
- optional benchmark strategy/task metadata;
- optional workflow metadata.

Transition analysis counts only transitions that occur within the same run. Cross-run adjacency is not considered a protocol transition.

## Current expected evidence

The Stage 3B corpus should demonstrate:

- all typed message kinds are exercised;
- workflow traces are deterministic;
- all workflow runs solve their intended task;
- multiple recurring kind transitions exist;
- causal provenance references are present in workflow messages;
- the compact canonical representation remains a valid non-CFG size baseline.

## What Stage 3B does not prove

Stage 3B does not validate a CFG.

It establishes enough protocol diversity to make a grammar experiment meaningful. A Stage 3C grammar candidate should still have to beat the typed/canonical baseline on one or more measurable dimensions:

- invalid-composition rejection;
- compactness;
- deterministic parsing;
- composability;
- constrained-generation reliability;
- transfer across workflows.

A grammar should not be promoted merely because the protocol now has recurring sequences.
