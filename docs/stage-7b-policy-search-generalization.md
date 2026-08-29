# Stage 7B — Policy Search and Generalization

Stage 7B is the optimization stage for the compact policy introduced in Stage
7A.

It does not change the local observation schema, action algebra, deterministic
policy semantics, or exact named control corners.

The question is:

> Can a compact theta selected only on small clean populations generalize to
> unseen population size, information density, redundancy, bandwidth, and
> topology while improving the feasibility/resource Pareto frontier over the
> named policies?

## Frozen Stage 7A policy

Stage 7B searches:

~~~text
theta = (n,e,r,u)
~~~

where:

~~~text
n = local novelty bias
e = cursor-order <-> deterministic seeded-order exploration
r = retry eligibility while unsent local facts remain
u = bandwidth utilization
~~~

The exact controls remain:

~~~text
round_robin
seeded
novel_first
~~~

and are always retained for diagnostics and hard-holdout comparison.

## Search strategy

Stage 7B uses a deterministic space-filling candidate set rather than a huge
Cartesian grid or a learned black-box optimizer.

The candidate set is frozen before any experiment executes.

### Fixed candidates

The first six candidates are the Stage 7A probe profiles:

~~~text
round_robin_corner
seeded_corner
novel_first_corner
soft_novel
exploratory_novel
lean_exploratory
~~~

### Space-filling candidates

An additional 128 candidates use deterministic stratification across all four
dimensions.

Each dimension visits every one of 128 strata exactly once under a distinct
coprime permutation.

~~~text
n in [0,1000]
e in [0,1000]
r in [0,1000]
u in [250,1000]
~~~

The resulting canonical search contains:

~~~text
134 unique candidates
~~~

There is no runtime entropy in candidate generation.

## Why u starts at 250 for space-filling candidates

Stage 7A already contains exact u=1000 controls.

The search allows a policy to use less capacity, but extremely tiny u values
would collapse many different configurations onto effective bandwidth 1 and
waste search resolution.

A floor of 250 preserves substantial capacity variation while keeping the
search focused on meaningful bandwidth-control behavior.

The exact fixed profiles remain outside this restriction where applicable.

## Training worlds

Training uses only:

~~~text
N={32,64}
F/N={1,2}
G={ring,grid}
R=2
B={1,2,4}
seed={0,1}
H=2048
~~~

Therefore:

~~~text
24 structural configurations
2 deterministic seeds
48 worlds per candidate
134 candidates
6432 exact training runs
~~~

The search cannot see any hard-holdout result during selection.

## Feasibility-first Pareto selection

A standard unconstrained Pareto frontier would be scientifically wrong here.

For example:

~~~text
policy A:
  fails every run
  sends zero bytes

policy B:
  succeeds every run
  sends useful state
~~~

If failure were merely another tradeable objective, A could remain
Pareto-optimal because it is cheaper.

Stage 7B therefore uses constrained selection.

For every selection split:

~~~text
1. find the minimum failure count across eligible candidates
2. discard candidates with more failures
3. compute the resource Pareto frontier among equally feasible candidates
~~~

Resource dimensions are minimized independently:

~~~text
sum of rounds
sum of communication units
sum of duplicate deliveries
sum of policy/computation calls
~~~

No scalar alpha/beta/gamma weighting is introduced.

## Validation

Only the training frontier proceeds to policy selection on validation.

The three exact named controls are also evaluated even when they are not on the
training frontier, but controls outside the training frontier are diagnostic
only and cannot re-enter selection.

Validation uses:

~~~text
N={32,64}
F/N={1,2}
G={ring,grid}
R=2
B={1,2,4}
seed=2
H=2048

24 worlds per evaluated candidate
~~~

A second feasibility-first Pareto frontier is computed using only the
training-frontier candidates.

This produces the frozen validation-selected frontier.

## Hard holdouts

Only:

~~~text
validation-selected frontier
+
round_robin
seeded
novel_first
~~~

is evaluated on the hard sets.

Hard results are never used to select theta.

### Population extrapolation

~~~text
N=128
F/N={1,2}
G={ring,grid}
R=2
B={1,2,4}
seed={0,1,2}

36 worlds
~~~

### Density extrapolation

~~~text
N={32,64}
F/N=4
G={ring,grid}
R=2
B={1,2,4}
seed={0,1,2}

36 worlds
~~~

### Redundancy extrapolation

~~~text
N={32,64}
F/N={1,2}
G={ring,grid}
R=4
B={1,2,4}
seed={0,1,2}

72 worlds
~~~

### Bandwidth extrapolation

~~~text
N={32,64}
F/N={1,2}
G={ring,grid}
R=2
B=8
seed={0,1,2}

24 worlds
~~~

### Topology extrapolation

The complete graph is absent from training and validation.

~~~text
N={32,64}
F/N={1,2}
G=complete
R=2
B={1,2,4}
seed={0,1,2}

36 worlds
~~~

This is a strong regime shift because complete-graph communication/saturation
behavior was qualitatively different in Stage 5C.

### Compound extrapolation

The compound set leaves the training box on several axes simultaneously:

~~~text
N=128
F=512
F/N=4
R=4
B=8
G={ring,grid,complete}
seed={0,1,2}

9 worlds
~~~

This is not intended to estimate a smooth average. It is a stress test of
whether the selected local control law catastrophically depends on the small
training regime.

## Why Stage 7B does not optimize against Stage 6 faults

Stage 6 and Stage 6.1 already established:

~~~text
dynamical failure under transient perturbation
structural failure under topology damage
redundancy-controlled reachability
h = -M log(1-p^R)
~~~

Feeding those same deterministic perturbation worlds into the theta optimizer
would blur a useful scientific distinction:

~~~text
clean coordination law
versus
robustness/transfer under new execution conditions
~~~

Stage 7B therefore selects theta on clean coordination dynamics.

The Stage 6 results remain external structural evidence and later robustness
tests.

Stage 7C is planned as the first deterministic asynchronous transfer stage
in Zig, where the selected theta can be tested unchanged under:

~~~text
independent local clocks
seeded latency and jitter
loss and duplication
delivery reordering
partitions and reconnection
stale local views
crash and restart
~~~

Every delivery schedule must be replayable. Optional Stage 7C fine-tuning can
then measure the synchronous-to-asynchronous transfer gap rather than allowing
Stage 7B to pre-adapt to those effects.

## Deterministic report

Run:

~~~sh
zig run -O ReleaseFast src/experiments/stage7/stage7b_cli.zig -- search \
  > trials/stage7b-search.txt
~~~

Progress goes to stderr.

The report records:

~~~text
candidate count
training minimum failures
training Pareto frontier
validation evaluations
validation-selected frontier

then, for selected frontier + named controls:
  population holdout
  density holdout
  redundancy holdout
  bandwidth holdout
  topology holdout
  compound holdout
~~~

Every row includes:

~~~text
candidate id/source/label
n/e/r/u
runs
failures
round sum
communication sum
duplicate sum
computation sum
useful-per-1000
duplicate-permille
violations
~~~

## Validation commands

Because PR #27 is the Stage 7A dependency, Stage 7B is intentionally stacked
until Stage 7A is merged.

Run on the Stage 7B branch:

~~~sh
zig test src/root.zig

zig run src/experiments/stage7/stage7a_cli.zig -- validate
zig run src/experiments/stage7/stage7b_cli.zig -- validate
zig run src/experiments/stage7/stage7b_cli.zig -- plan
~~~

Expected Stage 7B shape:

~~~text
candidate_count: 134
expected_candidate_count: 134
invalid_theta: 0
duplicate_theta: 0
exact_control_prefix: yes

worlds_training: 48
worlds_validation: 24
worlds_population_N_128: 36
worlds_density_F_over_N_4: 36
worlds_redundancy_R_4: 72
worlds_bandwidth_B_8: 24
worlds_topology_complete: 36
worlds_compound: 9
~~~

Only after these gates pass should the full search be run.

## Stage 7B completion criterion

Stage 7B is complete when:

1. Stage 7A remains regression-clean on the authoritative Zig toolchain;
2. all 134 candidate theta values are unique and valid;
3. search and holdout world counts match the frozen design;
4. all evaluated policy actions report zero violations;
5. the validation-selected frontier is non-empty;
6. hard-holdout behavior is compared directly against all three named controls;
7. no scientific claim is made from the hard sets until after selection is
   frozen.

A successful Stage 7B result would be evidence that a compact local control law
selected on small deterministic worlds transfers across unseen collective
regimes.

A negative result is also useful: if the named controls remain on every hard
frontier or selected interior theta values collapse under extrapolation, then
the four-dimensional Stage 7A parameterization is insufficient and should be
extended before asynchronous transfer.


## Canonical Stage 7B search result

Authoritative local execution passed all pre-search gates:

~~~text
zig test src/root.zig:
  All 152 tests passed

Stage 7A regression validation:
  baseline corner checks: 18
  mismatches: 0
  interior determinism checks: 6
  mismatches: 0

Stage 7B candidate audit:
  candidates: 134
  invalid theta: 0
  duplicate theta: 0
  exact control prefix: yes
~~~

The full search completed all training, validation, and hard-holdout phases with:

~~~text
total policy violations: 0
~~~

The canonical report file hash should be recorded separately after the local
report is hashed.

### Training selection

All 134 candidates were evaluated on 48 frozen training worlds.

~~~text
minimum failures: 0
training Pareto frontier: 10 candidates
~~~

Every training-frontier candidate was an interior Latin-hypercube candidate.
None of the three exact named controls remained on the training resource
frontier.

### Validation selection

The ten training-frontier candidates plus the three named controls were
evaluated on the untouched seed-2 validation worlds.

~~~text
validation candidates evaluated: 13
minimum failures: 0
validation Pareto frontier: 3 candidates
~~~

The validation-selected frontier is:

~~~text
id 37:
  theta = (n=244, e=94, r=15, u=958)
  failures = 0
  rounds sum = 1046
  communication = 258389
  duplicates = 170485
  computation = 55936

id 51:
  theta = (n=354, e=141, r=0, u=994)
  failures = 0
  rounds sum = 1054
  communication = 255319
  duplicates = 167211
  computation = 56576

id 93:
  theta = (n=685, e=283, r=960, u=344)
  failures = 0
  rounds sum = 1435
  communication = 250805
  duplicates = 162945
  computation = 76704
~~~

The three points expose two qualitatively different control regimes:

~~~text
37 / 51:
  low exploration
  low or zero retry
  near-full bandwidth
  fast convergence

93:
  stronger novelty
  high retry eligibility
  much lower bandwidth utilization
  lower communication/duplicates
  slower convergence and more computation
~~~

Thus Stage 7B does not support one universal optimal theta. It supports a
compact Pareto family.

### Validation comparison against named controls

The strongest named feasible control on validation is novel-first:

~~~text
novel-first:
  failures = 0
  rounds sum = 1691
  communication = 400022
  duplicates = 313000
  computation = 97344
~~~

Every selected interior theta strictly dominates novel-first on all four
resource dimensions at equal zero failures.

For example id 51 reduces relative to novel-first:

~~~text
round sum:        ~37.7%
communication:    ~36.2%
duplicates:       ~46.6%
computation:      ~41.9%
~~~

Round-robin also has zero validation failures but substantially higher resource
cost. Seeded is not feasibility-competitive on validation.

This is the first Stage 7 evidence that a searched compact local policy can
strictly dominate the previously handcrafted controls on unseen deterministic
worlds.

### Population extrapolation: N=128

The selected candidates remain feasible:

~~~text
id 37: failures 0
id 51: failures 0
id 93: failures 0
~~~

Round-robin has 3 failures and seeded has 9. Novel-first remains feasible.

Id 51 versus novel-first:

~~~text
round sum:
  4325 vs 18545
  ~76.7% lower

communication:
  2592088 vs 8522249
  ~69.6% lower

duplicates:
  1722158 vs 7653696
  ~77.5% lower

computation:
  553600 vs 2373760
  ~76.7% lower
~~~

Id 51 also strictly dominates id 37 on this holdout, while id 93 trades more
rounds/computation for slightly lower communication and duplicate cost.

### Density extrapolation: F/N=4

All three selected candidates remain feasible.

Id 51 versus novel-first:

~~~text
round sum:       ~18.0% lower
communication:   ~18.9% lower
duplicates:      ~26.5% lower
computation:     ~20.4% lower
~~~

Id 93 uses still less communication but sacrifices convergence/computation
cost, preserving the Pareto tradeoff.

### Redundancy extrapolation: R=4

All selected candidates and all named controls remain feasible.

Id 51 versus novel-first:

~~~text
round sum:       ~44.7% lower
communication:   ~42.8% lower
duplicates:      ~52.5% lower
computation:     ~47.8% lower
~~~

The searched policy therefore transfers strongly to unseen redundancy.

### Bandwidth extrapolation: B=8

All selected candidates remain feasible.

Id 51 versus novel-first:

~~~text
round sum:       ~20.5% lower
communication:   ~30.2% lower
duplicates:      ~38.9% lower
computation:     ~23.6% lower
~~~

Id 93 again chooses the lower-communication/slower branch of the frontier.

### Complete-topology extrapolation

This is the important exception to the sparse-topology wins.

The exact round-robin and novel-first controls are effectively identical on the
reported aggregate complete-graph worlds.

Id 51 remains feasible and approximately matches the controls:

~~~text
round sum:
  id 51 = 1098
  controls = 1119

communication:
  id 51 = 4966877
  controls = 4959421

duplicates:
  id 51 = 4834037
  controls = 4826365

computation:
  id 51 = 59360
  controls = 59808
~~~

So id 51 trades a small convergence/computation improvement for a very small
communication increase.

The complete topology does not show the large dominance seen on ring/grid.
This is consistent with Stage 5C's finding that complete connectivity is a
qualitatively different saturation regime.

### Compound extrapolation

The compound holdout simultaneously uses:

~~~text
N = 128
F = 512
F/N = 4
R = 4
B = 8
G in {ring,grid,complete}
~~~

All selected candidates remain feasible.

Relative to novel-first, id 51 shows:

~~~text
round sum:
  606 vs 1567
  ~61.3% lower

communication:
  17825187 vs 18052348
  ~1.3% lower

duplicates:
  17253904 vs 17481377
  ~1.3% lower

computation:
  77568 vs 200576
  ~61.3% lower
~~~

Thus the fast interior policy transfers to simultaneous multi-axis
extrapolation without losing feasibility.

Its communication advantage largely disappears because the complete-graph
component dominates byte volume, but its convergence/computation advantage
remains substantial.

### Stage 7B conclusion

Stage 7B validates the four-dimensional Stage 7A parameterization as
behaviorally useful within the tested deterministic envelope.

The central result is:

~~~text
a compact searched local policy selected only on small ring/grid populations
can strictly dominate the handcrafted policies on held-out validation and
transfer strongly across unseen population size, information density,
redundancy, and bandwidth.
~~~

The result is not a single universal theta.

Instead the validation data exposes a small Pareto family consisting of:

~~~text
fast / low-retry / near-full-bandwidth policies
versus
lower-bandwidth / higher-retry policies with lower byte cost
~~~

Complete connectivity remains a distinct regime where the searched sparse-
topology policy provides approximately parity rather than broad dominance.

This reinforces the broader Starlings finding that policy and topology interact
structurally rather than through one universal scalar optimum.

Stage 7C should transfer the frozen validation-selected theta values unchanged
into deterministic asynchronous Zig execution before any transfer fine-tuning.
