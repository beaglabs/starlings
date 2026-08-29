# F2.1 synchronous-to-asynchronous gap evidence

F2.1 measures the cost of the frozen Stage 7C asynchronous execution model
relative to synchronous Stage 7A under matched per-operator decision budgets.

The comparison holds fixed:

~~~text
profiles:
  theta37
  theta51
  theta93
  round_robin
  seeded
  novel_first

topologies:
  ring
  grid

seeds:
  0 1 2

N=8
F=32
R=2
B=2
decision budget/operator=4096
~~~

This yields 36 paired worlds.

## Matched budget semantics

One synchronous Stage 7A round gives every operator one policy decision, so
`max_rounds=4096` is exactly 4096 decisions per operator.

The asynchronous arm preserves the frozen Stage 7C local-clock schedule and
adds a hard per-operator decision cap of 4096. Its logical tick horizon is long
enough for the slowest allowed local clock to consume that full budget.

A failed async world is valid only when all operators reach exactly 4096 local
decisions, at which point it is explicitly right-censored.

## Frozen Stage 7C parity

Because the per-operator cap is an experimental extension, the derived async
harness is checked against the frozen Stage 7C engine whenever the cap does not
bind.

Parity includes:

- success and elapsed ticks;
- collector initial/final facts;
- local policy ticks;
- actions/rejections;
- transport attempts and terminal categories;
- duplicate/reordering counters;
- communication/useful/duplicate units;
- schedule hash;
- trace hash;
- violations.

## Canonical result — 2026-08-29

The authoritative local verifier completed on macOS with Zig 0.16.0.

~~~text
rows: 36
dataset bytes: 5695
SHA-256:
34531d63dc8628a7592f01f4c06cc0be632e0c2428f43e933beeec0b1a5293cd

byte_identical_replay: yes
stage7c_parity_rows: 36/36
budget_bound_rows: 0

sync_successes: 36/36
async_successes: 36/36
async_censored: 0

violations: 0
stage7c_parity_failures: 0
accounting_failures: 0
communication_failures: 0
invalid_censoring: 0
~~~

The generated dataset is:

~~~text
trials/f2-gap.tsv
~~~

in `beaglabs/starling-experiments` and remains intentionally uncommitted.
This document freezes its identity and result summary.

## Per-profile aggregate gap

Each row below aggregates six paired worlds.

~~~text
novel_first:
  communication_delta = +819
  duplicate_delta     = +779
  policy_call_delta   = +267
  tick_round_delta    = +120

round_robin:
  communication_delta = +1092
  duplicate_delta     = +1040
  policy_call_delta   = +315
  tick_round_delta    = +149

seeded:
  communication_delta = +1374
  duplicate_delta     = +1356
  policy_call_delta   = +405
  tick_round_delta    = +289

theta37:
  communication_delta = +478
  duplicate_delta     = +427
  policy_call_delta   = +192
  tick_round_delta    = +103

theta51:
  communication_delta = +144
  duplicate_delta     = +162
  policy_call_delta   = +135
  tick_round_delta    = +94

theta93:
  communication_delta = +691
  duplicate_delta     = +644
  policy_call_delta   = +380
  tick_round_delta    = +205
~~~

Aggregate across all 36 paired worlds:

~~~text
communication_delta = +4598
duplicate_delta     = +4408
policy_call_delta   = +1694
tick_round_delta    = +960
~~~

## Interpretation

F2.1 is a **PASS**.

The asynchronous execution model preserves feasibility across the entire
frozen N=8 comparison box: all 36 synchronous worlds and all 36 asynchronous
worlds converge, with no censoring.

The paired result also quantifies a real cost of asynchrony in this box:
aggregate communication, duplicate communication, policy calls, and elapsed
ticks are all higher in the async arm. The dominant communication increase is
duplicate traffic: +4408 duplicate units account for most of the +4598 total
communication-unit increase.

Among the six profiles, theta51 has the smallest aggregate communication and
tick/round gap, while seeded has the largest aggregate communication and
tick/round gap.

The canonical verdict is:

~~~text
F2.1 PASS: paired synchronous/asynchronous gap dataset is deterministic,
budget-matched, and Stage-7C-parity checked
~~~

F2.2 may proceed only after this evidence record is merged.
