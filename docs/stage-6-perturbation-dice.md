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
separately from ordinary horizon censoring.

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
