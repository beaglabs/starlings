# F3 local inference-control evidence

F3 tested whether Starlings operators can reduce local inference/recomputation
without sacrificing convergence or the resource behavior established by the
frozen Stage 7A/7B policy family.

F3 produced two distinct results:

~~~text
F3a  blind probabilistic / round-indexed cache gating
     LIMITATION

F3b  state-aware knowledge/staleness cache gating
     PASS
~~~

Together they answer the broader local-inference-control question while
separating a failed mechanism from the successful one.

## Frozen communication-policy surface

The validated Stage 7A/7B communication policy remains:

~~~text
theta = (n, e, r, u)
~~~

with the frozen selected family:

~~~text
id37 = (244,94,15,958)
id51 = (354,141,0,994)
id93 = (685,283,960,344)
~~~

F3b deliberately holds these communication-policy parameters fixed and varies
only the local inference controller.

## F3a — blind gating limitation

F3a extended the search surface with:

~~~text
theta = (n, e, r, u, c)

c = deterministic inference-gating permille
~~~

A skipped inference reused the previously cached action.

The canonical F3a dataset is:

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

The validation-selected frontier contained only always-refresh policies:

~~~text
id=3 theta=(500,0,250,1000,1000)
id=5 theta=(750,250,0,500,1000)
~~~

Both have:

~~~text
c = 1000
~~~

Therefore F3a closed as a scientifically valid limitation:

~~~text
F3a LIMITATION:
blind probabilistic inference gating did not produce a validation-selected
zero-failure policy with lower inference use
~~~

The negative result rejected that specific refresh mechanism; it did not
reject local inference control in general.

## F3b — paired state-aware control

F3b removed the main F3a confound.

Rather than jointly varying `(n,e,r,u,c)`, it fixed the three frozen Stage 7B
base policies and compared five deterministic inference controllers for each:

~~~text
always_refresh
knowledge_change
knowledge_or_stale
knowledge_or_stale_age4
knowledge_or_stale_age8
~~~

Exactly:

~~~text
3 frozen base policies × 5 controllers = 15 paired candidates
~~~

Each state-aware controller therefore has an exact always-refresh twin with
identical base theta and world configuration.

## State-aware controller semantics

### always_refresh

Exact frozen Stage 7A behavior.

~~~text
inference_units = policy_calls
cache_reuses = 0
~~~

### knowledge_change

Refresh when:

- no cached action exists;
- local knowledge changed since the last inference;
- the cached action became structurally invalid.

Otherwise reuse the cached action.

### knowledge_or_stale

Includes the `knowledge_change` triggers and additionally refreshes when:

~~~text
unsent local facts remain
AND
every fact selected by the cached action has already been sent
~~~

This identifies a cached action that is still structurally valid but
decision-stale.

### age-bounded variants

`knowledge_or_stale_age4` and `knowledge_or_stale_age8` add a forced refresh
after four or eight rounds without fresh inference.

## Exact accounting

Each policy opportunity is exactly one of:

~~~text
fresh inference
cached action reuse
~~~

so:

~~~text
policy_calls = inference_units + cache_reuses
~~~

Each inference unit is also attributed to exactly one cause:

~~~text
first
always
knowledge change
invalid cached action
semantic staleness
maximum age
~~~

and:

~~~text
inference_units = sum(refresh-reason counters)
~~~

Communication remains:

~~~text
communication_units = useful + duplicate
~~~

## Paired historical baseline gate

Before interpreting any F3b controller result, the three `always_refresh`
arms reproduced the historical Stage 7B training and validation aggregates
exactly:

~~~text
base ids: 37,51,93
aggregate checks: 6
mismatches: 0
~~~

This proves the paired comparison is anchored to the frozen Stage 7B behavior.

## Canonical F3b result — 2026-08-29

The authoritative local verifier completed on macOS with Zig 0.16.0.

~~~text
rows: 85
dataset bytes: 11329
SHA-256:
eb4237fdf5e6ac309b29f01c16345f9ff6507b8806ab986b15fbb3c9e080347a

byte_identical_replay: yes
violations: 0
inference_accounting_failures: 0
communication_accounting_failures: 0
paired_baseline_mismatches: 0
~~~

The generated dataset is:

~~~text
trials/f3b-state-aware.tsv
~~~

in `beaglabs/starling-experiments` and remains intentionally uncommitted.
This document freezes its identity and result summary.

## Validation frontier

Promoted state-aware controllers include:

~~~text
base 37 / knowledge_or_stale
  failures = 0
  rounds = 1046
  communication = 257666
  duplicates = 169774
  computation = 55936
  inference = 54769
  reuse = 1167
  hard failures = 0

base 51 / knowledge_or_stale
  failures = 0
  rounds = 1054
  communication = 253171
  duplicates = 165064
  computation = 56576
  inference = 55017
  reuse = 1559
  hard failures = 0

base 93 / knowledge_or_stale
  failures = 0
  rounds = 1437
  communication = 251061
  duplicates = 163160
  computation = 76832
  inference = 75701
  reuse = 1131
  hard failures = 0
~~~

Age-bounded variants also reached the validation frontier, but did not improve
the canonical validation measurements over plain `knowledge_or_stale`.
Therefore the simpler controller is preferred as the validated mechanism.

## Exact paired deltas

Against each exact always-refresh twin:

~~~text
base 37 / knowledge_or_stale
  inference delta     = -1167
  rounds delta        = 0
  communication delta = -723
  duplicate delta     = -711
  computation delta   = 0
  hard failures       = 0

base 51 / knowledge_or_stale
  inference delta     = -1559
  rounds delta        = 0
  communication delta = -2148
  duplicate delta     = -2147
  computation delta   = 0
  hard failures       = 0

base 93 / knowledge_or_stale
  inference delta     = -1003
  rounds delta        = +2
  communication delta = +256
  duplicate delta     = +215
  computation delta   = +128
  hard failures       = 0
~~~

Base 51 gives the strongest measured validation improvement: fewer inference,
less communication, fewer duplicates, no extra rounds, no extra computation,
and zero hard-holdout failures.

Base 93 demonstrates that inference savings can trade against other resources;
both its always-refresh and state-aware variants remain Pareto-relevant.

## Hard-holdout behavior

Every promoted F3b controller remained zero-failure across all six frozen hard
families:

~~~text
population_N_128
density_F_over_N_4
redundancy_R_4
bandwidth_B_8
topology_complete
compound
~~~

The paired always-refresh baselines also remained zero-failure.

Therefore the state-aware inference reduction is not confined to the ordinary
validation box.

## F3 conclusion

F3 closes as a **PASS** for local inference control, with an important
mechanistic qualification:

~~~text
blind refresh gating:
  LIMITATION

state-aware refresh gating:
  PASS
~~~

The validated architecture is not:

~~~text
theta = (n,e,r,u,c)
~~~

Instead:

~~~text
communication policy:
  theta = (n,e,r,u)

local inference controller:
  deterministic state-aware cache invalidation
~~~

The simplest validated controller is:

~~~text
refresh if:
  no cached action exists
  OR local knowledge changed since last inference
  OR cached action became structurally invalid
  OR cached action is decision-stale:
       unsent local facts remain
       AND cached selected facts are already sent

otherwise:
  reuse cached action
~~~

This mechanism reduces fresh local inference without requiring a new
probabilistic policy dimension.

Canonical verdict:

~~~text
F3 PASS:
state-aware local inference control reduces fresh inference while preserving
zero-failure validation and hard-holdout behavior
~~~
