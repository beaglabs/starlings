# starlings

Experimental infrastructure for evidence-backed mathematical agent communication and collective coordination, implemented in Zig.

## Current scope: Stage 0–5A

The foundation contains the machinery needed to run reproducible experiments and compare coordination strategies:

- deterministic operator state transitions
- a small typed message vocabulary
- bounded message queues and traces
- logical clocks
- seeded deterministic experimental entropy
- explicit capacity and routing failures
- replay-friendly execution traces
- deterministic distributed-information benchmarks
- broadcast-all, centralized, and typed point-to-point baselines
- communication metrics for messages, bytes, rounds, payload duplication, operator use, and task success
- seeded randomized fact placement
- partitioned and overlapping/redundant task shapes
- deterministic per-message loss injection
- whole-worker failure injection
- aggregate benchmark summaries across seed ranges
- deterministic protocol trace corpora and workflow-diversity experiments
- candidate CFG parsing, malformed-sequence rejection, and encoding benchmarks
- CFG stress/generalization tests over exhaustive and seeded unseen compositions
- provider-agnostic model-backed A/B evaluation for unconstrained vs CFG-constrained decoding
- outcome-scored controlled-emergence experiments over distributed local knowledge
- communication-budget experiments that measure useful vs redundant information transfer
- an operator-neutral formal population substrate with pluggable local policies
- deterministic coordination-plane validation without any language-model dependency
- orthogonal information-diffusion scaling sweeps over population, information volume, topology, redundancy, bandwidth, and local policy

Stage 1 uses five workers and a verifier. The partitioned task assigns one independent fact to each worker, while the overlapping task gives each worker two facts so that every fact exists at two workers. This lets the harness distinguish raw communication efficiency from resilience under information loss.

## Validated architecture: content-addressed provenance

Stage 2 validated content-addressed causal DAG provenance and promoted it into the required Starlings architecture.

- `ContentId` is a 256-bit BLAKE3 digest (`[32]u8`).
- Runtime causal references use content IDs rather than loose integer references.
- Event identity is derived from a versioned canonical encoding, not Zig struct memory layout.
- Repeated causal events deduplicate to one DAG node.
- Causal ancestry remains reconstructable across chains and fork/merge graphs.
- Divergent replicas can determine exact missing-content counts without replaying full history.

Canonical provenance encoding v1 is:

```text
version:u8
|| event_kind:u8
|| payload:u64 little-endian
|| parent_count:u8
|| parent_content_ids[0..parent_count]
```

See `docs/adr/0001-content-addressed-provenance.md` for the architectural decision.

Formal grammars remain a candidate architectural component under active Stage 3 validation: deterministic corpus, composition, stress, and encoding gates have passed locally; Stage 3E established live constrained-generation plumbing, and Stage 3F now tests whether formal control preserves autonomous collective coordination. Executable semantics, dynamic flocking topologies, VSAs, category-theoretic models, effect systems, and differential-geometric models also remain candidate components. Candidates should be integrated only after their hypotheses are experimentally validated; once validated, they become architectural commitments rather than optional features.

## Test

Using Zig 0.16.0 or a compatible newer compiler:

```sh
zig test src/root.zig
```

The suite covers deterministic runtime behavior, Stage 1 coordination benchmarks, provenance validation, duplicate-heavy provenance histories, fork/merge causal closure, replica divergence, content identity sensitivity, protocol trace analysis, deterministic workflow diversity, CFG parsing/encoding, CFG stress/generalization, and the Stage 3E model-evaluation machinery.


## Stage 3E.1 live llama.cpp experiment

Start a llama.cpp server, then validate and run the paired experiment:

```sh
python3 tools/stage3e1_llama_cpp.py --self-test
python3 tools/stage3e1_llama_cpp.py --dry-run
python3 tools/stage3e1_llama_cpp.py --seeds 100 --output trials/stage3e1.tsv
zig run src/stage3e1_summary.zig -- trials/stage3e1.tsv
```

See `docs/stage-3e1-llama-cpp.md` for the experimental controls and runbook.


## Stage 3F.0 distributed fact convergence

Stage 3F.0 replaces canonical workflow matching with an outcome-scored
controlled-emergence benchmark. Five model-backed workers start with overlapping local facts on a ring and autonomously choose factual protocol interactions until Worker 1 reconstructs the global fact set or the round budget is exhausted. Environment rotation and model sampling are separate factors so multiple trajectories can be measured from the same initial state.

Validate and run the five-seed smoke experiment:

```sh
python3 tools/stage3f0_llama_cpp.py --self-test
python3 tools/stage3f0_llama_cpp.py --dry-run
python3 tools/stage3f0_llama_cpp.py \
  --base-url http://127.0.0.1:8080 \
  --environments 5 \
  --sampling-seeds 4 \
  --output trials/stage3f0-gemma4-e2b-v2.tsv

zig run src/stage3f0_summary.zig -- \
  trials/stage3f0-gemma4-e2b-v2.tsv
```

See `docs/stage-3f0-distributed-fact-convergence.md` for the environment,
A/B controls, replay invariants, metrics, and progression gates.


## Stage 3F.1 communication efficiency

Stage 3F.1 expands the controlled-emergence task to ten overlapping facts and
gives each worker a fixed communication-unit budget. Broad redundant claims
consume budget quickly; selective claims and evidence queries can solve the
same global objective at substantially lower cost.

Validate and run the default replication:

~~~sh
python3 tools/stage3f1_llama_cpp.py --self-test
python3 tools/stage3f1_llama_cpp.py --dry-run
python3 tools/stage3f1_llama_cpp.py \
  --base-url http://127.0.0.1:8080 \
  --environments 5 \
  --sampling-seeds 4 \
  --worker-budget 16 \
  --output trials/stage3f1-gemma4-e2b-budget16.tsv

zig run src/stage3f1_summary.zig -- \
  trials/stage3f1-gemma4-e2b-budget16.tsv
~~~

See docs/stage-3f1-communication-efficiency.md for the budget semantics,
replay invariants, metrics, and experimental gate.


## Stage 4 formal population substrate

Stage 4 makes the architectural pivot from LLM-first experiments to an
operator-neutral coordination core. The formal population model is executable
as:

~~~text
P = (A, G, X, M, F, Pi, C, Phi, J)
~~~

where populations, topology, local state, actions, transition semantics,
policies, constraints, global observables, and costs are represented by the
generic Zig substrate in src/formal_population.zig.

The core has no dependency on prompts, tokenizers, model providers, or
completion APIs. Language models remain a supported downstream policy/operator
class rather than the definition of Starlings itself.

Validate the deterministic Stage 4 substrate:

~~~sh
zig test src/root.zig

zig run src/stage4_cli.zig -- validate

zig run src/stage4_cli.zig -- simulate 0 8
~~~

See docs/stage-4-formal-population-substrate.md and
docs/adr/0002-operator-neutral-coordination-core.md for the formal mapping,
architectural decision, validation scope, and progression toward a coordination
SDK/CLI/serving plane.


## Stage 5A information diffusion scaling

Stage 5A uses the operator-neutral coordination philosophy to measure how
deterministic local information diffusion scales without any LLM dependency.

The experiment supports up to 1,024 operators and 1,024 independent facts with:

- ring, complete, and grid topologies;
- configurable initial fact redundancy;
- configurable per-operator fact bandwidth;
- round-robin, seeded, and novel-first local policy families;
- collector convergence as the global outcome;
- exact messages, communication fact-units, useful deliveries, duplicate
  deliveries, policy calls, rejected actions, topology diameter/edges, and
  violations.

Stage 5A.1 performance hardening keeps the experiment semantics unchanged while
using word-level bitset delivery/accounting, active-word merges, and a no-copy
synchronous round path. A test-only reference engine preserves the original
copy-heavy/per-fact implementation and must produce exactly equal Results
across topology/policy combinations, including fact counts crossing a 64-bit
word boundary.

The sweep deliberately separates independent variables into three series
instead of coupling population size and information volume:

~~~text
population   vary N, hold facts/redundancy/bandwidth fixed
information  vary fact count, hold N/redundancy/bandwidth fixed
capacity     vary redundancy + bandwidth at fixed N and fact count
~~~

Validate and inspect the sweep plan:

~~~sh
zig test src/root.zig

zig run src/stage5a_cli.zig -- validate

zig run src/stage5a_cli.zig -- plan smoke
zig run src/stage5a_cli.zig -- plan full
~~~

Run a single configuration:

~~~sh
zig run src/stage5a_cli.zig -- \
  run 100 ring 2 2 novel_first 0 4096 32
~~~

Emit machine-readable TSV:

~~~sh
zig run src/stage5a_cli.zig -- sweep smoke > trials/stage5a-smoke.tsv

zig run src/stage5a_cli.zig -- sweep full > trials/stage5a-full.tsv
~~~

The smoke plan contains 63 runs. The full plan contains 918 runs.

See docs/stage-5a-information-diffusion-scaling.md for the experimental
controls, metric definitions, sweep matrix, and Stage 5A progression gate.


### Stage 5A.2 deterministic summary

After producing the canonical full sweep, summarize it without fitting a model:

~~~sh
zig run src/stage5a_summary.zig -- trials/stage5a-full.tsv
~~~

The summary:

- verifies the 918-row canonical shape and SHA-256 identity;
- keeps horizon-exhausted runs right-censored rather than treating 4096 as a
  convergence time;
- reports success rate, successful-run round statistics, communication cost,
  useful-information efficiency, duplicate fraction, and censored completion;
- groups results by topology/policy and by the population, information, and
  capacity sweep axes;
- reports the first observed population/information censoring boundary for each
  topology/policy family;
- lists empirical extrema and every censored configuration.

Canonical Stage 5A dataset SHA-256:

~~~text
92279da22ded432f942b24f96f4f4658ee49174ba45c66239537744bee988fc6
~~~


## Stage 5B — Predictive Coordination Laws

Stage 5B asks whether the empirical Stage 5A dynamics can be predicted on
configurations that are deliberately hidden before fitting.

Run against the frozen canonical dataset:

~~~sh
zig run src/stage5b_cli.zig -- trials/stage5a-full.tsv
~~~

The primary approach fits a separate compact law for each topology × policy
regime. Two identifiable feature families compete using only seed-2 validation
rows from the non-holdout region:

- mechanistic: diameter, information volume, redundancy, bandwidth;
- population: population size, information volume, redundancy, bandwidth.

A hybrid N+D model is still reported as a predictive diagnostic, but it cannot
be selected as the primary mathematical law because D is determined by N
inside each fixed topology family. For convergence regimes whose candidate-fit
rows contain only one outcome class, Stage 5B reports an explicit smoothed
one-class baseline instead of manufacturing an unidentifiable boundary law.

Seeds 0 and 1 fit each candidate. Seed 2 chooses the candidate. The selected
candidate is then refit on all non-holdout seeds before hard evaluation.

Hard holdouts are fixed before model fitting:

~~~text
population extrapolation: N = 1000
information extrapolation: F = 1024
capacity interpolation:
  (R,B) = (1,2), (1,8), (2,4), (4,2), (4,16), (8,8)
~~~

A pooled 30-term ridge model with topology/policy interactions is evaluated as
a challenger to the regime-specific laws.

Targets are separated:

~~~text
P(T_conv <= 4096)   all rows, including right-censored outcomes
T_conv | success    successful rows only
C_comm | success    successful rows only
eta_info | success  successful rows only
~~~

Censored observations are never assigned a fake convergence time of 4096.


## Stage 5C — Regime Boundaries and Saturation

Stage 5C follows the specific failures exposed by Stage 5B rather than adding
another generic model family.

It asks two questions:

1. Where does the high-information ring/grid regime leave the Stage 5A
   4096-round convergence envelope, and which cases merely converge slowly
   versus remain censored at an extended 16384-round horizon?
2. For complete graphs, what is the exact minimum local bandwidth B* that
   permits one-round saturation?

Plan and validate:

~~~sh
zig run src/stage5c_cli.zig -- plan full
zig run src/stage5c_cli.zig -- validate
~~~

Generate the canonical Stage 5C datasets:

~~~sh
zig run src/stage5c_cli.zig -- boundary full \
  > trials/stage5c-boundary.tsv

zig run src/stage5c_cli.zig -- saturation full \
  > trials/stage5c-saturation.tsv
~~~

Summarize them deterministically:

~~~sh
zig run src/stage5c_cli.zig -- summarize-boundary \
  trials/stage5c-boundary.tsv

zig run src/stage5c_cli.zig -- summarize-saturation \
  trials/stage5c-saturation.tsv
~~~

The boundary experiment contains 756 base cases at N=128, R=2 across dense
F values through 2048, B={1,2,4}, ring/grid, all three local policies, and
seeds 0-2. Runs censored at 4096 are automatically rerun from the same initial
condition to a 16384-round horizon.

The saturation experiment contains 576 threshold searches across N={32,64,128,
256}, F/N={0.5,1,2,4}, R={1,2,4,8}, all three policies, and seeds 0-2. It uses
an exact complete-graph one-round coverage oracle and binary-searches the
minimum B*.

Stage 5C extends the deterministic fact bitset ceiling from 1024 to 2048. This
changes capacity only, not transition semantics. Existing Stage 5A behavior in
the old range must remain regression-identical.


## Stage 6 — Perturbation / DICE

Stage 6 perturbs the control structures identified in Stage 5C instead of
introducing new clean-system laws.

Sparse robustness anchors use the Stage 5C near-boundary configurations and
apply three deterministic, nested perturbations:

- operator_omission: an operator loses an emission opportunity for one round
  but can still receive;
- message_drop: a directed transport attempt is suppressed for one round;
- edge_removal: an undirected topology edge is removed for the entire run.

The canonical sparse sweep contains 540 runs across six Stage 5C anchors, ten
severity levels, three perturbation classes, and three deterministic trials.
Static-edge runs record the collector component and whether that component
contains every fact, separating structural impossibility from slow dynamics.

Complete-graph coverage robustness perturbs the Stage 5C one-round B* threshold.
The canonical coverage sweep contains 2,592 threshold searches across
N={64,128,256}, F/N={1,2,4}, R={1,4,8}, round_robin/seeded, operator omission
or message drop, eight severities, and three deterministic trials. A perturbed
configuration may become explicitly unreachable even at B=F.

~~~sh
zig run src/stage6_cli.zig -- validate
zig run src/stage6_cli.zig -- plan full

zig run -O ReleaseFast src/stage6_cli.zig -- sparse full \
  > trials/stage6-sparse.tsv

zig run -O ReleaseFast src/stage6_cli.zig -- coverage full \
  > trials/stage6-coverage.tsv

zig run src/stage6_cli.zig -- summarize-sparse \
  trials/stage6-sparse.tsv

zig run src/stage6_cli.zig -- summarize-coverage \
  trials/stage6-coverage.tsv
~~~
