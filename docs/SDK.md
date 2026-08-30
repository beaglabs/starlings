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

- no activation is pending and all target variables carry values → `success`;
- no activation is pending and a target is explicitly `conflicting` → `conflicting`;
- no activation is pending and a target is `not_visible`, `unavailable`, or `blocked` → `blocked`;
- no activation is pending while targets remain unknown → `quiescent`;
- the activation budget is consumed while work remains → `exhausted`.

Terminal classification is deliberately made only after pending activations drain, so one early target claim cannot hide a later conflicting contribution. Quiescence is distinct from failure: a quiescent population can become `running` again when an external observation advances a relevant state revision.

`schedulerSnapshot()` exposes the current outcome, logical round, number of state-eligible operators, and number of pending reactive activations.

## Append-only runtime events and replay

The reactive runner records accepted runtime transitions in a canonical append-only event chain.

Each `EventRecord` contains:

```text
sequence
previous_event_id
event_id
event_payload
```

The event ID is domain-separated BLAKE3 over the canonical event version, sequence number, previous event ID, event kind, and payload identity. The previous event ID makes the log a hash chain: deletion, reordering, or mutation without recomputing the chain is detected by `validateEventLog()`.

Phase 2C records these event kinds:

```text
run_started
observation_added
operator_started
claim_accepted
invariant_changed
operator_completed
operator_failed
```

`run_started` binds the event stream to the runner seed and a canonical configuration digest covering the registered variables, invariants, operators, eligibility declarations, and targets. Once the first run event is emitted, the registry is locked against mutation.

Variable claims reuse the canonical claim identity from `output_state.claimContentId`. Operator-start events preserve the activation epoch and dependency fingerprint so replay can reconstruct the reactive scheduler state without re-executing an operator.

A fresh runner with the same registry, operator declarations, seed, and targets can call:

```zig
try replayed.replayFrom(&live.events);
```

Replay validates the event chain, run configuration/seed, deterministic scheduler arbitration, operator authorization, activation ordering, dependency fingerprints, and event rounds while reconstructing:

- materialized variable state;
- invariant state;
- state revisions;
- claim-store identities;
- activation epochs and settled activations;
- accepted/rejected claim counters;
- proposed-action counts;
- scheduler outcome and pending activation state.

Replay does **not** call operator implementations. It is a state reconstruction path, not a second execution.

The event log is currently an in-memory bounded SDK primitive. Durable NDJSON/file persistence and CLI replay surfaces are intentionally deferred to the next product slice rather than coupling Phase 2C to storage or command-line policy.

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