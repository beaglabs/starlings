# Stage 6 — Perturbation / DICE

Stage 6 is the first controlled robustness stage.

Stages 4–5C established deterministic population dynamics and two empirical
control structures:

1. sparse propagation is bounded by a topology/policy-specific information-load
   envelope, with Stage 5C showing a compact coordinate F/(B H) at fixed N,R;
2. complete-graph one-round saturation is a set-coverage threshold B* whose
   redundancy dependence is controlled by emission overlap rather than a
   multiplicative R factor.

Stage 6 asks how those structures move when the population is disturbed.

## Research question

> How robust are the identified coordination regimes to controlled operator,
> transport, and topology perturbations, and which failures are dynamical
> versus structurally unavoidable?

The experiment is deliberately operator-neutral. No language model or prompt
behavior is introduced.

## Deterministic perturbation worlds

Every perturbation event is generated from:

~~~text
perturbation_seed
mechanism domain
round
operator / sender / recipient
~~~

through a fixed 64-bit mixer.

Severity is represented in permille.

For a fixed perturbation seed, event sets are nested:

~~~text
events(p=0.10) subset events(p=0.30)
~~~

because the same deterministic hash value is compared against a larger
threshold. A higher severity therefore means more faults in the same world,
not a newly sampled world.

This matters for interpreting stability boundaries.

## Perturbation classes

### Operator omission

~~~text
operator_omission
~~~

With probability/severity p per operator-round, an operator does not execute
its local emission policy in that round.

The operator:

- keeps its state;
- can still receive messages;
- may resume emission in later rounds.

This isolates loss of local actuation capacity from network loss.

### Directed message drop

~~~text
message_drop
~~~

Each directed sender -> recipient delivery attempt in each round may be
suppressed.

The sender has still emitted the action and therefore commits its local
sent/cursor metadata exactly as in the unperturbed engine.

This models transient transport loss.

### Static edge removal

~~~text
edge_removal
~~~

An undirected edge is either present or absent for the entire run. The event is
keyed only by the unordered endpoint pair and perturbation seed, not by round.

This changes G itself rather than introducing transient delivery loss.

For each static-edge run Stage 6 computes before simulation:

~~~text
removed edge count
collector connected-component size
distinct initial facts in the collector component
~~~

If the collector component does not contain all F facts, convergence is
structurally impossible under that static topology. Stage 6 records this
separately from ordinary horizon censoring and returns immediately without
simulating rounds that cannot change the answer.

## No-fault equivalence

Stage 6 reuses Stage 5A's exact:

- state and BitSet representation;
- initial placement;
- local policies;
- action validation;
- synchronous merge semantics.

Stage 5A exposes its deterministic local decision and action-validation
primitives for this purpose.

Root tests require Stage 6 at severity zero to reproduce Stage 5A exactly for
all three topologies and all three policy families, including:

~~~text
success
rounds
collector state
policy calls
actions
messages
communication units
useful/duplicate accounting
violations
~~~

This is the primary regression guardrail.

## Sparse propagation robustness

Stage 6 anchors perturbations at six Stage 5C configurations that were all-seed
successful at H=4096.

~~~text
anchor                    topology policy        B  F     lambda=F/(BH)

ring_round_robin_edge     ring     round_robin   2  384   0.046875
ring_seeded_edge          ring     seeded        2  128   0.015625
ring_novel_first_high     ring     novel_first   1  2048  0.500000

grid_round_robin_edge     grid     round_robin   1  1280  0.312500
grid_seeded_edge          grid     seeded        2  896   0.109375
grid_novel_first_high     grid     novel_first   1  2048  0.500000
~~~

The first, second, fourth, and fifth anchors sit near the resolved Stage 5C
all-success boundary for their regime. Novel-first has no resolved boundary
through F=2048 and therefore acts as a high-load robustness control.

Canonical severities:

~~~text
0
10
25
50
100
150
200
300
400
500 permille
~~~

Each anchor is tested under all three perturbation mechanisms and three
deterministic trial seeds:

~~~text
6 anchors * 3 mechanisms * 10 severities * 3 trials = 540 runs
~~~

The base configuration seed is the trial seed. The perturbation world uses a
domain-separated deterministic seed derived from the same trial identifier.

## Sparse outcomes

Every row records:

~~~text
success / rounds
collector initial/final facts

policy opportunities
actual policy calls
operator omissions

attempted messages / units
delivered messages / units
suppressed messages / units
useful / duplicate delivered units

removed edges
collector component size
collector component fact coverage
structural reachability
~~~

The summary reports for every anchor × mechanism:

~~~text
last severity where all trials succeed
first severity where any trial censors
first severity where all trials censor

first severity with any structurally impossible trial
first severity where all trials are structurally impossible

non-monotonic all-success returns
~~~

Boundary summaries use `-1` to mean "not observed on the sampled severity
grid." This is intentionally distinct from a real 0-permille boundary value.
Each boundary row also reports the maximum severity actually present in the
dataset, and summary tables omit unsampled zero-row groups.

Detailed severity rows also report average successful convergence time,
delivered/attempted communication ratio, removed edges, and surviving collector
component fraction.

## DICE interpretation

For operator omission and transient message loss, a first-order throughput
hypothesis is that perturbation reduces the usable capacity term in the Stage
5C load envelope.

Stage 6 does not predeclare a corrected equation. It first measures whether
critical severities are consistent across topology/policy regimes.

For static edge removal, the relevant mechanism is different. Once G loses
connectivity needed to place all facts in the collector component, no amount of
additional H or local bandwidth can restore convergence.

This explicitly separates:

~~~text
resource-limited dynamical failure
from
topological reachability failure
~~~

## Complete-graph coverage robustness

Stage 5C defined:

~~~text
B* = minimum local bandwidth that gives collector full coverage after one round
~~~

Stage 6 perturbs that threshold under the two one-round-distinct mechanisms:

~~~text
operator_omission
message_drop
~~~

Static sender-collector edge removal is not included as a third canonical
coverage mechanism because in a one-round collector-only coverage test it is
observationally equivalent to permanently dropping that sender's message for
the round.

The canonical grid is:

~~~text
N = 64, 128, 256
F/N = 1, 2, 4
R = 1, 4, 8
Pi = round_robin, seeded
mechanism = operator_omission, message_drop
severity = 0,25,50,100,200,300,400,500 permille
trial = 0,1,2
~~~

for:

~~~text
2,592 threshold searches
~~~

Novel-first is omitted because Stage 5C proved it is exactly round-robin in the
first round before sent-history exists.

## Perturbed coverage threshold

For each row Stage 6 first computes the unperturbed Stage 5C B*.

It then tests the perturbed system at:

~~~text
B = F
~~~

If even full-bandwidth emission cannot cover every missing collector fact, the
perturbed one-round threshold is recorded as:

~~~text
reachable = no
perturbed_B = 0
~~~

rather than inventing a threshold.

If full-bandwidth coverage remains possible, Stage 6 binary-searches the
minimum perturbed B*.

The row records:

~~~text
baseline B*
perturbed B*
B* inflation = perturbed / baseline
reachability
max coverage at B=F
active/delivered sender counts
suppressed fact units
~~~

## Coverage summary

For each:

~~~text
mechanism × policy × R × F/N × severity
~~~

the summary pools population sizes and trial seeds and reports:

~~~text
reachable rows
median baseline B*
median perturbed B*
median threshold inflation
median maximum-coverage fraction
~~~

This measures both graceful threshold inflation and the onset of outright
one-round impossibility.

## Canonical validation gate

Before freezing Stage 6 datasets:

1. root tests pass on the authoritative Zig toolchain;
2. Stage 5A smoke output remains byte-identical;
3. Stage 5C canonical dataset hashes remain unchanged;
4. severity-zero Stage 6 dynamics match Stage 5A exactly;
5. perturbation event sets are nested with severity;
6. static edge removal is symmetric;
7. sparse smoke TSV has exactly 36 fields per row;
8. coverage smoke TSV has exactly 21 fields per row;
9. summaries contain zero malformed and violation rows;
10. coverage thresholds never report a finite B* when B=F is unreachable.

After Stage 6, the next roadmap step is to use the measured robustness surfaces
to define and optimize a compact coordination-control parameter theta rather
than continuing to add named hand-written policies.


### Resuming full sweeps

Full sparse and coverage sweeps emit progress to stderr and accept an optional
1-based start index.

A fresh run:

~~~sh
zig run -O ReleaseFast src/experiments/stage6/stage6_cli.zig -- sparse full 1 \
  > trials/stage6-sparse.tsv
~~~

If interrupted after K completed data rows, preserve the partial file and
resume at K+1 using append mode:

~~~sh
# Example: header + 136 completed rows means resume at case 137.
wc -l trials/stage6-sparse.tsv

zig run -O ReleaseFast src/experiments/stage6/stage6_cli.zig -- sparse full 137 \
  >> trials/stage6-sparse.tsv
~~~

When start_index > 1 the CLI does not emit another TSV header.

The same convention applies to the coverage sweep.


## Canonical sparse robustness results

The authoritative Stage 6 sparse dataset contains:

~~~text
rows: 540
malformed rows: 0
violation rows: 0
severity-zero failures: 0
SHA-256:
bc65358d7c8a519905319fdeb023c4d0b34d8a5d4d66f090bf6eaf30eb336d6e
~~~

Every canonical anchor therefore reproduces its Stage 5C baseline at zero
severity.

### Observed robustness boundaries

The first-any / first-all horizon-censoring severities are:

~~~text
anchor                         mechanism           first-any   first-all
ring_round_robin_edge          operator_omission       25          150
ring_round_robin_edge          message_drop            25           50
ring_round_robin_edge          edge_removal             10           25

ring_seeded_edge               operator_omission      400          500
ring_seeded_edge               message_drop           300          400
ring_seeded_edge               edge_removal             10           25

ring_novel_first_high          operator_omission       10           10
ring_novel_first_high          message_drop            10           10
ring_novel_first_high          edge_removal             10           25

grid_round_robin_edge          operator_omission       50          100
grid_round_robin_edge          message_drop            10           25
grid_round_robin_edge          edge_removal             25           50

grid_seeded_edge               operator_omission      150          150
grid_seeded_edge               message_drop           100          200
grid_seeded_edge               edge_removal            150          300

grid_novel_first_high          operator_omission       25          300
grid_novel_first_high          message_drop           100          150
grid_novel_first_high          edge_removal            100          300
~~~

All values are permille.

### Transient faults versus structural failure

Operator omission and directed message loss never make the initial graph
structurally unreachable. Their failures are therefore dynamical/horizon
failures.

Static edge removal behaves differently.

For the ring, the first structurally unreachable trial appears at 10 permille
edge removal and all three trials are structurally unreachable by 25 permille.
This is consistent with the ring's low edge-connectivity: small static damage
rapidly partitions the information placement.

For the grid, structural failure appears much later:

~~~text
first any structurally unreachable: 300 permille
first all structurally unreachable: 400 permille
~~~

for all three grid anchors.

Importantly, grid convergence often fails well before structural reachability
is lost. For example grid round-robin has all three trials horizon-censored by
50 permille edge removal even though all three collector components still
contain every fact. Grid seeded remains structurally reachable in all trials
through 200 permille but already shows horizon censoring at 150 permille.

Therefore topology perturbation has at least two separate effects:

1. path/throughput degradation while all information remains reachable;
2. eventual structural loss of required information from the collector
   component.

### Policy-specific fault tolerance

Ring seeded is the strongest transient-fault regime among the tested ring
anchors:

~~~text
operator omission:
  first-any censoring = 400 permille
  first-all censoring = 500 permille

message drop:
  first-any censoring = 300 permille
  first-all censoring = 400 permille
~~~

This is substantially more robust than ring round-robin despite both operating
on the same topology.

The high-load ring novel-first control shows the opposite behavior: it
converges cleanly without faults but all trials censor at only 10 permille
operator omission or message drop.

Thus high clean-system throughput is not equivalent to perturbation
robustness.

### Non-monotone trajectory response

The deterministic fault sets are nested with severity, but convergence outcome
is not strictly monotone.

Examples:

~~~text
ring round-robin + operator omission:
  25 permille -> 2/3 successes
  50 permille -> 3/3 successes

grid seeded + operator omission:
  150 permille -> 0/3 successes
  200 permille -> 1/3 successes
~~~

Additional faults can therefore alter the collective trajectory in a way that
restores convergence for a trial that failed at a lower severity.

This rejects a purely scalar interpretation in which perturbation only reduces
effective bandwidth or effective round budget. A future robustness law needs
both a resource-loss term and a trajectory/coordination-state term.

### Stage 6 sparse conclusion

The sparse results support four claims within the tested deterministic
population envelope:

1. robustness is strongly topology × policy dependent;
2. transient operator/message faults can cause dynamical failure without any
   loss of structural reachability;
3. static topology damage introduces a distinct reachability phase transition;
4. nested perturbation severity does not guarantee monotone collective
   convergence because faults also change the coordination trajectory.

The complete-graph coverage robustness sweep remains the second canonical half
of Stage 6.


## Canonical complete-coverage robustness results

The authoritative Stage 6 coverage dataset contains:

~~~text
rows: 2592
malformed rows: 0
violation rows: 0
severity-zero anomalies: 0
unreachable rows: 1172
unreachable fraction: 45.2%
SHA-256:
86f15137ee2c3d1b066daeb6e61fa9f052ddf55cb5eb4f4c4f44aed2a11bdb04
~~~

All severity-zero cells reproduce the Stage 5C one-round threshold baseline.

### Redundancy creates a reachability phase transition

Pooling policy, information density, population size, trial seed, and both
perturbation mechanisms gives the following one-round reachability fractions:

~~~text
R=1:
  p=0.000 -> 108/108 = 100.0%
  p=0.025 ->   8/108 =   7.4%
  p=0.050 ->   2/108 =   1.9%
  p=0.100 ->   0/108 =   0.0%

R=4:
  p=0.100 -> 108/108 = 100.0%
  p=0.200 ->  66/108 =  61.1%
  p=0.300 ->  16/108 =  14.8%
  p=0.400 ->   6/108 =   5.6%
  p=0.500 ->   4/108 =   3.7%

R=8:
  p=0.200 -> 108/108 = 100.0%
  p=0.300 -> 106/108 =  98.1%
  p=0.400 ->  84/108 =  77.8%
  p=0.500 ->  48/108 =  44.4%
~~~

Thus redundancy is not merely reducing the clean-system B* threshold. It
changes whether a complete one-round solution exists at all after faults.

R=1 is catastrophically brittle because a missing unique source can remove the
only one-round path to a required fact. R=8 often retains alternative source
copies even when a large fraction of senders or deliveries are suppressed.

### Reachability is policy-independent at full bandwidth

Round-robin and seeded have identical reachable-row counts in every
mechanism × R × severity aggregate.

This is mechanistically expected. At B=F, both policies emit all locally known
facts, so existence of a one-round solution depends on:

~~~text
initial placement
redundancy
which senders/deliveries survive
collector's own initial knowledge
~~~

rather than the ordering policy.

Policy still changes the minimum sub-full threshold B* when the perturbed
system remains reachable.

This separates two mathematical objects:

~~~text
reachability phase:
  controlled primarily by placement/redundancy/fault realization

bandwidth inflation inside the reachable phase:
  controlled additionally by emission policy/overlap
~~~

### Fault mechanism differences

At high redundancy, message-drop worlds remain somewhat more reachable than
operator-omission worlds at high severity.

Examples pooled over policy/density/population/trial:

~~~text
R=8, p=0.5:
  message_drop      28/54 reachable = 51.9%
  operator_omission 20/54 reachable = 37.0%

R=4, p=0.3:
  message_drop      14/54 reachable = 25.9%
  operator_omission  2/54 reachable =  3.7%
~~~

In the sparse multi-round experiment, operator omission and per-recipient
message loss are genuinely different mechanisms. In this complete one-round
collector-only coverage oracle, however, both reduce to a Bernoulli
sender-contribution event at the collector. Their different observed reachable
counts come from different deterministic fault hash domains / finite sampled
worlds and should not be interpreted as different one-round coverage
correlation structures.

### Information density reduces fault tolerance

Within fixed redundancy, larger F/N reduces the probability that every
required fact still has at least one surviving route.

At R=8 and p=0.5, pooling policy and both mechanisms:

~~~text
F/N=1 -> 26/36 reachable = 72.2%
F/N=2 -> 14/36 reachable = 38.9%
F/N=4 ->  8/36 reachable = 22.2%
~~~

This shows that redundancy alone is not the sufficient robustness coordinate;
information volume must also enter the reachability law.

### Graceful threshold inflation

When redundant systems remain reachable, perturbation often first appears as
an increase in B* rather than immediate impossibility.

Representative summary cells include:

~~~text
operator omission, seeded, R=8, F/N=4, p=0.5:
  median inflation ≈ 2.038x

message drop, seeded, R=8, F/N=4, p=0.5:
  median inflation ≈ 1.705x

operator omission, round-robin, R=8, F/N=4, p=0.5:
  median inflation ≈ 1.236x

message drop, round-robin, R=8, F/N=4, p=0.5:
  median inflation ≈ 1.096x
~~~

Therefore redundancy converts part of the fault response from binary
unreachability into graceful communication-cost inflation.

### Candidate missing-fact hazard law

A useful null model follows directly from the one-round semantics.

If each required fact has R independently placed source copies and each source
route is independently unavailable with probability p, then the probability a
particular fact loses every source is approximately:

~~~text
p^R
~~~

and for F required facts:

~~~text
P(all facts reachable) ≈ (1 - p^R)^F
                       ≈ exp(-F p^R)
~~~

when p^R is small.

This implies a candidate critical fault scale:

~~~text
p_c ~ F^(-1/R)
~~~

up to collector-self-knowledge, placement correlations, and finite-population
effects.

Stage 6 does not validate this equation yet. It is a mechanistic hypothesis
suggested by the observed sharp R-dependent reachability transition and should
be tested explicitly before becoming part of the Starlings coordination law.

### Stage 6 combined conclusion

The sparse and complete-coverage experiments together separate three distinct
robustness mechanisms:

1. **dynamical degradation** — transient faults can push a structurally
   reachable sparse population beyond the convergence horizon;
2. **topological reachability loss** — static damage can remove required
   information from the collector component entirely;
3. **coverage redundancy** — replicated information can preserve one-round
   reachability and convert faults into B* inflation instead of immediate
   impossibility.

The sparse experiment additionally shows that nested fault sets can produce
non-monotone trajectory outcomes, so a complete robustness theory cannot be
only a scalar capacity law.

The complete-coverage result suggests that structural fault tolerance may have
a simpler missing-fact hazard law based on F, R, and perturbation probability,
while sparse multi-round dynamics require an additional trajectory/state term.

This completes the canonical Stage 6 perturbation dataset. The next stage
should test/fit the compact robustness coordinates and then use them to define
a learnable coordination-control parameter theta.
