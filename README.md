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
