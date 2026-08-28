# Stage 4 — Formal Population Substrate

Stage 4 is the architectural pivot from LLM-first experiments to an
operator-neutral coordination plane.

The research question becomes:

> Can population-level coordination behavior be expressed, simulated, measured,
> and eventually parameterized independently of the implementation of any one
> operator?

## Formal model

The Stage 4 substrate uses:

~~~text
P = (A, G, X, M, F, Pi, C, Phi, J)
~~~

where:

~~~text
A    operator population
G    communication / neighborhood graph
X    local state
M    coordination action
F    deterministic transition rule
Pi   local policy
C    admissibility constraints
Phi  global observable / outcome
J    cost vector
~~~

This is a research abstraction, not a claim that the final theory is already
complete. Stage 4 makes these objects executable so later experiments can
derive and falsify mathematical predictions about them.

## Core API

src/formal_population.zig defines:

- OperatorId
- Topology(max_operators)
- Population(State, max_operators)
- Policy(Observation, Action)
- Simulator(Spec, max_operators)
- Outcome
- Cost
- RoundEffect
- SimulationResult

A domain Spec supplies State, Observation, Action, Context, observe, apply, and
evaluate.

The simulator executes synchronous rounds:

~~~text
snapshot local states
        |
        v
local observation per active operator
        |
        v
independent policy decisions
        |
        v
collect all actions
        |
        v
deterministic constraint + transition application
        |
        v
global outcome evaluation
~~~

Every active policy sees the same pre-round snapshot. Policy outputs therefore
cannot observe within-round application order.

## Policy boundary

A Policy contains a decision function and an optional opaque parameter/context
pointer.

That permits future policies backed by:

- deterministic rules;
- coefficients / matrices;
- compact learned coordination weights;
- neural policies;
- external solvers;
- LLM adapters.

The simulator itself does not know which implementation is behind the policy.

## Deterministic Stage 4 experiment

src/stage4_population_experiment.zig ports the distributed overlapping-fact
shape into the generic substrate without an LLM.

Five operators start on a ring with overlapping local facts. Each local policy
knows only:

- its operator index;
- current round;
- its own current knowledge;
- its local topology degree.

The default rotating-claim policy emits one currently-known fact. It does not
receive the global state or an exact trajectory.

All five environment rotations converge to the same collector objective using
the generic simulator. A silent local policy intentionally fails, establishing
that the outcome is driven by the policy rather than hard-coded simulator
success.

This is a substrate validation experiment, not yet a mathematical law.

## Cost vector

The Stage 4 common cost vector currently tracks:

~~~text
communication
computation
violations
~~~

Computation is counted as local policy invocations. Domain-specific experiments
may later add richer metrics alongside this common vector.

The vector is intentionally not collapsed into a scalar objective yet. Later
stages can define and validate objective functions such as:

~~~text
J =
alpha * communication
+ beta * convergence time
+ gamma * violations
~~~

without baking one weighting into the core.

## CLI boundary

Stage 4 adds a minimal executable boundary:

~~~sh
zig run src/stage4_cli.zig -- validate
zig run src/stage4_cli.zig -- simulate 0 8
~~~

validate runs all five rotated deterministic environments and exits nonzero if
any fail or violate constraints.

simulate runs one environment and reports the outcome, rounds, policy calls,
actions, rejected actions, cost vector, and final states.

This is intentionally not yet a daemon or network protocol. The purpose is to
establish the product/API seam before adding serving.

## Validation

Run:

~~~sh
zig test src/root.zig

zig run src/stage4_cli.zig -- validate

zig run src/stage4_cli.zig -- simulate 0 8
~~~

Expected validation properties:

- 5/5 rotated environments succeed;
- no constraint violations;
- deterministic repeated summaries;
- silent policy exhausts without success;
- no language-model process or API is required.

## What Stage 4 does not claim

Stage 4 does not yet establish:

- an optimal coordination law;
- scalability to large populations;
- robustness under failures;
- a learned compact policy;
- transfer to coding/CAD/language agents;
- a production serialization format.

It establishes the abstraction required to test those hypotheses cleanly.

## Next research progression

Once the substrate is stable:

1. Scale deterministic populations across graph sizes and topologies.
2. Measure convergence, communication, redundancy, and trajectory diversity.
3. Fit candidate relationships between graph/information parameters and global
   outcomes.
4. Perturb the population with loss, failures, topology changes, and adversarial
   behavior.
5. Optimize or learn compact policy parameters theta.
6. Reintroduce heterogeneous learned operators as a generalization test.
7. Add SDK/serving/package interfaces only after the executable abstractions
   survive those experiments.

The desired commercialization path is therefore:

~~~text
mathematical model
      |
simulation + validation
      |
validated coordination policy
      |
portable policy/artifact
      |
SDK / CLI / serving runtime
      |
coding, CAD, robotics, distributed AI, other operator classes
~~~
