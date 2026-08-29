# F2.2 asynchronous scaling evidence

F2.2 measures the feasibility boundary of the frozen asynchronous Starlings
execution model under a fixed 4096 decisions/operator budget.

The canonical scaling box is:

~~~text
N = 8, 16, 32, 64, 128
F/N = 1, 2
topology = ring, grid
profiles = theta37, theta51, theta93, novel_first
seeds = 0, 1, 2
redundancy = 2
bandwidth = 2
clock_jitter = 3
latency_min = 1
latency_jitter = 4
~~~

Exactly 240 worlds.

## Budget and censoring discipline

Each operator receives at most 4096 local policy decisions.

If all operators consume that budget before the collector converges, F2.2
does not censor immediately. No further policy decisions are allowed, but
deterministic delivery continues until all in-flight envelopes are drained.

A valid censored world therefore requires:

~~~text
success = no
censored = yes
min_local_decisions = 4096
max_local_decisions = 4096
budget_exhausted_tick > 0
pending = 0
collector_final < facts
~~~

This prevents the measured scaling boundary from being an artifact of
messages still in flight at the budget edge.

## Structural gate

F2.2 is no-fault. Every canonical row must therefore have:

~~~text
dropped = 0
partitioned = 0
crashed = 0
queue_overflow = 0
duplicate_copies = 0
violations = 0
~~~

and satisfy:

~~~text
transport_attempts = delivered + pending
communication_units = useful + duplicate
~~~

## F2.1 continuity

The F2.2 implementation uses a separate harness rather than modifying the
frozen F2.1 code.

Before scaling results are interpreted, the F2.2 test suite checks exact
agreement with F2.1 across the complete N=8 scaling box:

~~~text
4 profiles × 2 densities × 2 topologies × 3 seeds = 48 worlds
~~~

The comparison includes outcome, elapsed ticks, collector state, policy/action
counts, transport counts, communication metrics, schedule hash, trace hash and
violations.

## Canonical result — 2026-08-29

The authoritative local verifier completed on macOS with Zig 0.16.0.

~~~text
rows: 240
dataset bytes: 35712
SHA-256:
25f828b00b74b93f27826c91193057b3bfb1148ae0127c32be1afa79f1911773

byte_identical_replay: yes
successes: 240/240
censored: 0
violations: 0
accounting_failures: 0
communication_failures: 0
queue_overflow: 0
unexpected_fault_terminals: 0
~~~

The generated dataset is:

~~~text
trials/f2-scaling.tsv
~~~

in `beaglabs/starling-experiments` and remains intentionally uncommitted.
This document freezes its identity and result summary.

## Per-profile totals

~~~text
theta37:
  successes = 60/60
  communication_units = 1816013
  duplicate_units = 1434263

theta51:
  successes = 60/60
  communication_units = 1720228
  duplicate_units = 1338138

theta93:
  successes = 60/60
  communication_units = 1737538
  duplicate_units = 1355694

novel_first:
  successes = 60/60
  communication_units = 7575655
  duplicate_units = 7193975
~~~

## Feasibility boundary

For every one of the 16 `profile × topology × F/N` groups, the three-seed
success pattern is:

~~~text
N=8:   3/3
N=16:  3/3
N=32:  3/3
N=64:  3/3
N=128: 3/3
~~~

Therefore every group has:

~~~text
largest_all_success_N = 128
first_any_censored_N = none
first_all_censored_N = none
monotone_success_counts = yes
~~~

This does **not** establish a feasibility boundary at N=128.

The correct conclusion is that no boundary was observed inside the frozen
experimental box. For every profile, topology and tested fact density:

~~~text
observed feasibility lower bound:
  N > 128
~~~

The true boundary, if one exists under the same budget and parameterization,
lies outside the canonical F2.2 range.

## Interpretation

F2.2 is a **PASS**.

The asynchronous substrate remains deterministic and fully accounted across
all 240 canonical worlds. Every world converges before budget exhaustion, so
the planned right-censoring mechanism is validated structurally but is not
activated by the canonical matrix.

The most communication-heavy profile in this box is `novel_first`;
`theta51` has the lowest aggregate communication and duplicate counts among
the four F2.2 profiles.

Canonical verdict:

~~~text
F2.2 PASS: asynchronous scaling dataset is deterministic, fully accounted,
and no feasibility boundary was observed through N=128 under the fixed
4096 decisions/operator budget
~~~

Together with F2.1, this closes the F2 scientific questions:

- F2.1 quantifies the cost of asynchrony at N=8;
- F2.2 establishes that the tested asynchronous policies remain feasible
  throughout the frozen scaling box and places the observed boundary beyond
  N=128.

The disposable F2 experiment scaffold may be deleted only after this
documentation-of-record is merged.
