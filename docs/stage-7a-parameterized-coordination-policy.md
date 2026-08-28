# Stage 7A — Parameterized Coordination Policy

Stage 7A is the first control-law stage after the structural results from
Stages 5-6.1.

The goal is deliberately narrower than Stage 7B:

> Define a compact local coordination parameter theta, prove that the existing
> named policies remain exact controls inside the parameter space, and verify
> that deterministic interior policies produce a measurable control surface.

Stage 7A does not optimize theta.

## Why now

The preceding stages separated several pieces of the population dynamics:

~~~text
Stage 5C sparse load:
  lambda = F / (B H)

Stage 6 topology:
  structural reachability versus dynamical/horizon failure

Stage 6.1 one-round robustness:
  M = F - K0
  h = -M log(1-p^R)
~~~

The learning/search layer therefore no longer needs to rediscover basic
structural impossibility from scratch.

Stage 7 can focus on the remaining local coordination decision.

## Operator-neutral policy

The Stage 7A policy is:

~~~text
a_i,t = pi_theta(o_i,t)
~~~

There are no prompts, tokenizers, providers, language models, or semantic
message interpretation in this layer.

Any future operator class can implement the same observation/action interface.

## Observation schema

The policy-visible observation contains:

~~~text
local State:
  knowledge bitset
  sent-history bitset
  cursor

operator-local identity:
  operator index

time:
  current round

immutable environment metadata:
  population size N
  fact count F
  topology kind G
  redundancy R
  maximum local bandwidth B
  experiment seed
  local topology degree
~~~

It explicitly does not contain:

~~~text
collector knowledge
peer knowledge
global completion
global useful-information counts
global novelty state
future fault realization
global trajectory state
~~~

Thus pi_theta remains locally admissible.

## Compact theta

Stage 7A begins with four dimensions:

~~~text
theta = (n, e, r, u)
~~~

All are integer permille controls in [0,1000], except u must be at least 1.

### n — novelty bias

n rewards facts that are locally known but not present in the operator's
persistent sent bitset.

At n=0, unsent facts receive no ranking bonus.

At n=1000, the novelty bonus is large enough to dominate the normal local
ordering score for the current deterministic fact ceiling.

This is a preference, not global novelty: two operators can independently
consider the same fact novel.

### e — deterministic exploration

e blends two local ranks:

~~~text
cursor rank
Stage-5 seeded permutation rank
~~~

Interior action score begins from:

~~~text
(1000-e) * cursor_rank + e * seeded_rank
~~~

The seeded permutation is reconstructed exactly from local operator index,
round, experiment seed, and F.

No external randomness source is used.

### r — retry eligibility

While the operator still has locally unsent facts, a previously emitted fact is
eligible for reconsideration according to a deterministic hash gate with
threshold r.

~~~text
r=0:
  no previously sent fact is eligible while unsent local facts remain

r=1000:
  all previously sent facts remain eligible
~~~

Intermediate values produce deterministic retry diversity across
operator/round/fact coordinates.

### u — bandwidth utilization

The environment supplies maximum local bandwidth B.

The policy uses:

~~~text
B_theta = ceil(B * u / 1000)
~~~

clamped to:

~~~text
1 <= B_theta <= B
~~~

This lets Stage 7B test whether using less than the available local capacity can
improve total communication efficiency.

## Persistent local memory

For interior theta values, State.sent is persistent emission history.

The policy does not clear this history merely because every currently known
fact has been emitted. If a genuinely new fact arrives later, it is still
distinguishable from prior local emissions.

The exact novel_first control corner retains its historical Stage 5 reset
semantics because that corner delegates to the original implementation.

## Exact baseline corners

Three points are reserved as exact named controls:

~~~text
round_robin:
  n=0
  e=0
  r=1000
  u=1000

seeded:
  n=0
  e=1000
  r=1000
  u=1000

novel_first:
  n=1000
  e=0
  r=0
  u=1000
~~~

At these points pi_theta delegates directly to stage5a_scaling.decideLocal.

Whole-run Stage 7A execution similarly delegates to the frozen Stage 5A
simulator for exact corner configurations.

Therefore the named controls are not approximate target behaviors.

## Interior fact selection

Interior theta values use a deterministic bounded top-k selection.

For each locally known eligible fact:

~~~text
cursor_rank = cyclic distance from local cursor
seeded_rank = deterministic Stage-5 seeded permutation position

base_score =
  (1000-e) * cursor_rank
  + e * seeded_rank

if fact is locally unsent:
  score -= n * novelty_scale
~~~

Lower score is preferred.

A bounded max-heap retains the best B_theta candidates without sorting the full
fact set.

Tie breaking uses fact id.

This produces one compact fact-selection surface connecting:

~~~text
ordered retransmission
seeded exploration
novelty pressure
retry pressure
reduced bandwidth use
~~~

## Why recipient selection is not in theta yet

The Stage 5/6 fact-diffusion action contains a selected fact-set.

Transport then broadcasts that action to all current topology neighbors.

There is no recipient field in the local action algebra.

Adding a neighbor-selection weight now would therefore either be inert or
quietly change the transport model.

Stage 7A does neither.

Recipient/neighbor control should be introduced only alongside an explicit
addressable transport action in a later control-law extension.

## Objective vector

Stage 7A exposes:

~~~text
failure
rounds
communication units
duplicate deliveries
policy/computation calls
~~~

as a Pareto-style objective vector.

No single scalar J is frozen in Stage 7A.

This prevents arbitrary alpha/beta/gamma weights from becoming part of the
scientific result before Stage 7B compares Pareto structure.

The implementation provides weak and strict dominance helpers.

## Fixed probe profiles

Stage 7A defines six profiles:

~~~text
round_robin_corner
seeded_corner
novel_first_corner

soft_novel:
  n=500 e=0 r=250 u=1000

exploratory_novel:
  n=750 e=500 r=250 u=1000

lean_exploratory:
  n=750 e=250 r=0 u=500
~~~

The three interior profiles are probes only.

They are not claimed to be good policies and are not selected from data.

## Probe grid

The full Stage 7A probe is:

~~~text
profiles: 6
N:        {32,64}
F:        {32,128}
G:        {ring,grid}
R:        2
B:        {1,2,4}
seed:     {0,1,2}

total: 432 runs
~~~

This is intentionally much smaller than a Stage 7B search.

Its purposes are:

1. verify the parameter surface executes deterministically;
2. verify interior theta values can produce behavior distinct from all three
   named controls;
3. expose obvious pathological parameter semantics before optimization;
4. give Stage 7B a stable TSV schema.

It is not evidence that any interior profile is optimal.

## Validation gates

Run:

~~~sh
zig test src/root.zig
~~~

Then:

~~~sh
zig run src/stage7a_cli.zig -- validate
~~~

The CLI checks exact whole-run equivalence of all three control corners across:

~~~text
ring/grid
three deterministic seeds
~~~

for 18 baseline checks.

It separately reruns an interior profile twice across ring/grid and three seeds
for six deterministic-repeat checks.

Expected high-level result:

~~~text
baseline_corner_checks: 18
baseline_corner_mismatches: 0
interior_determinism_checks: 6
interior_determinism_mismatches: 0
~~~

Plan:

~~~sh
zig run src/stage7a_cli.zig -- plan
~~~

Smoke:

~~~sh
zig run -O ReleaseFast src/stage7a_cli.zig -- probe smoke \
  > trials/stage7a-smoke.tsv
~~~

Full probe:

~~~sh
zig run -O ReleaseFast src/stage7a_cli.zig -- probe full \
  > trials/stage7a-probe.tsv
~~~

The probe TSV records:

~~~text
profile/configuration
all four theta coordinates
success/rounds
collector initial/final knowledge
policy calls/actions
messages/communication units
useful and duplicate deliveries
useful-information efficiency
duplicate fraction
violations
~~~

## Stage 7A completion criterion

Stage 7A is complete when:

1. the authoritative Zig toolchain passes root tests;
2. all 18 named-policy control checks are exact;
3. all six deterministic interior-repeat checks match;
4. probe rows contain zero policy/action violations;
5. interior profiles produce at least some outcomes distinct from the named
   corners, proving the parameterization is not behaviorally degenerate.

Only then should Stage 7B freeze train/validation/hard-holdout worlds and begin
searching theta.

## Stage 7B boundary

Stage 7B, not this PR, should:

~~~text
freeze train/validation/hard holdouts
add structural/fault regime mixtures
choose a search strategy
evaluate Pareto fronts
compare discovered theta against all named controls
test unseen N/F/B/topology/fault regimes
~~~

Stage 6.1 structural hazard should be used as an external reachability
constraint/diagnostic rather than asking theta to solve impossible worlds.
