# F3 local inference-control evidence

F3 tested whether the frozen Stage 7A/7B policy surface could be extended from:

~~~text
theta = (n, e, r, u)
~~~

to:

~~~text
theta = (n, e, r, u, c)

c = inference-gating permille
~~~

where `c` controls whether an operator refreshes its local observation and
recomputes a fresh Stage 7A action or reuses its previously cached action.

The primary scientific question was:

> Can local inference/recomputation be reduced while preserving zero-failure
> validation feasibility and competitive resource behavior?

## Gate semantics

Every policy opportunity is exactly one of:

~~~text
refresh:
  fresh observation
  frozen Stage 7A decision
  inference cost = 1

reuse:
  cached action
  inference cost = 0
~~~

The first opportunity always refreshes.

Inference accounting is exact:

~~~text
policy_calls = inference_units + cache_reuses
~~~

The `c=1000` corner delegates directly to frozen Stage 7A and therefore has:

~~~text
inference_units = policy_calls
cache_reuses = 0
~~~

## Historical Stage 7B provenance

The Stage 7B reference was re-materialized from historical blob:

~~~text
e91f88b2ea2dafd6bd51113954ff03aee4330163
~~~

with only the two import paths rewritten for the experiments repository
layout.

The canonical Stage 7B report identity is:

~~~text
SHA-256:
e3d27eec1f7bb78d5cabf869fc5172c3746a356f7f4cd9db4cc91f657e01ff2f
~~~

F3 independently anchors the historical reference to the frozen
validation-selected Stage 7B family:

~~~text
id37 = (244,94,15,958)
  failures=0
  rounds=1046
  communication=258389
  duplicates=170485
  computation=55936

id51 = (354,141,0,994)
  failures=0
  rounds=1054
  communication=255319
  duplicates=167211
  computation=56576

id93 = (685,283,960,344)
  failures=0
  rounds=1435
  communication=250805
  duplicates=162945
  computation=76704
~~~

## Search design

The canonical F3 candidate set contains:

~~~text
6 fixed Stage 7A probe profiles at c=1000
128 deterministic five-dimensional Latin-hypercube candidates
134 total candidates
127 candidates with c<1000
~~~

Ranges:

~~~text
n in [0,1000]
e in [0,1000]
r in [0,1000]
u in [250,1000]
c in [0,1000]
~~~

Training and validation preserve the frozen Stage 7B split definitions:

~~~text
training:
  N={32,64}
  F/N={1,2}
  topology={ring,grid}
  R=2
  B={1,2,4}
  seed={0,1}
  H=2048
  48 worlds/candidate

validation:
  same structural box
  seed=2
  24 worlds/evaluated candidate
~~~

Selection remains feasibility-first, then Pareto-minimizes:

~~~text
rounds
communication
duplicates
policy/computation calls
inference units
~~~

Hard holdouts remain the Stage 7B population, density, redundancy, bandwidth,
complete-topology and compound extrapolation sets. Hard results do not
participate in selection.

## c=1000 corner audit

Every historical Stage 7B candidate was evaluated through the F3 `c=1000`
corner on both training and validation:

~~~text
candidate_count: 134
aggregate_checks: 268
mismatches: 0
~~~

This confirms that introducing the fifth control dimension does not alter the
frozen four-dimensional behavior when inference refresh is always enabled.

## Canonical result — 2026-08-29

The authoritative local verifier completed on macOS with Zig 0.16.0.

~~~text
rows: 187
dataset bytes: 25506
SHA-256:
42e60db5b999d19319f00a254eafda0eebe3ae5c1c37a824ca155bcbd074bfb2

byte_identical_replay: yes
violations: 0
inference_accounting_failures: 0
c1000_corner_mismatches: 0
stage7b_anchor: PASS
~~~

Candidate-set validation:

~~~text
candidate_count: 134
expected_candidate_count: 134
corner_candidate_count: 134
gated_candidates: 127
expected_gated_candidates: 127
invalid_theta: 0
duplicate_theta: 0
training_worlds: 48
validation_worlds: 24
~~~

The generated dataset is:

~~~text
trials/f3-inference-control.tsv
~~~

in `beaglabs/starling-experiments` and remains intentionally uncommitted.
This document freezes its identity and result summary.

## Validation-selected frontier

The canonical validation frontier contains two policies:

~~~text
id=3
theta=(500,0,250,1000,1000)
failures=0
rounds=1044
communication=265191
duplicates=177280
computation=55968
inference=55968
reuse=0

id=5
theta=(750,250,0,500,1000)
failures=0
rounds=1448
communication=250833
duplicates=162874
computation=77408
inference=77408
reuse=0
~~~

Both selected policies have:

~~~text
c = 1000
~~~

No gated candidate (`c < 1000`) survived onto the validation-selected
feasibility/resource frontier.

Therefore the F3 PASS criterion was not met:

~~~text
selected gated candidate:
  validation failures = 0

ungated twin:
  validation failures = 0

gated inference < ungated inference
~~~

No selected gated candidate existed for that comparison.

## Frozen Stage 7B family on hard holdouts

The frozen Stage 7B selected family remained feasible across all six hard
holdout sets when evaluated ungated:

~~~text
id37:
  failures = 0
  communication = 28280472
  inference = 1103040

id51:
  failures = 0
  communication = 27458552
  inference = 1100576

id93:
  failures = 0
  communication = 29195088
  inference = 1615264
~~~

## Interpretation

F3 is a **LIMITATION**, not an engineering failure.

Every provenance, determinism, accounting and historical-corner gate passed.
The negative result is therefore attributable to the tested mechanism and
search outcome rather than to an invalid experiment.

The canonical result rejects this specific inference-control design as a
validated extension of the current policy surface:

~~~text
deterministic refresh gate keyed by:
  world seed
  operator index
  local round

when refresh is skipped:
  reuse the previously cached action
~~~

Within the frozen F3 search envelope, policies that reduced refresh frequency
did not survive feasibility-first validation Pareto selection. The selected
frontier preferred always-refresh behavior.

This does **not** establish that local inference control is impossible. The
result does not evaluate, for example:

- state-change-triggered refresh;
- uncertainty- or novelty-triggered refresh;
- invalidation of cached actions after new information arrives;
- learned or adaptive inference budgets;
- model confidence or token-cost-aware gating;
- asynchronous/model-backed inference control.

The architectural consequence is narrower:

> Keep the validated four-dimensional `theta=(n,e,r,u)` policy surface as
> authoritative. Do not promote the tested cached-action `c` gate into the
> protocol core.

Canonical verdict:

~~~text
F3 LIMITATION: local inference-control evidence complete
~~~
