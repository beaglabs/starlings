# F4 heterogeneous model-backed operator evidence

F4 is the final stage of the Starlings finalization run.

It tested whether the operator-neutral coordination substrate can host live
language-model-backed operators alongside frozen deterministic operators while
keeping Starlings authoritative for protocol semantics, state transitions,
topology, accounting, and success.

## Canonical environment

~~~text
N = 5
F = 5
facts = A,B,C,D,E
redundancy = 2
bandwidth = 2
collector = Worker 1
max_rounds = 10
topologies = ring, grid
~~~

Frozen deterministic communication policy:

~~~text
theta51 = (354,141,0,994)
~~~

Canonical model:

~~~text
gemma-4-E2B-it-Q4_K_M.gguf
~~~

The exact local GGUF bytes used for the run are pinned by SHA-256:

~~~text
740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8
~~~

The model weights remain external to the repository.

## Population arms

### deterministic-only

All five operators use frozen theta51.

### mixed

~~~text
Worker 1 deterministic collector
Worker 2 model-backed
Worker 3 model-backed
Worker 4 deterministic
Worker 5 deterministic
~~~

Workers 2 and 3 share one fact whose only two initial copies are held by those
two model-backed workers. Therefore a successful mixed run must contain a real
information transfer from the model-backed portion into the deterministic
portion of the population.

### model-only

All five operators are model-backed. This arm is diagnostic rather than the
primary F4 promotion gate.

## Model action language

Model operators may propose only:

~~~text
CLAIM <facts>
QUERY EVIDENCE <fact>
~~~

The model proposes an interaction. It does not own execution semantics.

The authoritative path is:

~~~text
llama.cpp completion
  -> Zig parse
  -> Zig semantic validation
  -> Starlings action
  -> deterministic topology/state transition
  -> authoritative Zig replay
~~~

Invalid outputs are rejected and counted. They are never silently repaired.

## Decode treatments

Every canonical state-aware model population compares:

~~~text
typed_unconstrained
cfg_constrained
~~~

with the same:

- model bytes;
- initial environment;
- topology;
- sampling seed;
- sampler settings;
- round budget;
- token budget;
- inference controller.

CFG constrains syntax only. Semantic validity remains a deterministic Starlings
decision.

## F3 inference-control continuity

Canonical model-backed operators use the F3-validated:

~~~text
knowledge_or_stale
~~~

controller.

A smaller matched always-refresh subset remains as a diagnostic control.

## Canonical matrix

~~~text
deterministic controls:
  3 environment seeds
  x 2 topologies
  = 6 runs

state-aware model matrix:
  3 environment seeds
  x 3 sampling seeds
  x 2 topologies
  x 2 mixes
  x 2 decode modes
  = 72 runs

always-refresh audit:
  env0 x sampling0
  x 2 topologies
  x 2 mixes
  x 2 decode modes
  = 8 runs

total:
  86 population runs
~~~

## Frozen identities

~~~text
summary rows:
  86

summary bytes:
  11284

summary SHA-256:
  d263db94aee099c9ba47aa8eae60cf0ad49258fa6f299a5a9571fe6b545d2164

raw TSV SHA-256:
  bf2d791e8f37fc75c8fb423920a5737fa7a70b56599ad49d2274300256389530

GGUF SHA-256:
  740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8
~~~

Structural gates:

~~~text
byte_identical_replay: yes
backend_errors: 0
token_budget_violations: 0
~~~

## Deterministic controls

All six deterministic controls converged:

~~~text
ring:
  3/3

grid:
  3/3
~~~

## Canonical mixed-population results

### CFG-constrained

~~~text
ring:
  successes=9/9
  model_calls=36
  cache_reuses=0
  invalid=0
  semantic_rejections=5
  communication=340
  useful=135
  duplicate=205

grid:
  successes=9/9
  model_calls=18
  cache_reuses=0
  invalid=0
  semantic_rejections=0
  communication=180
  useful=108
  duplicate=72
~~~

### Typed-unconstrained

~~~text
ring:
  successes=6/9
  model_calls=104
  cache_reuses=0
  invalid=30
  semantic_rejections=22
  communication=739
  useful=118
  duplicate=555

grid:
  successes=3/9
  model_calls=143
  cache_reuses=1
  invalid=65
  semantic_rejections=51
  communication=934
  useful=104
  duplicate=803
~~~

The primary F4 heterogeneous success gate therefore passes on both topologies
through the CFG-constrained treatment.

## Model-only diagnostic

CFG-constrained:

~~~text
ring:
  successes=9/9
  invalid=0
  semantic_rejections=11

grid:
  successes=9/9
  invalid=0
  semantic_rejections=0
~~~

Typed-unconstrained:

~~~text
ring:
  successes=0/9
  invalid=377
  semantic_rejections=30

grid:
  successes=0/9
  invalid=413
  semantic_rejections=11
~~~

This arm is not the promotion gate, but it shows that syntactic protocol
control is operationally decisive for this model and action language.

## Trajectory diversity

F4 also required evidence that success was not reducible to one scripted
trajectory.

Examples of fixed mixed environments with multiple successful semantic
trajectory hashes across sampling seeds:

~~~text
grid / env1 / typed:
  successful=3
  unique=3

ring / env0 / typed:
  successful=3
  unique=3

ring / env1 / cfg:
  successful=3
  unique=2

ring / env1 / typed:
  successful=3
  unique=2

ring / env2 / cfg:
  successful=3
  unique=3
~~~

Therefore the trajectory-diversity gate passes.

## State-aware cache reuse in F4

Reuse opportunities were sparse in this short live-model workload:

~~~text
mixed/grid/typed:
  cache_reuses=1

model-only/grid/typed:
  cache_reuses=13

model-only/ring/typed:
  cache_reuses=5

all other state-aware groups:
  cache_reuses=0
~~~

This does not contradict F3. F3 established that the controller safely reduces
fresh inference when reusable state exists. F4's short closed-loop runs often
change knowledge or invalidate/stale the cached decision before reuse becomes
eligible.

## Interpretation

F4 closes as a **PASS**.

The canonical evidence supports:

1. live model-backed operators can participate in the same coordination
   substrate as deterministic operators;
2. the model does not need authority over protocol semantics or state
   transitions;
3. mixed deterministic/model populations converge across both ring and grid;
4. successful mixed runs require actual information transfer from the
   model-backed portion into the deterministic portion;
5. repeated successful semantic trajectories occur from fixed initial states;
6. CFG-constrained decoding materially improves reliability for this model and
   protocol vocabulary.

The architectural claim is deliberately narrower than the CFG result:

~~~text
model-backed operators are untrusted policy adapters;
Starlings remains the deterministic authority.
~~~

The strong CFG result is retained as experimental evidence for this
model/protocol pair, not as a universal requirement for every future model or
interaction language.

Canonical verdict:

~~~text
F4 PASS: heterogeneous model-backed operator evidence complete
~~~
