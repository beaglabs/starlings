# Stage 5C — Regime Boundaries and Saturation

Stage 5B showed that compact topology × policy laws are useful on held-out
configurations, but it also exposed two structured failures:

1. ring + novel_first extrapolates poorly from F<=512 to F=1024 even though it
   remains convergent;
2. complete graphs exhibit abrupt one-round saturation that a smooth power law
   models poorly.

Stage 5C treats those failures as experimental hypotheses rather than adding
more regression terms until the errors disappear.

## Hypothesis A — high-information regime boundary

At fixed population and redundancy, information volume and local bandwidth
may create distinct propagation regimes.

Canonical boundary experiment:

~~~text
N = 128
R = 2

F =
128, 192, 256, 320, 384, 448, 512,
640, 768, 896, 1024, 1280, 1536, 2048

B = 1, 2, 4

G =
ring
grid

Pi =
round_robin
seeded
novel_first

seed = 0, 1, 2
~~~

This is exactly 756 base configurations.

Each configuration is first evaluated at the Stage 5A resource horizon:

~~~text
H0 = 4096 rounds
~~~

If it is censored, the same deterministic initial condition is rerun from
round zero with:

~~~text
H1 = 16384 rounds
~~~

The rerun is diagnostic. The 4096 result remains the canonical bounded-resource
outcome.

This distinguishes:

~~~text
converged within Stage 5A horizon
delayed:       T_conv in (4096, 16384]
persistent:    T_conv > 16384
~~~

A 16384 result is never substituted into the Stage 5A dataset.

## Boundary coordinates

Every boundary row also records scaled candidate coordinates:

~~~text
q_FB      = F / B
q_FDB     = F D / B
q_FNB     = F / (N B)
q_FDNRB   = F D / (N R B)
~~~

The TSV stores each multiplied by 1000 using integer arithmetic.

These are descriptive coordinates, not preselected laws. Stage 5C reports
where censoring first appears under each representation.

Because N and R are fixed inside this sweep, not every candidate is independently
distinguishable within one topology. Cross-topology differences and the later
saturation experiment provide additional variation. Stage 5C must not claim a
dimensionless control parameter solely because one coordinate looks visually
compact.

## Boundary characterization

For every topology × policy × bandwidth group, the deterministic summary
reports:

~~~text
last F where every seed succeeds
first F where any seed is censored
first F where all seeds are censored
~~~

at both 4096 and 16384 rounds.

It also reports non-monotonicity: a later F returning to all-success after an
earlier censored F is explicit evidence against a simple scalar threshold.

A value of zero in a boundary column means no such boundary was observed in
the rows actually present for that group. The summary also reports
`max_observed_F`; only the canonical full dataset reaches F=2048 for every
topology/policy/bandwidth group.

## Hypothesis B — complete-graph one-round saturation

Stage 5B indicates that complete graphs behave qualitatively differently from
sparse graphs. Stage 5C directly measures the one-round threshold rather than
fitting a smooth approximation to it.

Canonical saturation experiment:

~~~text
N = 32, 64, 128, 256

F/N = 0.5, 1, 2, 4

R = 1, 2, 4, 8

Pi =
round_robin
seeded
novel_first

seed = 0, 1, 2
~~~

This yields 576 threshold configurations.

For round 1, `novel_first` is intentionally expected to match
`round_robin`: every operator begins with an empty `sent` set, so the
novelty policy's first emission reduces to the same round-robin selection.
Those duplicated threshold rows are retained as an explicit invariant/control,
not interpreted as independent policy evidence. Root tests require exact
one-round equivalence for representative configurations.

For each configuration Stage 5C finds:

~~~text
B* = minimum bandwidth that gives complete collector coverage after one round
~~~

## Exact one-round oracle

A full complete-graph round normally delivers every selected action to every
other operator, which is O(N^2) fanout.

For the one-round saturation question, the collector only needs the union of:

~~~text
collector initial knowledge
union of every operator's round-1 admissible emission
~~~

Stage 5C therefore adds a one-round complete-coverage oracle to the deterministic
Stage 5A substrate. It uses the exact same:

- initial placement;
- local policy decision;
- action validation;
- fact representation.

It skips only redundant recipient fanout that cannot affect whether the
collector has full coverage after that single round.

Root tests require the oracle's collector initial count, collector final count,
success state, and violations to match the full simulator at max_rounds=1.

## Saturation threshold search

For each N,F,R,policy,seed tuple, one-round success is searched over B in
[1,F].

The canonical policy implementations select nested prefixes as B increases,
so one-round coverage is expected to be monotone in B. The threshold result
records whether B*-1 also succeeded; any such case is a threshold minimality
failure and invalidates the result.

Stage 5C reports:

~~~text
B*
B*/F
N B*/F
N R B*/F
~~~

The final two quantities test simple normalized saturation-capacity hypotheses.

## Saturation characterization

For each policy × R × F/N group, the summary aggregates all population sizes
and seeds and reports:

~~~text
median B*
median N B*/F
min/max N B*/F
normalized spread of N B*/F
~~~

A low spread means the aggregate-capacity normalization collapses the
population-size dependence reasonably well.

The summary then pools redundancy values at each policy × F/N and compares:

~~~text
spread(N B*/F)
versus
spread(N R B*/F)
~~~

This tests whether explicitly incorporating initial redundancy improves or
worsens the collapse.

These are empirical threshold characterizations, not yet universal laws.

## Fact-capacity extension

Stage 5A originally fixed:

~~~text
max_facts = 1024
~~~

Stage 5C requires F beyond the failed F=1024 extrapolation and extends the
BitSet capacity to:

~~~text
max_facts = 2048
~~~

No transition rule, policy, placement rule, topology rule, or communication
accounting changes.

The root suite adds 1536/2048 bitset boundary tests and complete-oracle
equivalence tests.

Because this modifies a shared substrate constant, local validation should also
confirm the existing Stage 5A smoke dataset remains byte-identical:

~~~sh
zig run src/experiments/stage5/stage5a_cli.zig -- sweep smoke > /tmp/stage5a-smoke-stage5c.tsv

cmp trials/stage5a-smoke.tsv /tmp/stage5a-smoke-stage5c.tsv \
  && echo "Stage 5A smoke remains identical"
~~~

## Commands

~~~sh
zig test src/root.zig

zig run src/experiments/stage5/stage5c_cli.zig -- validate
zig run src/experiments/stage5/stage5c_cli.zig -- plan full

zig run src/experiments/stage5/stage5c_cli.zig -- boundary full \
  > trials/stage5c-boundary.tsv

zig run src/experiments/stage5/stage5c_cli.zig -- summarize-boundary \
  trials/stage5c-boundary.tsv

zig run src/experiments/stage5/stage5c_cli.zig -- saturation full \
  > trials/stage5c-saturation.tsv

zig run src/experiments/stage5/stage5c_cli.zig -- summarize-saturation \
  trials/stage5c-saturation.tsv
~~~

Smoke profiles are also available for fast local checks.

## Stage 5C gate

Stage 5C is complete when:

1. root tests pass on the authoritative Zig toolchain;
2. Stage 5A smoke output remains byte-identical after the 2048-fact extension;
3. Stage 5C validation reports zero violations and no saturation minimality
   failure;
4. the 756-row boundary dataset is complete and structurally valid;
5. the boundary summary explicitly separates <=4096, delayed, and >16384
   outcomes;
6. the 576-row saturation dataset is complete and structurally valid;
7. every B* is locally minimal;
8. the saturation summary quantifies normalized threshold spread;
9. any claimed transition or saturation law is limited to what these
   deterministic sweeps support.

After Stage 5C, the roadmap moves to controlled perturbation/robustness
experiments rather than further fitting on these same clean deterministic
populations.


## Canonical Stage 5C results

The authoritative local Zig 0.16 run produced complete, structurally valid
datasets.

~~~text
root tests: 123 passed

boundary rows: 756
boundary malformed rows: 0
boundary violation rows: 0
boundary SHA-256:
5fe94854ea42c80a11c743c40672fddfce1ab05f8d797eb65d1afa581c251c80

saturation rows: 576
saturation malformed rows: 0
saturation violation rows: 0
saturation threshold minimality failures: 0
saturation SHA-256:
d897ebc7fc8d3e1b724dd1e2d49bb43d7bf165cec1739eabdf29d9879142947b
~~~

### Boundary outcome classes

Of 756 boundary cases:

~~~text
censored at H=4096:            228
converged by H=16384:          152 of those 228
still censored at H=16384:      76 of those 228
~~~

Therefore two thirds of Stage-5A-horizon censoring in this sweep represents
delayed convergence rather than persistent censoring through the extended
resource envelope.

All reported topology/policy/bandwidth boundary sequences were monotone in the
sampled F grid at both horizons.

### Horizon-normalized information load

The boundary data suggests a compact empirical coordinate:

~~~text
lambda = F / (B H)
~~~

where H is the round horizon.

For ring + round_robin, the sampled all-seed transition is strikingly stable.

At H=4096:

~~~text
B=1: last all-success F=192   -> lambda=0.046875
     first censor    F=256   -> lambda=0.062500

B=2: last all-success F=384   -> lambda=0.046875
     first censor    F=448   -> lambda=0.0546875

B=4: last all-success F=768   -> lambda=0.046875
     first censor    F=896   -> lambda=0.0546875
~~~

At H=16384:

~~~text
B=1: last all-success F=768   -> lambda=0.046875
     first censor    F=896   -> lambda=0.0546875

B=2: last all-success F=1536  -> lambda=0.046875
     first censor    F=2048  -> lambda=0.062500
~~~

The B=4 extended-horizon boundary lies above the F=2048 experiment ceiling.

Within the tested N=128,R=2 ring regime this supports an empirical
round-robin load envelope approximately bracketed by:

~~~text
all-seed success: lambda <= 0.046875 on every resolved boundary
censoring onset:  lambda approximately 0.0547--0.0625
~~~

This is substantially more compact than separate F and B exponents and is
consistent with the Stage 5B result that ring round-robin convergence time
scales approximately linearly with F and inversely with B.

Ring + seeded shows a distinct, lower-throughput regime. Resolved boundaries
mostly place its censoring onset near:

~~~text
lambda approximately 0.0195--0.0234
~~~

Grid + seeded supports a substantially larger load envelope, with resolved
censoring onset around:

~~~text
lambda approximately 0.125
~~~

and grid + round-robin is larger again: its only resolved H=4096 B=1 boundary
is bracketed between lambda=0.3125 and 0.375.

These values are empirical regime boundaries for N=128,R=2. Stage 5C does not
yet establish invariance under population size or redundancy.

### Novel-first boundary result

No ring or grid novel-first case censored through:

~~~text
F = 2048
B = 1,2,4
H = 4096
~~~

or through the extended H=16384 diagnostic.

The most demanding observed B=1,H=4096 point has:

~~~text
lambda = 2048 / (1 * 4096) = 0.5
~~~

and still converges.

Therefore the Stage 5B F=1024 ring novel-first extrapolation failure was not a
convergence phase transition. It was a failure of the smooth fitted
convergence-time law to predict the magnitude of a still-convergent
high-information regime.

Within the Stage 5C envelope, local sent-history/novelty memory increases the
observed convergence load capacity by at least an order of magnitude relative
to ring seeded and by more than the resolved ring round-robin boundary.

### Complete-graph saturation

The one-round threshold experiment confirms that complete-graph saturation is
a coverage phenomenon rather than a single universal aggregate-capacity
threshold.

For fixed policy, redundancy, and F/N, the normalized quantity:

~~~text
N B* / F
~~~

often has modest spread across N and seed, including several zero-spread
groups. This supports it as a useful first-order population-size
normalization.

However it is not universal across redundancy or information density.
For round-robin/novel-first, for example, median N B*/F at F/N=4 rises from:

~~~text
R=1: 2.375
R=2: 3.125
R=4: 4.250
R=8: 7.750
~~~

Thus increasing initial redundancy does not simply divide the bandwidth
needed for one-round coverage.

The naive multiplicative normalization:

~~~text
N R B* / F
~~~

is strongly rejected as a cross-redundancy collapse. When redundancy values
are pooled, its normalized spread is much larger than the spread of N B*/F
for every reported policy/F-N group.

This indicates that redundancy changes emission overlap and local knowledge
structure; its effect cannot be represented as independent linear capacity.

### Seeded first-round coverage

Round-robin and novel-first are exactly equivalent in round 1 by construction,
so their saturation thresholds match.

Seeded selection differs because each operator uses an operator/round/seed
dependent traversal. At higher redundancy it can require substantially less
normalized aggregate bandwidth than round-robin.

Examples at F/N=4:

~~~text
R=8:
round_robin / novel_first median N B*/F = 7.750
seeded                         median N B*/F = 4.375
~~~

and at F/N=2,R=8:

~~~text
round_robin / novel_first median N B*/F = 7.250
seeded                         median N B*/F = 4.500
~~~

This is evidence that one-round saturation depends on diversity/overlap of
local emissions, not merely the number of initially replicated fact copies.

### Stage 5C conclusion

The canonical Stage 5C result supports two distinct mathematical structures:

1. Sparse-graph convergence boundaries are well described, within fixed
   N,R, by a topology/policy-specific horizon-normalized information load
   F/(B H).
2. Complete-graph one-round saturation is a set-coverage threshold whose
   population dependence is partially normalized by N B*/F, but whose
   redundancy dependence is controlled by emission overlap rather than a
   simple multiplicative R factor.

The next stage should therefore perturb these identified control structures
rather than fit additional smooth laws to the same deterministic data.
