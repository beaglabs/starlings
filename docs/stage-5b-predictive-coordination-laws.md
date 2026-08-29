# Stage 5B — Predictive Coordination Laws

Stage 5B moves Starlings from descriptive scaling experiments to predictive
mathematical tests.

The question is not whether a curve can fit the Stage 5A dataset. The question
is whether compact laws chosen without access to designated hard cases can
predict those unseen population regimes.

## Research question

> Can population-level convergence, convergence time, communication cost, and
> useful-information efficiency be predicted from compact graph/resource
> variables and local policy class on configurations withheld before fitting?

A negative answer is scientifically meaningful. In particular, if no pooled
law generalizes while regime-specific laws do, that is evidence that the local
control law changes the class of global dynamics rather than merely shifting a
coefficient.

## Canonical input

Stage 5B accepts only the frozen Stage 5A canonical TSV:

~~~text
rows: 918
sha256: 92279da22ded432f942b24f96f4f4658ee49174ba45c66239537744bee988fc6
~~~

The Stage 5A.2 parser verifies this identity before fitting.

## Outcomes

Stage 5B separates bounded-horizon convergence from conditional performance.

### Convergence

All rows are used for:

~~~text
Y_conv = 1 if T_conv <= 4096
Y_conv = 0 if the run is right-censored at 4096
~~~

The model predicts:

~~~text
P(T_conv <= 4096)
~~~

Candidate selection and evaluation use Brier score. Accuracy and censored-run
recall are reported as diagnostics.

### Convergence time

Only successful rows are used:

~~~text
Y_T = log(T_conv)
~~~

A censored row is not represented as T=4096.

### Communication

Only successful rows are used:

~~~text
Y_C = log(C_comm)
~~~

### Useful-information efficiency

For successful rows:

~~~text
eta = useful_deliveries / communication_units
Y_eta = logit(eta)
~~~

Predictions are transformed back to useful deliveries per 1000 communication
units for interpretation.

## Deterministic holdouts

The hard holdouts are fixed in code before fitting.

### Population extrapolation

~~~text
series = population
N = 1000
~~~

The model may see N = 20, 50, 100, 250, 500 but never N=1000 during model
selection or refitting.

### Information extrapolation

~~~text
series = information
F = 1024
~~~

The model may see F through 512 but never F=1024 during model selection or
refitting.

### Capacity interpolation

Six R/B cells are hidden completely:

~~~text
(R,B) =
(1,2)
(1,8)
(2,4)
(4,2)
(4,16)
(8,8)
~~~

All topology, policy, and seed realizations of those cells are holdouts.

The capacity test is interpolation rather than edge extrapolation. Its purpose
is to test whether the model learned a relationship between redundancy and
bandwidth rather than memorizing the sampled grid.

With the canonical 918 rows this yields:

~~~text
hard population holdout:   27 rows
hard information holdout:  27 rows
hard capacity holdout:    162 rows
non-holdout training:     702 rows
~~~

Within those 702 training rows:

~~~text
seed 0-1 candidate fit:   468 rows
seed 2 candidate validate:234 rows
~~~

The exact usable row count for a conditional-performance target may be smaller
because right-censored rows are excluded from T/C/eta fitting.

## Primary model: regime-specific compact laws

A regime is one topology × policy pair:

~~~text
ring × round_robin
ring × seeded
ring × novel_first
grid × round_robin
grid × seeded
grid × novel_first
complete × round_robin
complete × seeded
complete × novel_first
~~~

Two identifiable candidate laws compete independently for every regime and
target. A hybrid law remains as a predictive diagnostic only.

### Mechanistic candidate

For log-linear performance targets:

~~~text
log(Y) =
  beta0
  + betaD log(D + 1)
  + betaF log(F)
  + betaR log(R)
  + betaB log(B)
~~~

For convergence the same linear predictor is passed through a logistic link.

This candidate asks whether graph distance plus information/resource variables
are sufficient without explicit population size.

### Population candidate

~~~text
log(Y) =
  beta0
  + betaN log(N)
  + betaF log(F)
  + betaR log(R)
  + betaB log(B)
~~~

This challenger asks whether raw population scale can substitute for graph
diameter within a fixed topology family.

### Hybrid diagnostic

~~~text
log(Y) =
  beta0
  + betaN log(N)
  + betaD log(D + 1)
  + betaF log(F)
  + betaR log(R)
  + betaB log(B)
~~~

The hybrid is evaluated but cannot be selected as the primary empirical law.
Within each fixed Stage 5A topology, diameter is a deterministic function of
population size: ring diameter is approximately N/2, complete diameter is 1,
and the grid construction deterministically maps N to its dimensions. Separate
betaN and betaD coefficients are therefore not identifiable as physical
scaling exponents. Ridge can stabilize prediction numerically, but it cannot
create independent information that the experiment did not vary.

### One-class convergence fallback

Some topology × policy regimes contain only successes (or only censoring) in
the candidate-fit region. Logistic regression cannot identify a convergence
boundary without both outcome classes.

For those regimes Stage 5B uses a smoothed constant probability:

~~~text
p = (successes + 0.5) / (rows + 1)
~~~

and reports the law as `one_class`. This is an explicit statement that the
Stage 5A training region does not identify a boundary for that regime; it is
not interpreted as a scaling law.

## Candidate selection without hard-holdout leakage

For each topology × policy × target:

1. Fit the mechanistic and population candidates on non-holdout rows with seed
   0 or 1.
2. Evaluate both on non-holdout rows with seed 2.
3. Select the lower validation loss.
4. Refit the selected candidate using all non-holdout seeds 0, 1, and 2.
5. Evaluate the hybrid separately as a predictive-only diagnostic.
6. Only then evaluate N=1000, F=1024, and capacity interpolation holdouts.

For convergence, if the seed-0/1 fit region contains only one outcome class,
the `one_class` constant model replaces candidate selection because no
boundary is identifiable.

Selection loss:

~~~text
convergence: Brier score
T/C/eta:     mean absolute log error
~~~

The CLI prints all candidate validation scores and marks the selected law.
Therefore model selection remains auditable.

## Pooled interaction challenger

The secondary model deliberately asks a different question:

> Can a single shared law explain all topology and policy families if it is
> allowed interaction terms?

The pooled model has 30 terms:

~~~text
intercept

numeric:
  log(N)
  log(F)
  log(D + 1)
  log(R)
  log(B)

categorical indicators:
  grid
  complete
  seeded
  novel_first

numeric × topology interactions
numeric × policy interactions
~~~

Ring and round_robin are baseline categories.

This is not automatically preferred because it is more flexible. Its purpose
is to challenge the claim that separate dynamical regimes are necessary.

## Fitting

Performance targets use deterministic ridge-regularized normal equations.

Convergence uses deterministic iteratively reweighted least squares for
logistic regression with fixed iteration count and ridge regularization.

No random optimization seed is used.

## Evaluation

For convergence:

~~~text
Brier score
accuracy
censored-run recall
~~~

For conditional performance:

~~~text
mean absolute log error
mean absolute percentage error
~~~

The primary nine-law model and the pooled challenger are scored on the exact
same hard-holdout rows.

The CLI additionally reports each regime separately so a good aggregate score
cannot hide failure in one topology/policy family.

## Interpretation of coefficients

For T and communication models, log-linear coefficients act as empirical
scaling exponents.

For example:

~~~text
betaF > 0
~~~

means the predicted target grows as information volume grows, holding the other
model variables fixed.

A bandwidth coefficient:

~~~text
betaB < 0
~~~

means increasing local communication capacity is predicted to reduce the
target.

The CLI prints every selected coefficient with its named term.

Convergence and useful-efficiency coefficients are effects on log odds rather
than direct power-law exponents.

## Falsification

Stage 5B is not successful merely because one fitted model has a low training
error.

Useful outcomes include any of the following:

1. A compact regime-specific law predicts hard extrapolation/interpolation
   substantially better than the pooled challenger.
2. The pooled interaction law predicts equally well or better, weakening the
   claim that topology/policy regimes require separate laws.
3. Both approaches fail on hard holdouts, falsifying the proposed compact
   feature families.
4. Certain regimes predict cleanly while others do not, identifying where a
   missing state variable or mechanism is required.
5. A law predicts convergence-time magnitude but fails to predict the onset of
   censoring, showing that bounded-horizon failure is a separate phenomenon.

The result is therefore informative even if the preferred mathematical form is
rejected.

## CLI

~~~sh
zig test src/root.zig

zig run src/experiments/stage5/stage5b_cli.zig -- \
  trials/stage5a-full.tsv
~~~

The report includes:

- canonical input identity;
- deterministic split counts;
- all candidate validation scores;
- selected regime law coefficients;
- primary-vs-pooled scores for each hard holdout;
- regime-specific hard-holdout diagnostics.

## Stage 5B gate

Before moving to perturbation experiments:

1. Root tests pass on the authoritative Zig toolchain.
2. The canonical Stage 5A hash is required.
3. Hard-holdout assignments are invariant to outcome and seed.
4. No hard-holdout row participates in candidate selection or refitting.
5. Candidate selection is deterministic.
6. Numerical fits produce finite predictions.
7. Primary and pooled models are compared on identical hard cases.
8. Conclusions distinguish convergence classification from conditional
   performance prediction.
9. Any claimed law is stated only to the extent supported by held-out
   prediction.

Stage 5B does not optimize a new coordination policy. It predicts the behavior
of the Stage 5A policies already observed.
