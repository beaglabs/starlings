# Starlings SDK v0.1

Starlings SDK exposes decentralized coordination as an operator/variable/invariant system rather than an LLM-agent framework.

## Core objects

- `Variable` — typed contextual state with epistemic status.
- `Invariant` — a named relationship or constraint over variables.
- `Claim` — an immutable operator contribution.
- `OperatorManifest` — declares `requires` and `provides` boundaries.
- `OperatorOutput` — canonical envelope for claims, invariants, artifacts, actions, and diagnostics.
- `Result` — terminal/materialized view over the collective state.

Epistemic states are explicit:

```text
unknown
observed
estimated
derived
not_visible
unavailable
blocked
conflicting
```

`blocked` and `unavailable` are resolved epistemic outcomes, not fabricated values.

## Output lifecycle

```text
operator executes
      |
      v
OperatorOutput
      |
      v
manifest + type validation
      |
      v
canonical BLAKE3 claim identity
      |
      v
immutable ClaimStore
      |
      v
merge/conflict policy
      |
      v
materialized collective state
      |
      v
new local eligibility
```

Large payloads are represented by content-addressed `ArtifactRef` values. External effects remain `ActionProposal` values and are not silently executed as variable writes.

## Local eligibility

Operators declare required variables/invariants and optional dependency expressions. Eligibility is computed from current state and freshness rather than from a central workflow sequence.

## Reactive scheduling

The local runner is resumable. Operators activate when their declared requirements are eligible **and** the relevant variable/invariant revision fingerprint differs from their previous activation.

`runUntilQuiescent(budget)` advances the population until one of these conditions occurs:

- all target variables carry values → `success`;
- no activation is pending and a target is explicitly `conflicting` → `conflicting`;
- no activation is pending and a target is `not_visible`, `unavailable`, or `blocked` → `blocked`;
- no activation is pending while targets remain unknown → `quiescent`;
- the activation budget is consumed while work remains → `exhausted`.

Quiescence is deliberately distinct from failure. A quiescent population can become `running` again when an external observation advances a relevant state revision.

`schedulerSnapshot()` exposes the current outcome, logical round, number of state-eligible operators, and number of pending reactive activations.

## External operators

Wire protocol v1 is transport-neutral:

```text
STARLINGS/1 REQUEST
operator=20
round=4
var=2,3,i:20
END
```

and:

```text
STARLINGS/1 RESPONSE
operator=20
claim=3,3,1000,20,i:30
END
```

The Zig SDK provides subprocess and Python invocation descriptors behind an injectable transport seam. `python/starlings_operator.py` provides a no-dependency Python stdin/stdout helper.

## Conformance gate

The final SDK stack checks:

- generated acyclic dependency graphs;
- exact replay for the same seed/context;
- malformed output rejection;
- crash and timeout propagation;
- stale-variable eligibility;
- conflict preservation;
- heterogeneous native/external/deterministic composition;
- native/external canonical claim parity;
- a real Python subprocess round trip in CI.

The key invariant is that changing the operator implementation should not change the coordination semantics.