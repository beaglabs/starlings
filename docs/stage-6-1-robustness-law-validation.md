# Stage 6.1 — Robustness Law Validation

Stage 6 discovered a sharp redundancy-dependent reachability transition in the
complete-graph one-round coverage experiment.

Stage 6.1 asks one narrow question:

> Is that transition captured by a compact mechanistic law that predicts
> configurations deliberately hidden before fitting?

This stage does not generate another perturbation sweep and does not add a
large generic regression family.

## Canonical input

Stage 6.1 consumes only the frozen Stage 6 coverage dataset:

~~~text
rows: 2592
malformed rows: 0
violation rows: 0
severity-zero anomalies: 0
SHA-256:
86f15137ee2c3d1b066daeb6e61fa9f052ddf55cb5eb4f4c4f44aed2a11bdb04
~~~

The CLI refuses to fit a non-canonical dataset.

## De-duplicating policy-invariant evidence

Stage 6 established that round-robin and seeded have identical one-round
reachability when evaluated at full local bandwidth B=F.

That equality is expected because both policies emit the entire local
knowledge set at B=F.

The two policy rows therefore are not independent evidence for the reachability
law.

Before fitting, Stage 6.1 requires every round-robin row to have exactly one
seeded partner with the same:

~~~text
N
F
F/N
R
trial seed
perturbation mechanism
perturbation severity
perturbation seed
~~~

and verifies equality of:

~~~text
reachable
collector initial knowledge K0
maximum full-bandwidth collector coverage
~~~

Only the round-robin representative is then retained for law validation.

Canonical representative rows:

~~~text
1296
~~~

Policy remains important for B* inflation, but B* inflation is not the Stage
6.1 target.

## Mechanistic exposure coordinate

The original Stage 6 hypothesis used:

~~~text
P(reachable) ~ exp(-F p^R)
~~~

where:

~~~text
F = total required facts
R = exact copies per fact
p = transient fault probability/severity
~~~

However, facts already present at the collector cannot be lost by omission of
remote senders or by sender-to-collector message drops.

Define:

~~~text
K0 = facts initially known by the collector
M  = F - K0
~~~

Only M missing facts are exposed.

For a missing fact with R distinct source copies, the independent-source null
gives:

~~~text
P(all R source routes lost) = p^R
~~~

and therefore:

~~~text
P(all M missing facts retain at least one route)
    = (1 - p^R)^M
~~~

Define the exact missing-fact hazard:

~~~text
h = -M log(1 - p^R)
~~~

so the parameter-free law becomes:

~~~text
P(reachable) = exp(-h)
~~~

The small-hazard approximation is:

~~~text
h ~ M p^R
P(reachable) ~ exp(-M p^R)
~~~

## Candidate law family

Stage 6.1 deliberately limits the family to four models.

### M0 — original naive approximation

~~~text
P = exp(-F p^R)
~~~

Parameters: 0.

### M1 — exact missing-fact independence law

~~~text
M = F - K0
h = -M log(1 - p^R)
P = exp(-h)
~~~

Parameters: 0.

This is the primary mechanistic candidate.

### M2 — one global hazard scale

~~~text
P = exp(-c h)
~~~

Parameters: 1.

This tests whether correlations and finite-population effects can be absorbed
into one global effective-hazard multiplier.

### M3 — one scale per fault mechanism

~~~text
P = exp(-c_k h)
~~~

Parameters: 2 total:

~~~text
c_operator_omission
c_message_drop
~~~

This tests whether the different correlation structures of operator omission
and directed message drop require separate effective hazards.

No polynomial feature expansion, generic logistic interaction model, or
policy term is included.

## Fitting

The scalar corrections are fitted by deterministic Bernoulli maximum
likelihood.

The optimization is one-dimensional in log(c), preserving:

~~~text
c > 0
~~~

and uses a fixed deterministic golden-section search.

M0 and M1 are parameter-free and never fitted.

## Hard holdouts

The non-holdout training box is fixed before fitting:

~~~text
N in {64,128}
F/N in {1,2}
R in {1,4}
p <= 0.4
~~~

Hard evaluation is factorial.

A row outside the training box on exactly one axis enters the corresponding
single-axis extrapolation set:

~~~text
population extrapolation:
  N = 256
  all other coordinates remain inside the training box

density extrapolation:
  F/N = 4
  all other coordinates remain inside the training box

redundancy extrapolation:
  R = 8
  all other coordinates remain inside the training box

severity extrapolation:
  p = 0.5
  all other coordinates remain inside the training box
~~~

Rows outside the training box on two or more axes enter a separate:

~~~text
compound extrapolation
~~~

set.

This makes the four single-axis scores interpretable while preserving a hard
test of simultaneous extrapolation.

The deterministic split is:

~~~text
representatives: 1296

non-holdout: 336
  candidate fit seeds 0-1: 224
  candidate validation seed 2: 112

single-axis hard holdouts:
  N=256: 168
  F/N=4: 168
  R=8: 168
  p=0.5: 48

compound extrapolation: 408
~~~

## Model selection discipline

Candidate scalar parameters are fitted using only non-holdout seeds 0 and 1.

Seed 2 in the same non-holdout region reports candidate validation:

~~~text
Brier score
Bernoulli log loss
0.5-threshold accuracy
observed reachability
mean predicted reachability
~~~

The validation Brier winner is reported, but Stage 6.1 does not automatically
declare a more complex law scientifically necessary solely because its score
is numerically lower.

After validation, scalar corrections are refitted using all non-holdout seeds
0-2.

Every model is then evaluated unchanged on each hard holdout.

## Hazard-collapse diagnostic

The CLI bins all 1296 representative rows directly by:

~~~text
h = -M log(1 - p^R)
~~~

and reports:

~~~text
hazard interval
rows
observed reachability
parameter-free M1 predicted reachability
~~~

If M1 is the correct structural coordinate, observations from different N,
F/N, R, and perturbation mechanisms should approximately collapse onto:

~~~text
P = exp(-h)
~~~

without regime-specific fitting.

## Interpretation rules

Possible outcomes:

### M1 predicts hard holdouts well

Then the Stage 6 reachability transition has a compact, operator-neutral
missing-fact hazard law.

The extra fitted scales should not be promoted unless they materially improve
unseen predictions.

### M2 materially improves M1

Then the mechanistic coordinate is likely right, but source/fact dependencies
renormalize the hazard by an approximately global constant.

### M3 materially improves M2

Then nominally equal p values have different effective hazard under operator
omission versus directed message drop.

### All compact laws fail hard extrapolation

Then F, R, p, and K0 are insufficient. Stage 6.1 should identify the missing
structural coordinate before Stage 7 rather than hide the failure behind a
large flexible model.

## Validation command

~~~sh
zig test src/root.zig

zig run -O ReleaseFast src/stage6_1_cli.zig -- \
  trials/stage6-coverage.tsv
~~~

Expected canonical audit:

~~~text
canonical_dataset: yes
rows: 2592
malformed_rows: 0
violation_rows: 0
severity0_anomalies: 0
representative_rows_after_policy_dedup: 1296
policy_invariant_pairs: 1296
policy_invariant_missing_pairs: 0
policy_invariant_mismatches: 0
~~~

Stage 6.1 should be interpreted only after the authoritative local Zig 0.16
run produces the validation and hard-holdout scores.
