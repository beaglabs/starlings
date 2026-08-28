# ADR 0002: Operator-neutral coordination core

Status: Accepted for Stage 4

## Context

Stages 3E–3F used language models as a convenient source of imperfect,
heterogeneous local decisions. Those experiments established that formal
communication constraints can materially change population-level outcomes, but
they also exposed model-specific failure modes such as trivial serialization
errors.

The long-term Starlings research objective is broader: study and eventually
serve validated decentralized coordination policies over heterogeneous
operators. Those operators may be deterministic algorithms, learned policies,
language models, CAD/physics tools, robots, sensors, humans, or other systems.

Making an LLM the architectural foundation would incorrectly couple the core
research object to one operator class and make DICE/MATHBAC-style mathematical
claims harder to isolate.

## Decision

Starlings Core is operator-neutral and has no dependency on:

- language-model providers;
- prompts;
- tokenizers;
- chat/completion APIs;
- natural-language message formats.

The formal population substrate is modeled as:

~~~text
P = (A, G, X, M, F, Pi, C, Phi, J)

A   population of operators
G   neighborhood / communication topology
X   local state
M   emitted coordination actions / messages
F   deterministic state transition semantics
Pi  local coordination policy
C   admissibility / control constraints
Phi global observable / outcome
J   cost vector / objective
~~~

The executable mapping is:

- Population + Topology represent A and G.
- State and Observation represent X and the policy-visible local view.
- Action represents M.
- Policy represents Pi.
- Spec.apply owns deterministic transition and constraint enforcement F,C.
- Spec.evaluate owns the global observable Phi.
- Cost provides a common measurement basis for J.

Policies are pluggable. A policy may be:

- a pure deterministic function;
- a parameterized matrix/tensor policy;
- a learned neural policy;
- a solver;
- an adapter to an LLM or other external inference engine.

The runtime validates and applies policy outputs deterministically.

## Consequences

Stage 3 model-backed experiments remain valid historical experiments and
downstream generalization benchmarks. They are not the definition of the core.

New foundational experiments should prefer deterministic or explicitly
parameterized policies so that population-level laws can be measured without
model-provider confounds.

Language-oriented, coding, CAD, robotics, and other learned-agent integrations
should enter through operator/policy adapters after the coordination law and
its operating envelope are characterized.

The initial Stage 4 CLI is intentionally small. It validates the abstraction
and establishes a future product boundary for simulation, validation, serving,
and packaging without prematurely committing to a large framework.
