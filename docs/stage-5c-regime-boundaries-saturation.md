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

A value of zero in a boundary column means no such boundary was observed
through F=2048.

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
zig run src/stage5a_cli.zig -- sweep smoke > /tmp/stage5a-smoke-stage5c.tsv

cmp trials/stage5a-smoke.tsv /tmp/stage5a-smoke-stage5c.tsv \
  && echo "Stage 5A smoke remains identical"
~~~

## Commands

~~~sh
zig test src/root.zig

zig run src/stage5c_cli.zig -- validate
zig run src/stage5c_cli.zig -- plan full

zig run src/stage5c_cli.zig -- boundary full \
  > trials/stage5c-boundary.tsv

zig run src/stage5c_cli.zig -- summarize-boundary \
  trials/stage5c-boundary.tsv

zig run src/stage5c_cli.zig -- saturation full \
  > trials/stage5c-saturation.tsv

zig run src/stage5c_cli.zig -- summarize-saturation \
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
