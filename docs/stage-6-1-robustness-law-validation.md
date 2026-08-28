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

For the one-round collector-only reachability target, operator omission and
sender-to-collector message drop are distributionally equivalent: either the
sender's full contribution is available to the collector or it is not. The two
perturbation labels use different deterministic hash domains, so this model is
retained only as a **fault-world/domain sensitivity diagnostic**. A persistent
difference in fitted c_k must not be interpreted as distinct coverage physics
without new independent perturbation worlds.

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

Treat the improvement as evidence that the finite deterministic perturbation
worlds differ by fault-domain label. It is not, by itself, evidence that
operator omission and sender-to-collector drop have different one-round
coverage physics.

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


## Canonical Stage 6.1 results

Authoritative local evaluation used the frozen Stage 6 coverage dataset and
passed the canonical input/policy-invariant audit:

~~~text
dataset SHA-256:
86f15137ee2c3d1b066daeb6e61fa9f052ddf55cb5eb4f4c4f44aed2a11bdb04

rows: 2592
malformed rows: 0
violation rows: 0
severity-zero anomalies: 0

representative rows after policy de-duplication: 1296
policy-invariant pairs: 1296
missing policy pairs: 0
policy-invariant mismatches: 0
~~~

### Seed-2 validation

The hard holdouts remained unseen while the scalar corrections were fitted on
non-holdout seeds 0-1.

~~~text
law                     params   Brier       log-loss    accuracy
naive_F_exp               0     0.031485    0.101848    95.54%
missing_exact              0     0.032672    0.105357    95.54%
global_scaled_exact        1     0.043141    0.139429    93.75%
mechanism_scaled_exact     2     0.043995    0.146544    94.64%
~~~

Observed validation reachability was 41.96%.

~~~text
naive_F_exp predicted:       44.94%
missing_exact predicted:     45.23%
global_scaled predicted:     48.18%
mechanism_scaled predicted:  48.04%
~~~

The validation Brier winner was the zero-parameter naive law. Both
zero-parameter laws outperformed the fitted corrections.

This is important: the Stage 6 transition does not require a fitted scale to
predict held-out deterministic worlds.

### Refit scalar diagnostics

Refitting the optional scalar corrections on all non-holdout seeds produced:

~~~text
global c:             0.824710
operator-omission c:  1.230805
message-drop c:       0.615599
~~~

For this one-round collector-only target, omission and sender-to-collector
message loss are distributionally equivalent Bernoulli sender-contribution
events. The difference between the mechanism-specific coefficients is therefore
a finite deterministic fault-domain diagnostic, not evidence of two distinct
coverage laws.

### Single-axis hard extrapolation

#### Population: N=256

~~~text
law                     Brier       accuracy   observed   predicted
naive_F_exp             0.022132     96.43%     40.48%     39.89%
missing_exact           0.022099     96.43%     40.48%     39.95%
global_scaled_exact     0.022055     96.43%     40.48%     40.70%
mechanism_scaled_exact  0.020606     97.02%     40.48%     40.56%
~~~

All compact laws extrapolate well to unseen population size.

#### Information density: F/N=4

~~~text
law                     Brier       accuracy   observed   predicted
naive_F_exp             0.018923     97.02%     38.69%     39.89%
missing_exact           0.019504     97.02%     38.69%     40.11%
global_scaled_exact     0.021690     95.83%     38.69%     40.87%
mechanism_scaled_exact  0.026028     95.24%     38.69%     40.73%
~~~

The zero-parameter laws are strongest on unseen density.

#### Redundancy: R=8

Training saw only R={1,4}. The R=8 holdout contained 167 reachable rows and
1 unreachable row.

~~~text
law                     Brier       accuracy   observed   predicted
naive_F_exp             0.006385     99.40%     99.40%     98.59%
missing_exact           0.006296     99.40%     99.40%     98.70%
global_scaled_exact     0.006077     99.40%     99.40%     98.92%
mechanism_scaled_exact  0.006536     99.40%     99.40%     98.81%
~~~

Classification accuracy alone is weak evidence in this highly imbalanced
holdout, but the probability calibration is also close. The p^R structure
therefore extrapolates successfully to an unseen redundancy regime.

#### Severity: p=0.5

The severity holdout contained only 2 reachable rows out of 48.

~~~text
law                     Brier       log-loss    accuracy   predicted
naive_F_exp             0.040931    0.252002    95.83%      0.24%
missing_exact           0.040788    0.245808    95.83%      0.29%
global_scaled_exact     0.040036    0.205718    95.83%      0.58%
mechanism_scaled_exact  0.037932    0.155539    95.83%      0.77%
~~~

Observed reachability was 4.17%.

All models correctly identify the high-severity regime as overwhelmingly
unreachable, but every compact law under-predicts the rare reachable tail.
This is the clearest remaining calibration miss.

### Compound extrapolation

The compound holdout contains 408 worlds outside the training box on two or
more axes simultaneously.

~~~text
law                     Brier       log-loss    accuracy   observed   predicted
naive_F_exp             0.051488    0.150701    92.16%     62.25%     61.67%
missing_exact           0.051507    0.150784    92.16%     62.25%     62.07%
global_scaled_exact     0.051326    0.150972    92.16%     62.25%     63.23%
mechanism_scaled_exact  0.050295    0.149588    92.65%     62.25%     62.85%
~~~

This is the strongest Stage 6.1 result.

The two zero-parameter laws predict compound extrapolation with approximately
0.0515 Brier, 92.2% classification accuracy, and aggregate probability
calibration within 0.6 percentage points of the observed reachability rate.

The fitted corrections improve Brier only marginally and do not justify
promoting extra parameters as part of the structural law.

### Parameter-free hazard collapse

Binning all 1296 representative rows by:

~~~text
h = -M log(1 - p^R)
~~~

produces a strong monotone collapse:

~~~text
h interval       observed reachable   M1 predicted
0 - 0.05              100.0%             99.65%
0.05 - 0.10            86.67%            93.03%
0.10 - 0.25            78.57%            84.65%
0.25 - 0.50            64.58%            67.17%
0.50 - 1.0             43.75%            42.08%
1.0 - 2.0              25.00%            17.73%
2.0 - 4.0              12.96%             5.80%
4.0 - 8.0               1.28%             0.39%
>= 8                    0.00%             approximately 0
~~~

The coordinate orders the phase transition correctly across population size,
density, redundancy, severity, and fault-domain labels.

The parameter-free exact probability is not perfectly calibrated in the
intermediate/high-hazard tail: it under-predicts rare successful worlds for
roughly h>1. Therefore Stage 6.1 should distinguish:

~~~text
validated structural coordinate:
  h = -M log(1 - p^R)
  approximately M p^R at low hazard

compact probability approximation:
  P(reachable) approximately exp(-h)
~~~

from the stronger and unsupported statement that P=exp(-h) is an exact law.

## Stage 6.1 conclusion

Stage 6.1 validates a compact predictive robustness coordinate within the
tested deterministic one-round coverage envelope.

The central empirical result is:

~~~text
reachability is primarily organized by a missing-information hazard whose
leading structure is M p^R (or exactly -M log(1-p^R) under the independence
null).
~~~

This coordinate predicts unseen:

~~~text
population size
information density
redundancy
fault severity
simultaneous multi-axis extrapolation
~~~

without fitted parameters.

The optional fitted hazard scales do not consistently improve unseen
prediction and should not be part of the primary Starlings robustness law.

The current evidence therefore supports:

~~~text
h = -M log(1-p^R)

P(reachable) approximately exp(-h)
~~~

as a compact operator-neutral structural robustness law, with an explicit
caveat that rare successful worlds at high hazard are under-predicted.

Stage 7 can now treat structural reachability as an external constraint and
focus learned coordination parameter theta on dynamical questions: trajectory
selection, retransmission, novelty, neighbor choice, bandwidth allocation, and
stopping.
