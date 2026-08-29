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
zig run src/stage7c_run.zig -- validate
zig run -O ReleaseFast src/stage7c_run.zig -- suite \
  > trials/stage7c-async.tsv
~~~

`src/stage7c_run.zig` is a one-line entry point. Zig 0.16 refuses imports
outside the root file's directory, so the CLI cannot be rooted directly in
`src/experiments/stage7/`.

A single world is:

~~~sh
zig run -O ReleaseFast src/stage7c_run.zig -- \
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

## Canonical first suite result

Generated with the authoritative Zig 0.16.0 toolchain
(`zig run -O ReleaseFast src/stage7c_run.zig -- suite`). An independent
ReleaseFast rerun reproduced the file byte-for-byte.

~~~text
dataset: trials/stage7c-async.tsv
worlds: 24
SHA-256: c89d1985af0479191126fca91265b1fe7f49e7b34db471e13c74e8bb28195a36
~~~

All 24 worlds converge with full accounting:

~~~text
success:                 24/24
collector final facts:   32/32 in every world
policy violations:       0
dropped/partitioned/
crashed/overflow:        0 (no-fault suite)
accounting identities:   hold in every world
~~~

The envelope tail still in flight at convergence is explicitly right-censored
as `pending`; nothing disappears from the ledger.

Per-profile convergence and cost (six worlds each, ring + grid, seeds 0-2):

~~~text
profile      ticks range    comm units   attempts  delivered  pending
theta37      17-38          3046         1736      1554       182
theta51      17-41          2992         1717      1540       177
theta93      34-77          3327         3496      3327       169
novel_first  17-53          3463         1921      1755       166
~~~

Jitter-induced due-time inversions produce reordered deliveries in every
world (558-1241 per profile across the six worlds) without affecting
convergence: the merge is commutative and idempotent.

The asynchronous ordering preserves the Stage 7B structure: theta37/theta51
remain the fast low-cost branch, theta93 remains the slower lower-bandwidth
branch, and both selected branches stay at or below novel-first on
communication units while converging.

Verdict: the first suite validates the transfer hypothesis for zero-fault
asynchronous execution. The frozen family converges deterministically under
independent local clocks and asynchronous delivery, with complete envelope
accounting and byte-identical replay. Fault-world behavior is exercised by
the unit tests but is not part of this frozen dataset; a canonical disruption
matrix remains undeclared follow-on work.

## Boundary

Stage 7C establishes deterministic asynchronous policy transfer, not real
network behavior. Multiple processes, hosts, WANs, RF/off-grid transports, and
third-party replication systems remain separable candidate experiments. No
later numbered stage is declared by this report.

## F1a addendum — canonical contested fault matrix

F1a extends the deterministic Stage 7C substrate into a frozen contested
matrix without modifying the S0 historical substrate files. The authoritative
measurement remains the deterministic Zig engine; F1a adds only explicit fault
controls and a per-fact causal ledger in `starling-experiments`.

Canonical matrix:

~~~text
profiles:    theta37 theta51 theta93 round_robin seeded novel_first
topologies:  ring grid
seeds:       0 1 2
N=8 F=32 R=2 B=2 max_ticks=4096
fault worlds: 12
rows:        432
~~~

The 12 worlds are no-fault, 50/200-permille loss, 250-permille duplication,
elevated latency/jitter, forced reordering, timed partition/reconnection,
crash/restart with persistent knowledge, crash/restart with reset knowledge,
stale policy-visible state, bounded queue capacity, and a combined contested
world.

Every collector-missing fact is assigned exactly one terminal cause:

~~~text
pending_at_censor
crashed_before_merge
delivery_faulted
never_transmitted
~~~

Any missing fact outside those categories is `unattributed` and fails the
gate. Envelope accounting and delivered-unit accounting remain mandatory.

Execution evidence, reproduced on macOS with Zig 0.16.0:

~~~text
dataset: trials/f1a-fault-matrix.tsv
rows: 432
bytes: 68973
SHA-256: c9d6b93937467ebf363ee14a02b2028ba0993d50a282770c547eaa3d35ed3ae5

successes:                     397/432
non-convergent worlds:          35/432
byte-identical replay:          yes
envelope_accounting_failures:   0
missing_accounting_failures:    0
unattributed_missing:           0
protocol violations:            0
~~~

All 35 non-convergent worlds are therefore measured negative outcomes rather
than silent loss. The matrix does not require universal convergence under every
fault; it requires deterministic replay, complete accounting, and causal
attribution for every terminal missing fact.

Per-profile summary across 72 worlds each:

~~~text
profile       successes  terminal missing  communication units
novel_first   66/72      22                181035
round_robin   67/72      18                176508
seeded        66/72      17                238524
theta37       66/72      19                181687
theta51       66/72      21                180593
theta93       66/72      21                116470
~~~

Verdict: F1a passes. The deterministic substrate remains byte-stable and fully
auditable under the canonical contested envelope. Non-convergence under some
fault configurations is preserved as evidence, with no unattributed fact loss.

