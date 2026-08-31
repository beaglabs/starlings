# Training curriculum

The curriculum is staged, but runtime behavior must not become a memorized
workflow. Training should vary successful and unsuccessful action order,
available operators, repository shape, verifier output, and local context.

## Stage 0 — language and code

Train ordinary causal language/code competence from repository source and
technical documentation windows. Structured supervision is `NOOP` / `NONE`.

## Stage 1 — native operations

Introduce `OBSERVE`, `QUERY`, `CLAIM`, `EVIDENCE`, `PROPOSE`,
`ACCEPT`, `REJECT`, `CHALLENGE`, `RETRACT`, `DELEGATE`, and
`EXECUTE` at `<ACT>`. Train typed spans at the same time.

## Stage 2 — Operator Retrieval

Vary the visible operator population. OR returns a bounded relevant set and the
argument head points to the selected operator. Include distractors, unavailable
capabilities, renamed operators with equivalent descriptions, and different
operator counts so tool names cannot become a fixed workflow vocabulary.

## Stage 3 — attributable evidence

Train direct-parent pointers, parent count, and confidence. Include irrelevant
or missing evidence and unsupported claims. BLAKE3 IDs are host-assigned and
only pointed to by the model.

## Stage 4 — verifier-grounded repair

Use known-good repositories, controlled mutations, compiler/test failures,
source/AST/docs queries, repair proposals, and post-repair verification.
`oracle-bootstrap-v1` episodes are explicitly labeled supervised bootstrap
data.

## Stage 5 — revision and richer episodes

Oversample genuine failed proposals and evidence that forces `CHALLENGE`,
`RETRACT`, or `REJECT`. Replace increasing amounts of oracle bootstrap data
with policy-generated environment interactions scored by external verifiers.

## Stage 6 — delegation and populations

Supply varying `P = (A, G, X, M, F, Π, C, Φ, J)` contexts. The same physical
model may back multiple logical agents with different bounded observations,
capabilities, neighborhoods, and budgets.

## Stage 7 — causal credit from the DAG

Use successful and failed ancestry to estimate which observations, operator
calls, challenges, proposals, and delegations actually contributed to accepted
solutions.

## Stage 8 — local-k=7 micro-dynamics ablation

Only after the fixed ~500M baseline is strong and reproducible, introduce the
parameter-agent/local-k=7 hypothesis and compare against the exact same
protocol, environments, tools, and benchmarks.
