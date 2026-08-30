<div align="center">

<img src="assets/starlings-logo.png" alt="Starlings logo placeholder" width="520">

# Starlings

**Decentralized intelligence through controlled emergence.**

[![Zig](https://img.shields.io/badge/Zig-0.16.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Core](https://img.shields.io/badge/core-operator--neutral-655eb6)](#architecture)
[![Replay](https://img.shields.io/badge/replay-deterministic-2ea44f)](#deterministic-runtime)
[![Status](https://img.shields.io/badge/status-active%20research-444444)](#research-status)

</div>

---

Starlings is a coordination substrate for **decentralized artificial intelligence through controlled emergence**.

Instead of treating intelligence as one central model, planner, or orchestrator, Starlings treats a system as a population of local operators. Each operator sees only the context available to it, contributes what it can establish, and coordinates through a small typed protocol.

An operator does **not** have to be an LLM. It can be anything capable of supplying useful state to the collective:

- a small local language or vision model;
- a deterministic algorithm or state machine;
- a sensor or sensor-fusion process;
- a physics, geometry, optimization, or planning solver;
- a database query, retrieval system, or external tool;
- a robot, service, human reviewer, or other bounded decision process.

What matters is not the implementation behind an operator. What matters is the contextual information it can contribute: **variables, invariants, observations, estimates, constraints, hypotheses, evidence, or admissible actions**.

Starlings coordinates those contributions without requiring a central component to encode the complete workflow. Local operators expose partial knowledge; causal evidence changes what becomes possible next; runtime constraints bound what is allowed; and the resulting global trajectory emerges from those interactions.

> **The goal is controlled emergence:** global behavior that is not centrally scripted, but is still constrained, attributable, reproducible where required, and measurable under faults and limited resources.

This makes the research problem broader than multi-agent LLM orchestration. The same coordination machinery can connect small local models with non-ML operators and physical or computational systems, allowing the collective to reason over context that no single operator possesses.

The protocol, formal substrate, and SDK live here. Executable stress tests, application witnesses, and falsification experiments live in [`beaglabs/starling-experiments`](https://github.com/beaglabs/starling-experiments).

The SDK turns the formal model into a usable operator/variable/invariant API: operators declare what context they require, what they can contribute, and how they execute; Starlings derives local eligibility and coordinates the resulting state transitions.

## Core capabilities

- **Heterogeneous local operators** — coordinate LLMs, deterministic code, sensors, solvers, tools, humans, and other bounded processes through the same protocol boundary.
- **Contextual variable and invariant exchange** — operators can contribute observations, estimates, constraints, invariants, hypotheses, evidence, and actions without sharing a common internal implementation.
- **Controlled emergence** — the runtime constrains admissibility and provenance while leaving the global workflow to arise from local state and local eligibility.
- **No central semantic schedule** — the coordination substrate does not require a single planner to encode the complete action sequence.
- **Typed coordination grammar** — `OBSERVE`, `QUERY`, `CLAIM`, `EVIDENCE`, `PROPOSE`, `ACCEPT`, `REJECT`, `CHALLENGE`, `RETRACT`, and `DELEGATE`.
- **Deterministic execution where required** — seeded entropy, logical clocks, bounded queues, explicit routing failures, and replay-friendly traces.
- **Content-addressed causal provenance** — BLAKE3 identities, canonical encodings, parent closure, and Merkle-DAG ancestry make contributions attributable and replayable.
- **Pluggable local policies** — deterministic rules, parameterized policies, learned models, solvers, or external adapters can participate without changing the protocol core.
- **Operator/variable/invariant SDK** — declare typed state, local dependencies, invariants, outputs, and terminal targets without hard-coding a global workflow.
- **External operator boundary** — Python and subprocess operators participate through the same versioned wire protocol and output semantics as native operators.

## Architecture

Starlings separates **what an operator knows or can do** from **how the collective coordinates it**.

```mermaid
flowchart TD
    O["Local observation Ωᵢ(Σₜ)"]
    P["Local policy πᵢ"]
    Q["Typed proposal pᵢ,ₜ"]
    C{"Admissibility C"}
    A["Accepted"]
    R["Rejected"]
    F["Transition F"]
    S["Local / global state Σₜ₊₁"]
    PHI["Observable Φ"]

    O --> P
    P --> Q
    Q --> C
    C -->|accepted| A
    C -->|rejected| R
    A --> F
    F --> S
    S --> PHI
    R --> S
```

Operators own local observations and local decisions. The coordination substrate owns admissibility, causal provenance, accounting, and replay.

A sensor can publish a measurement, a solver can establish an invariant, a local model can propose a hypothesis, and a deterministic tool can derive a new variable. None of them needs the full global plan. Their contributions change the state visible to other operators, which changes what becomes locally eligible next.

The workflow is therefore an **outcome of coordinated local state transitions**, not a centrally authored pipeline.

## SDK v0.1

The SDK provides a higher-level interface over the coordination core.

A population is built from typed variables, invariants, and operators. Each operator declares the context it requires and the state it can contribute:

```zig
const sdk = @import("starlings").sdk;

const R = sdk.execution.Runner(8, 4, 8, 64);
var flock = R.init(7, &.{3});

try flock.addVariable(.{
    .variable = .{ .id = 1, .name = "input", .kind = .integer },
});

try flock.addVariable(.{
    .variable = .{ .id = 2, .name = "derived", .kind = .integer },
});
```

Operators return typed `OperatorOutput` values containing variable claims, invariant claims, artifact references, action proposals, and diagnostics. Claims are validated against the operator manifest, content-addressed with BLAKE3, and materialized into collective state without discarding conflicting evidence.

The SDK currently includes:

- typed variables and epistemic states;
- invariants and dependency expressions;
- freshness-aware local eligibility;
- immutable claims and content-addressed artifacts;
- merge and conflict policies;
- deterministic population execution and replay;
- `result.value()`, `result.status()`, and `result.explain()`;
- a versioned external operator protocol;
- Python and subprocess operator support;
- conformance and adversarial tests.

See **[`docs/SDK.md`](docs/SDK.md)** for the SDK model and external operator protocol.

## Formal model

The canonical population is:

```text
P = (A, G, X, M, F, Π, C, Φ, J)
```

| Symbol | Meaning |
| --- | --- |
| `A` | operator population |
| `G` | communication / neighborhood graph |
| `X` | local state |
| `M` | typed coordination actions / messages |
| `F` | deterministic state-transition semantics |
| `Π` | local policy family |
| `C` | admissibility / control constraints |
| `Φ` | global observable / terminal evaluation |
| `J` | cost / measurement vector |

The operational model also makes explicit `Ω` (local observation), `α` (arbitration), and `H` (content identity).

**[Read Formal Starlings Model v0.1](docs/FORMAL_MODEL.md)**

The specification defines heterogeneous populations, local observation boundaries, typed proposals, synchronous/queue/event arbitration, global transition semantics, workflow emergence, deadlock, fault assumptions, theorem status, empirical laws, and the planned Byzantine robustness extension.

## Deterministic runtime

The core runtime uses bounded deterministic state transitions.

A message contains:

```text
sender
recipient
kind
payload
causal_ref
logical_clock
```

The runtime dequeues a message, resolves the recipient, advances logical time, appends the trace event, applies the local transition, and enqueues any emitted response.

Seeded entropy is exposed explicitly for experiments without hard-wiring one scheduler into the foundation.

## Content-addressed provenance

Starlings treats provenance as part of the protocol, not a logging afterthought.

Canonical causal events are encoded as:

```text
version:u8
|| event_kind:u8
|| payload:u64 little-endian
|| parent_count:u8
|| parent_content_ids[0..parent_count]
```

and identified by `BLAKE3(canonical_event_encoding)`.

The current implementation enforces deduplication, parent closure, reconstructable ancestry, explicit fork/merge history, and exact replica divergence accounting.

See:

- [`docs/adr/0001-content-addressed-provenance.md`](docs/adr/0001-content-addressed-provenance.md)
- [`docs/adr/0002-operator-neutral-coordination-core.md`](docs/adr/0002-operator-neutral-coordination-core.md)

## Research status

| Area | Status |
| --- | --- |
| Deterministic coordination runtime | Validated |
| Typed protocol grammar | Validated |
| Content-addressed provenance | Validated |
| Formal population substrate | Validated |
| Scaling and predictive coordination laws | Validated empirically |
| Fault / perturbation behavior | Validated empirically |
| Parameterized coordination policy | Validated |
| Local inference control | Validated empirically |
| Heterogeneous operator experiments | Validated empirically |
| Application-level workflow emergence | Validated in `starling-experiments` |
| Operator / variable / invariant SDK | **v0.1 validated** |
| External operator boundary | **v0.1 validated** |
| SDK conformance / adversarial suite | **Validated** |
| Explicit formal model | **v0.1 defined** |
| Byzantine / rogue-operator robustness | Planned |

## Empirical evidence

Starlings keeps the canonical coordination substrate and its empirical work separate.

This repository contains the protocol, formal model, architecture, SDK, and frozen Stage 0–7C reports under [`docs/`](docs/). The executable modern experiment suite lives in [`beaglabs/starling-experiments`](https://github.com/beaglabs/starling-experiments).

The experiment suite exercises contested fault behavior, asynchronous scaling, state-aware inference control, heterogeneous operator populations, and emergent specialist coordination under changing local context.

```text
beaglabs/starlings
  protocol + semantics
  formal model
  SDK
  architecture
  frozen research reports

beaglabs/starling-experiments
  executable experiments
  stress tests
  application witnesses
  generated datasets
```

## Empirical relationships

Two compact relationships are useful across the existing experiments.

### Sparse-load coordinate

```text
λ = F / (B H)
```

where `F` is information volume, `B` is local bandwidth, and `H` is the execution horizon.

It is a useful regime coordinate in the tested sparse settings rather than a universal threshold.

### Missing-information hazard

```text
h = -M log(1 - p^R)
P(reachable) ≈ exp(-h)
```

The hazard coordinate tracks held-out population, density, redundancy, severity, and compound perturbation cases. The probability approximation is intentionally treated as approximate and can underpredict rare high-hazard successes.

See [`docs/FORMAL_MODEL.md`](docs/FORMAL_MODEL.md) for the mathematical definitions and scope of these relationships.

## Quick start

Requirements:

- Zig **0.16.0**
- macOS or Linux

Clone and run the full core test suite:

```bash
git clone https://github.com/beaglabs/starlings.git
cd starlings

zig version
zig test src/root.zig
zig build test

# external Python operator conformance
python3 -m unittest discover -s python -p 'test_*.py'
```

The root suite covers the deterministic runtime, message routing, provenance, protocol traces and workflows, formal-population behavior, SDK types, registry/eligibility, output/provenance semantics, execution, external operator protocol, replay, conflict handling, and conformance cases.

## Repository layout

```text
src/
  core/
    formal_population.zig    operator-neutral population substrate
    runtime.zig              deterministic message runtime
    operator.zig             local transition interface
    message.zig              typed coordination vocabulary
    content_id.zig           content-addressed identities

  protocol/
    protocol_cfg*.zig        grammar and constrained protocol machinery
    protocol_trace.zig       trace semantics
    protocol_workflow.zig    workflow structure
    protocol_model_*.zig     model-backed evaluation records

  provenance/
    provenance.zig           causal Merkle-DAG substrate
    provenance_validation.zig
    provenance_stress.zig

  sdk/
    core_types.zig           variables, invariants, claims, outputs
    registry.zig             schemas and dependency registry
    eligibility.zig          local eligibility rules
    output_state.zig         claim identity, merge, conflict materialization
    execution.zig            population runner and result API
    external.zig             versioned external operator boundary
    conformance.zig          SDK conformance and adversarial tests

python/
  starlings_operator.py      Python wire-protocol helper
  test_starlings_operator.py subprocess/operator conformance

docs/
  SDK.md                     SDK v0.1 guide
  FORMAL_MODEL.md            formal Starlings specification
  STAGES.md                  historical research program
  stage-*.md                 frozen experimental reports
  adr/                       architecture decisions

grammars/                    protocol grammars
trials/                      generated outputs; generally untracked
assets/                      project visual assets / logo placeholder
```

## Documentation

- **[Starlings SDK v0.1](docs/SDK.md)** — variables, invariants, operator manifests, output lifecycle, external operators, and conformance
- **[Formal Starlings Model v0.1](docs/FORMAL_MODEL.md)** — mathematical object, transition semantics, emergence definition, theorem layer, empirical laws, and conjectures
- [`docs/STAGES.md`](docs/STAGES.md) — historical research progression
- [`docs/adr/0001-content-addressed-provenance.md`](docs/adr/0001-content-addressed-provenance.md) — provenance architecture
- [`docs/adr/0002-operator-neutral-coordination-core.md`](docs/adr/0002-operator-neutral-coordination-core.md) — operator-neutral core
- [`docs/adr/0003-state-aware-inference-controller.md`](docs/adr/0003-state-aware-inference-controller.md) — inference-control architecture
- [`docs/stage-5b-predictive-coordination-laws.md`](docs/stage-5b-predictive-coordination-laws.md) — predictive coordination laws
- [`docs/stage-6-1-robustness-law-validation.md`](docs/stage-6-1-robustness-law-validation.md) — robustness coordinate
- [`docs/stage-7a-parameterized-coordination-policy.md`](docs/stage-7a-parameterized-coordination-policy.md) — parameterized local policy
