# Stage 7C — Deterministic Asynchronous Transfer

## Status

Stage 7B is complete. It produced the frozen validation-selected policy family:

~~~text
theta37 = (244, 94, 15, 958)
theta51 = (354, 141, 0, 994)
theta93 = (685, 283, 960, 344)
~~~

Stage 7C is the next uncompleted stage.

The P2Panda adapter was an experimental candidate for Stage 7C. Focused
history/live synchronization tests could pass, but the canonical eight-node
transfer remained nondeterministic: identical configurations sometimes
converged and sometimes exhausted the runtime with missing collector facts
while the adapter reported no synchronization or processing errors. That is
not sufficient evidence for the Stage 7C claim, so the Rust module, dependency,
C ABI, and P2Panda-specific report were removed.

This result does not invalidate Stage 7A or Stage 7B. It rejects one candidate
measurement substrate.

## Research question

Does the frozen Stage 7B Pareto family retain its convergence and resource-cost
advantages when synchronous global rounds are replaced by independently
scheduled local decisions and asynchronous delivery?

The policy remains unchanged:

~~~text
a_i,t = pi_theta(o_i,t)
~~~

Only the execution and observation schedule changes.

## Canonical Stage 7C boundary

Stage 7C will be implemented entirely in Zig as a deterministic discrete-event
experiment. The runtime must support:

- independent local policy clocks;
- a seeded priority queue of policy and delivery events;
- latency and jitter;
- loss, duplication, and reordering;
- partitions and reconnection;
- stale local observations;
- crash and restart with explicit volatile/persistent state;
- bounded queues and explicit overflow;
- stable event identities and idempotent fact merge;
- complete replay from configuration, seed, and recorded event schedule.

The transport abstraction moves envelopes. Starlings continues to own policy,
logical topology, recipient selection, fact semantics, idempotency, traces,
metrics, and completion.

A real socket, process, host, or third-party replication layer is outside the
Stage 7C validation gate. Such a layer may be evaluated later as a separable
candidate after deterministic asynchronous transfer is understood.

## Validation gates

Stage 7C is complete only when all of the following hold:

1. identical configuration and seed produce byte-identical event traces and
   result rows;
2. a recorded schedule replays to the same result independently of wall time;
3. zero-latency, zero-fault asynchronous execution has an explicit comparison
   against the Stage 7B synchronous baseline;
4. every dropped, duplicated, delayed, reordered, rejected, and undelivered
   envelope is accounted for;
5. collector completion and right-censoring are explicit outcomes;
6. the three frozen theta profiles and named controls are evaluated without
   changing theta;
7. canonical datasets, hashes, holdouts, and progression criteria are frozen
   before interpreting results.

## Follow-on PR stack

These PRs should be created only after the current cleanup PR merges. Each PR
is based on the preceding PR so the review order is explicit.

### PR 1 — Stage 7C.1 deterministic event transport

Implement the generic event queue, virtual clocks, envelope identity, seeded
delivery schedule, latency/jitter/loss/duplication/reordering controls, replay
format, and deterministic unit/property tests.

Gate: transport traces are byte-identical for the same seed and replay exactly.

### PR 2 — Stage 7C.2 frozen-policy transfer harness

Run the exact Stage 7A policy and frozen Stage 7B profiles directly in Zig over
the Stage 7C.1 transport. Add asynchronous local observations, logical
ring/grid/complete recipients, collector completion, right-censoring, and a
synchronous-baseline comparison row.

Gate: the no-fault transfer matrix is deterministic and fully accounted.

### PR 3 — Stage 7C.3 disruption and recovery matrix

Add frozen partition/reconnect, stale-view, crash/restart, queue-capacity, and
combined perturbation worlds. Freeze training/validation/holdout axes before
running the canonical matrix.

Gate: every injected event and terminal missing fact has a traceable cause; no
silent loss is possible.

### PR 4 — Stage 7C.4 canonical analysis and decision

Generate and hash canonical datasets, summarize convergence and resource-cost
transfer for the Pareto family and named controls, quantify the
synchronous-to-asynchronous gap, and record the architectural decision.

Gate: either validate Stage 7C and identify which asynchronous machinery earns
integration, or record the observed limitation and keep it experimental.

## What is deliberately not scheduled yet

No later numbered stage is defined here. Real sockets, multiple processes,
multiple hosts, WAN behavior, RF/off-grid transports, and third-party
replication systems remain candidate experiments. Their ordering depends on
the Stage 7C evidence and should not be declared in advance.
