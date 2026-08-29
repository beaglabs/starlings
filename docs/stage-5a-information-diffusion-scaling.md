# Stage 5A — Information Diffusion Scaling

Stage 5A is the first post-substrate experiment aimed at discovering
population-level regularities rather than merely demonstrating that Starlings
can execute a decentralized population.

## Research question

> How do population size, information volume, topology, initial redundancy,
> local communication bandwidth, and local policy affect convergence time and
> communication cost in a deterministic decentralized population?

The experiment remains LLM-independent.

## Variables

The Stage 5A harness exposes:

~~~text
N   population size
F   independent fact count
G   topology
R   initial copies per fact
B   maximum facts emitted per operator per round
Pi  local policy family
~~~

The global outcome is collector convergence: operator 0 succeeds once its
local knowledge contains all F facts.

## Supported scale

The implementation uses a bounded 1,024-bit information representation and
supports:

~~~text
2 <= N <= 1024
1 <= F <= 1024
1 <= R <= N
1 <= B <= F
~~~

The scaling harness intentionally does not use the Stage 4 adjacency matrix for
large populations. Ring, complete, and grid neighborhoods are evaluated
analytically so a sparse ring does not pay O(N^2) topology scanning overhead.
This keeps the measured cost focused on coordination behavior rather than a
particular graph storage representation.

## Topologies

### Ring

Each operator has its immediate predecessor and successor as neighbors.

~~~text
degree ~= 2
edges = N
diameter = floor(N / 2)
~~~

For N=2, the single peer is counted once.

### Complete

Every operator is adjacent to every other operator.

~~~text
degree = N - 1
edges = N(N - 1) / 2
diameter = 1
~~~

### Grid

Operators are placed row-major in the smallest square-width rectangular grid
that can hold N nodes. Up/down/left/right edges are used when the corresponding
node exists.

The final row may be incomplete.

## Initial information placement

Each fact is placed at exactly R distinct operators.

Placement is deterministic from:

~~~text
(seed, fact_index, redundancy_copy)
~~~

A mixed start index and a stride coprime with N are used so repeated copies of
one fact cannot land on the same operator.

Different seeds change placement while preserving the requested copy count.

## Local policy families

No policy receives global population state or the collector state.

### round_robin

An operator walks deterministically through its currently known facts and emits
up to B facts per round.

### seeded

An operator derives a deterministic pseudo-random traversal from:

~~~text
(seed, operator_index, round)
~~~

and emits up to B locally known facts.

This provides trajectory diversity without nondeterministic execution.

### novel_first

An operator prefers facts it has not previously emitted. Once all currently
known facts have been emitted, its local sent-history epoch resets.

This is a compact local anti-redundancy policy and requires no neighbor
knowledge.

## Synchronous semantics

Each round uses a frozen pre-round snapshot.

~~~text
snapshot
   |
   +--> local policy decisions
   |
   +--> validate every proposed action
   |
   +--> deliver to topology neighbors
   |
   +--> merge received facts
   |
   +--> evaluate collector convergence
~~~

No policy can observe state changes produced earlier in the same round.

## Bandwidth

B is a local fact-unit limit.

If B=2, one operator may emit at most two distinct facts in one round.

A single action is delivered to every topology neighbor. Therefore one
two-fact action on a ring normally costs four communication units:

~~~text
2 facts * 2 recipients = 4 fact-units
~~~

This separates message count from information volume.

## Metrics

Each run records:

~~~text
population
facts
topology
diameter
edges
redundancy
bandwidth
policy
seed
success
rounds
collector_initial
collector_final
policy_calls
actions
rejected
messages
comm_units
useful
duplicate
useful_per_1000
violations
~~~

### Useful and duplicate delivery semantics

A fact delivery is useful when that recipient did not know the fact at the
start of the round and has not already received that fact earlier in the same
round.

All other transmitted fact-units are duplicates.

This makes the aggregate identity exact:

~~~text
communication_units = useful_deliveries + duplicate_deliveries
~~~

The identity is asserted by the runtime.

## Why the full sweep is orthogonalized

Varying N operators and F facts together would confound population scaling with
information-volume scaling.

Stage 5A therefore uses three separate series.

### Population series

Vary population size while fixing information volume and local capacity.

Full profile:

~~~text
N = 20, 50, 100, 250, 500, 1000
F = 32
R = 2
B = 2
G = ring, grid, complete
Pi = round_robin, seeded, novel_first
seed = 0, 1, 2
~~~

162 runs.

### Information series

Vary information volume while fixing population size.

Full profile:

~~~text
N = 128
F = 8, 16, 32, 64, 128, 256, 512, 1024
R = 2
B = 2
G = ring, grid, complete
Pi = round_robin, seeded, novel_first
seed = 0, 1, 2
~~~

216 runs.

### Capacity series

Vary redundancy and communication bandwidth at a fixed baseline.

Full profile:

~~~text
N = 128
F = 128
R = 1, 2, 4, 8
B = 1, 2, 4, 8, 16
G = ring, grid, complete
Pi = round_robin, seeded, novel_first
seed = 0, 1, 2
~~~

540 runs.

Total full profile:

~~~text
918 runs
~~~

## Smoke profile

The smoke profile contains 63 runs and covers the population and information
series at smaller scale.

Use it to validate the harness before starting the full sweep.

## CLI

Run the root suite:

~~~sh
zig test src/root.zig
~~~

Validate the Stage 5A matrix:

~~~sh
zig run src/experiments/stage5/stage5a_cli.zig -- validate
~~~

Inspect planned run counts without executing the sweep:

~~~sh
zig run src/experiments/stage5/stage5a_cli.zig -- plan smoke
zig run src/experiments/stage5/stage5a_cli.zig -- plan full
~~~

Run one configuration:

~~~sh
zig run src/experiments/stage5/stage5a_cli.zig -- \
  run 100 ring 2 2 novel_first 0 4096 32
~~~

Arguments are:

~~~text
population
topology
redundancy
bandwidth
policy
seed
max_rounds
fact_count
~~~

Emit the smoke data:

~~~sh
zig run src/experiments/stage5/stage5a_cli.zig -- sweep smoke > trials/stage5a-smoke.tsv
~~~

Emit the full data:

~~~sh
zig run src/experiments/stage5/stage5a_cli.zig -- sweep full > trials/stage5a-full.tsv
~~~

The TSV contains a series column so population, information, and capacity
experiments remain distinguishable.

## Stage 5A.1 performance hardening

The canonical Stage 5A experiment is unchanged, but the execution engine is
hardened so large sweeps measure coordination behavior without avoidable
simulator overhead.

The optimized path makes four semantics-preserving changes:

1. Delivery accounting operates on active 64-bit words rather than scanning
   every fact for every logical message.
2. BitSet count, complete-set detection, and novel-first unsent detection use
   word-level operations with an explicit mask for partial tail words.
3. The main round loop no longer copies the complete population into both
   snapshot and next arrays. All policy decisions are collected before any
   mutation; knowledge remains frozen during delivery; local sent/cursor
   metadata is then committed; received knowledge is merged only after all
   deliveries.
4. Knowledge merges touch only the words needed by the configured fact count.

These changes preserve the Stage 5A synchronous semantics:

~~~text
all decisions observe pre-round state
all action validation uses pre-round knowledge
all useful/duplicate accounting uses pre-round knowledge plus earlier
same-round receipts
new knowledge becomes policy-visible only on the next round
~~~

A deliberately slow reference engine remains test-only. It retains the
original population copying and per-fact delivery loop. The root suite compares
the optimized and reference Results exactly across all three topology families,
all three policy families, and configurations on both sides of a 64-bit word
boundary.

The equivalence requirement is:

~~~text
optimized Result == reference Result
~~~

including success, rounds, policy calls, actions, messages, communication
units, useful deliveries, duplicates, rejected actions, and violations.

For a direct regression against the preliminary large-ring result, rerun:

~~~sh
zig run src/experiments/stage5/stage5a_cli.zig -- \
  run 1000 ring 2 2 novel_first 0 4096 32
~~~

The optimized implementation should reproduce the same deterministic metrics
as the pre-hardening run while completing substantially faster.

## Stage 5A.2 deterministic dataset summary

The canonical full sweep is summarized by a deterministic Zig parser:

~~~sh
zig run src/experiments/stage5/stage5a_summary.zig -- trials/stage5a-full.tsv
~~~

The canonical dataset checkpoint is:

~~~text
rows: 918
population: 162
information: 216
capacity: 540
violating rows: 0
successes within 4096 rounds: 889
right-censored at 4096 rounds: 29
success rate within horizon: 96.84%
sha256: 92279da22ded432f942b24f96f4f4658ee49174ba45c66239537744bee988fc6
~~~

A horizon-exhausted row is not treated as a 4096-round convergence. It is a
right-censored observation:

~~~text
T_conv > 4096
~~~

Accordingly, mean/median/min/max convergence rounds are calculated only over
successful runs. Censored runs are instead characterized by collector
completion fraction, communication expenditure, and useful-information
efficiency.

The summary produces:

1. canonical shape/hash/integrity metadata;
2. overall successful-versus-censored metrics;
3. topology x policy aggregate statistics;
4. population-scaling tables at fixed F=32, R=2, B=2;
5. information-scaling tables at fixed N=128, R=2, B=2;
6. capacity-scaling tables at fixed N=128, F=128;
7. first observed population and information censoring boundaries by
   topology/policy;
8. empirical extrema;
9. the complete list of right-censored configurations.

Stage 5A.2 remains descriptive. It does not fit, select, or validate a scaling
equation. Predictive mathematical modeling and held-out evaluation are reserved
for Stage 5B.

## Stage 5A gate

Stage 5A is successful if:

1. Root tests and the validation matrix pass deterministically.
2. Repeated identical configurations produce identical results.
3. Every fact begins with exactly the requested redundancy.
4. No valid policy produces protocol/constraint violations.
5. Communication accounting closes exactly.
6. The smoke and full sweeps emit complete machine-readable rows.
7. The resulting data show enough variation in rounds and communication cost
   to justify fitting candidate relationships in Stage 5B.

Stage 5A does not require a preferred scaling equation.

Selecting, fitting, comparing, and validating predictive mathematical models is
reserved for Stage 5B.

## What Stage 5A does not claim

This stage does not establish:

- an optimal topology;
- an optimal local policy;
- a universal communication law;
- robustness under failure or compromise;
- transferable learned coordination weights;
- coding, CAD, language, or robotics performance.

Those require later stages.

## Progression

The intended progression is:

~~~text
Stage 4
formal executable substrate
        |
Stage 5A
orthogonal empirical scaling data
        |
Stage 5B
candidate predictive mathematical model
        |
Stage 6
perturbations and controlled-emergence envelope
        |
Stage 7
optimized / learned compact coordination policy
        |
Stage 8
transfer to heterogeneous real operators
~~~
