# Durable Replay v1

Phase 2D makes the Phase 2C event stream durable without changing its semantics.

The in-memory event log remains canonical. Persistence stores the same typed,
hash-chained events and a bounded configuration snapshot sufficient to build a
replay-only runner after process restart.

## Run layout

A durable run lives under:

```text
.starlings/runs/<run-id>/
├── configuration.bin
└── events.ndjson
```

The run ID is a unique 256-bit execution identifier encoded as 64 lowercase
hexadecimal characters. It is intentionally distinct from the content-addressed
event head: two executions with the same seed and configuration are still
different runs.

## Configuration snapshot

`configuration.bin` is versioned and contains the replay-relevant runtime
configuration:

- run ID;
- seed;
- configuration digest;
- variable schemas and freshness;
- invariant declarations;
- operator manifests;
- eligibility expressions;
- targets.

The snapshot does not contain executable operator code. On replay, operators are
registered with a replay-only implementation that fails if invoked. Replay must
therefore reconstruct state exclusively from accepted events.

Before applying persisted events, the replay path recomputes the configuration
digest and requires it to match the snapshot and the original `run_started`
event.

A `RunWriter` is also bound to the seed and configuration digest that existed
when the snapshot was written. If configuration changes before the first event,
the writer rejects the run before an observation is durably accepted.

## Event file

`events.ndjson` contains exactly one record per newline:

```json
{"v":1,"seq":0,"prev":"...","id":"...","kind":1,"payload":"..."}
```

The envelope is NDJSON. The typed event payload uses a bounded, versioned binary
encoding represented as hexadecimal text.

For every complete record, loading verifies:

1. storage version;
2. sequence number;
3. previous-event identity;
4. event payload shape;
5. canonical event identity;
6. the complete event chain.

Mutation, deletion, insertion, or reordering therefore fails closed unless the
entire canonical chain is recomputed—and replay still validates configuration,
operator authorization, activation ordering, arbitration, and fingerprints.

## Durability boundary

A configured runtime event sink writes each accepted canonical event and calls
`File.sync` before acknowledging it to the runner.

If persistence fails, the runner latches closed. Future runtime operations return
`EventSinkFailed` rather than continuing without a durable trace.

This is designed for process termination and restart recovery. Phase 2D does not
claim whole-machine power-loss durability for parent-directory metadata.

## Crash behavior

A process can terminate at any point between events.

A newline-terminated event is treated as committed and must validate completely.

An unterminated final byte fragment is treated as a torn append and ignored on
load. A malformed newline-terminated record is never ignored.

If the last committed event is `operator_started`, replay reconstructs that
activation as open. It does not invoke the operator or fabricate completion.
The SDK exposes the open operator ID so host recovery policy can decide what to
do.

## Replay SDK

Replay is intentionally a library capability. Hosts open a durable run with the
run-store APIs, reconstruct a replay-only Runner from the persisted
configuration, and apply the validated event records without executing operator
implementations.

The SDK exposes the reconstructed event count, logical round, outcome,
claim/action counters, pending activations, open activation, and event-chain
head to the embedding application.

## Bounded replay envelope

The v1 durable store rejects runners that cannot fit the built-in replay
envelope:

- 256 variables;
- 128 invariants;
- 128 operators;
- 64 dependencies per declaration/expression;
- 64 targets;
- 512 claim slots;
- the corresponding bounded event capacity.

This makes successful durable-run creation a guarantee that the built-in replay
runner has sufficient structural capacity for the run.

## Validation

The Phase 2D acceptance path is:

```text
configure runner
    ↓
create durable run + snapshot
    ↓
attach event sink
    ↓
execute and sync canonical events
    ↓
terminate / close process
    ↓
open run in a fresh process
    ↓
reconstruct replay-only registry
    ↓
validate + replay events
    ↓
compare materialized state, revisions,
scheduler state, counters, and event head
```

Repository validation remains:

```sh
zig test src/root.zig
zig build test
```
