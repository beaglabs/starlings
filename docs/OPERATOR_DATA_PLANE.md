# Operator Data Plane — Phase 3A

Phase 3A extends the reactive runtime from variable/invariant claims into a
replayable operator data and control plane.

It does not add a workflow. Operators remain eligible from local state,
invariants, observations, and declared requirements. The runtime only records
what an eligible activation produced and applies the same deterministic
arbitration already established in Phase 2.

## Canonical activation trace

A successful activation can now produce this event shape:

```text
operator_started
  claim_accepted*
  invariant_changed*
  artifact_emitted*
  action_proposed*
operator_completed
```

A failed activation remains:

```text
operator_started
operator_failed
```

Failure kinds distinguish:

- execution;
- validation;
- timeout;
- crash.

The existing event hash chain remains canonical. Existing Phase 2 event kind
numbers and failure-kind numbers are unchanged; Phase 3 kinds are appended.

## Artifacts

An `artifact_emitted` event records:

- logical round;
- source operator;
- activation epoch;
- content-addressed artifact ID;
- artifact size.

The artifact content ID is produced by the existing SDK artifact identity
function and therefore binds the media type and bytes. Phase 3A records the
emission in the canonical trace; physical artifact-byte storage belongs to a
later data-plane slice.

Artifact emission count is derived from the event stream and reconstructs
identically under replay.

## Actions

Every action proposal receives a canonical content ID derived from:

- source operator;
- activation epoch;
- ordinal within the operator output;
- action name;
- action payload;
- approval requirement.

The event stream stores the action ID and whether approval is required.

Actions therefore have replay-derived state:

```text
no approval required -> ready
approval required    -> pending_approval
action_decided       -> approved | rejected
```

Approval and rejection are themselves append-only `action_decided` events.
There is no separate mutable approval database in the runtime.

Approval decisions are only accepted after the operator activation has settled.
An unknown action does not start a run as a side effect.

## Replay

Replay validates that artifact and action proposal events occur inside the
correct open activation and match its:

- operator ID;
- activation epoch;
- logical round.

Action decisions require an existing pending approval and no open activation.

The replay CLI reports:

- artifact emission count;
- pending activations;
- pending approvals;
- open activation.

## External operators

The existing transport-neutral subprocess/Python wire adapter already emits
claims, invariants, and actions into `OperatorOutput`. Phase 3A makes those
actions first-class canonical runtime events.

The next Phase 3 slice will implement real supervised OS transport execution,
including timeout enforcement, exit/crash classification, bounded stdout/stderr,
and the ownership rules required for external text/artifact outputs.

Phase 3A intentionally does not pretend that an injectable test transport is
already a production subprocess supervisor.

## Acceptance coverage

Phase 3A tests cover:

- artifact emission inside an activation;
- approval-gated action proposal;
- approval as an append-only event;
- identical action/artifact state after replay;
- durable close/load/replay with artifact + approved action;
- distinct canonical timeout and crash failures;
- malformed data-plane descriptor rejection.

The Phase 3 acceptance gate is broader and is not complete until real native,
Python, and subprocess operators execute under the supervised operator plane.
