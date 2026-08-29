# Stage 7C — Deterministic Asynchronous Transfer

## Status

Stage 7A defined the compact local policy and Stage 7B froze the
validation-selected Pareto family:

~~~text
theta37 = (244, 94, 15, 958)
theta51 = (354, 141, 0, 994)
theta93 = (685, 283, 960, 344)
~~~

Stage 7C now has a Zig-native deterministic asynchronous transfer harness. The
canonical Stage 7C dataset remains to be generated and frozen after the
implementation and validation gates pass.

The removed P2Panda adapter remains a negative candidate result: focused
history/live tests could pass, but identical eight-node transfer configurations
sometimes converged and sometimes exhausted the runtime with missing collector
facts while reporting no synchronization or processing errors. Stage 7C
therefore replaces that measurement substrate rather than changing its research
question.

## Research question

Does the frozen Stage 7B Pareto family retain convergence and resource-cost
advantages when synchronous global rounds are replaced by independently
scheduled local decisions and asynchronous delivery?

The policy remains unchanged:

~~~text
a_i,t = pi_theta(o_i,t)
~~~

Only execution and observation timing changes.

## Implementation

`src/experiments/stage7/stage7c_async_transfer.zig` directly imports the exact
Stage 7A policy. There is no policy rewrite, FFI boundary, Rust toolchain,
socket, wall clock, or third-party replication layer.

A run contains:

- independently seeded node periods and local policy-round counters;
- deterministic latency and jitter;
- delivery reordering induced by due times;
- deterministic loss and duplicate copies;
- a fixed-capacity pending-delivery queue with explicit overflow;
- a timed two-component partition followed by reconnection;
- a timed node crash and restart;
- explicit persistent or reset knowledge across restart;
- stable sender, recipient, sequence, and copy identity;
- idempotent commutative fact merge;
- schedule and trace hashes.

Events are ordered by virtual due tick and then transport ordinal. Wall-clock
scheduling cannot affect a result.

## Accounting invariant

Every physical transport attempt has exactly one terminal category at the
measurement horizon:

~~~text
transport_attempts
  = delivered_envelopes
  + dropped_envelopes
  + partitioned_envelopes
  + crashed_envelopes
  + queue_overflow_envelopes
  + pending_envelopes
~~~

For delivered fact units:

~~~text
communication_units
  = useful_deliveries
  + duplicate_deliveries
~~~

The runtime asserts both identities. Missing facts cannot disappear into an
unreported synchronization layer.

## Frozen first suite

The first comparison contains 24 worlds:

~~~text
profiles:
  theta37
  theta51
  theta93
  novel_first

topologies:
  ring
  grid

world/schedule seeds:
  0
  1
  2

N=8
F=32
R=2
B=2
max virtual ticks=4096
~~~

Generate it with:

~~~sh
zig test src/root.zig
zig run src/experiments/stage7/stage7c_cli.zig -- validate
zig run -O ReleaseFast src/experiments/stage7/stage7c_cli.zig -- suite \
  > trials/stage7c-async.tsv
~~~

A single world is:

~~~sh
zig run -O ReleaseFast src/experiments/stage7/stage7c_cli.zig -- \
  run theta51 8 32 ring 2 2 0 0
~~~

## Validation gates

The implementation gate requires:

1. all root tests pass;
2. frozen theta values are exact;
3. identical configuration and seed reproduce schedule hash, trace hash, and
   terminal result;
4. changing the schedule seed changes the schedule;
5. the no-fault theta51 smoke converges;
6. loss, duplication, partition, and crash paths are exercised;
7. all transport and fact-unit accounting identities hold;
8. policy violations remain zero.

The scientific gate then requires freezing the generated dataset hash,
summarizing convergence and cost transfer for the three selected profiles and
novel-first, and recording whether Stage 7C validates the transfer hypothesis.

## Boundary

Stage 7C establishes deterministic asynchronous policy transfer, not real
network behavior. Multiple processes, hosts, WANs, RF/off-grid transports, and
third-party replication systems remain separable candidate experiments. No
later numbered stage is declared by this report.
