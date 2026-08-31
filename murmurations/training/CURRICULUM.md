# Training curriculum

The curriculum is staged, but the **runtime behavior must not become a memorized
workflow**. Each stage should contain varied successful and unsuccessful action
orders so the policy learns epistemic utility from local state rather than a
fixed sequence.

## Stage 0 — language and code

Train ordinary causal language/code competence. Protocol supervision can be
`NOOP` with `NONE` arguments. The purpose is to establish syntax, code, and
basic reasoning capacity without forcing every token sequence to perform an
action.

## Stage 1 — native operations

Introduce `OBSERVE`, `QUERY`, `CLAIM`, `EVIDENCE`, `PROPOSE`, `ACCEPT`,
`REJECT`, `CHALLENGE`, `RETRACT`, and `DELEGATE` as classification targets at
`<ACT>` positions. Train argument kind/span grounding at the same time.

## Stage 2 — attributable evidence

Every claim/proposal episode carries canonical references. Train direct-parent
pointers, parent count, and confidence. Generate negative examples with missing
parents, irrelevant evidence, unsupported claims, and invalid ancestry.

## Stage 3 — revision

Oversample episodes in which early hypotheses are wrong. Reward productive
`CHALLENGE` and `RETRACT` behavior rather than confidence persistence. Include
multiple valid investigation paths to the same result.

## Stage 4 — delegation and populations

Supply varying `P = (A, G, X, M, F, Π, C, Φ, J)` contexts. Train the same
physical model across multiple logical agents with different local observations,
capabilities, neighborhoods, and budgets. A delegate receives only its bounded
context, not the caller's hidden state.

## Stage 5 — executable coding environments

Move from imitation to compiler/test feedback. Episodes should contain real
queries, patch proposals, failed compiles, hidden-test failures, property-test
evidence, revisions, and accepted solutions. Record every contribution in the
Merkle-DAG.

## Stage 6 — causal credit from the DAG

Use successful and failed episode ancestry to train preference/value objectives:
which observations became ancestors of accepted solutions, which challenges
removed bad branches, which delegations reduced cost, and which actions were
redundant. Preserve rejected/retracted branches instead of deleting them.

## Stage 7 — local-k=7 micro-dynamics ablation

Only after the fixed-transformer ~500M baseline is strong and reproducible,
introduce the parameter-agent hypothesis. Keep pretrained parameters as the
initial condition and train a small shared local law controlling sparse gates,
state, and dynamic `k=7` neighborhoods. Compare against the exact same model,
data, protocol, and external benchmarks.

The first required result is not "beat a frontier model." It is a clean scaling
curve showing whether protocol-native training and then local dynamics provide
capability beyond an equal-parameter conventional baseline.
