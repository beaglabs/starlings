# Starlings Finalization Run

## Purpose

Stages 0–7C established the protocol core and the clean-condition evidence:
formal communication, efficiency laws, robustness laws, policy search and
generalization, and deterministic asynchronous transfer with full envelope
accounting.

The finalization run closes the remaining thesis gaps for the
decentralized-coordination and agentic-communication research position:

~~~text
F1  contested-environment evidence
      F1a canonical fault matrix on the deterministic substrate
      F1b P2Panda-wired transfer as a candidate measurement substrate
F2  asynchrony cost and scaling (delete after validation)
F3  local inference control
F4  neutral heterogeneous AI operators (gemma-4-E2B-it-Q4_K_M.gguf)
~~~

The run is complete when every stage has either frozen canonical evidence
with a recorded dataset hash, or a recorded negative/limitation result with
the same evidentiary discipline.

## Governing rules

Carried forward from STAGES.md and the Stage 7B/7C precedent:

1. The deterministic Zig substrate is authoritative. Real transports,
   replication layers, and model-backed operators are separable candidates
   evaluated against it, never replacements for it.
2. Starlings owns policy, logical topology, recipient selection, fact
   semantics, idempotency, traces, metrics, and completion. A candidate
   substrate only moves envelopes.
3. Freeze worlds, seeds, budgets, and dataset shapes before interpreting
   results.
4. Every transport attempt has exactly one terminal accounting category.
   Every terminal missing fact has a traceable cause. Silent loss is a
   validation failure, not an outcome.
5. Identical configuration and seed reproduce byte-identical traces and
   result rows on the deterministic substrate.
6. Canonical dataset hashes and conclusions are frozen into the stage
   documentation in this repository. Generated trial files stay out of
   version control.
7. Stages marked delete-after-validation: once the dataset hash is frozen
   into documentation, the stage scaffold is deleted from the experiments
   repository. Git history remains the regeneration source.
8. A negative result is a complete result. Candidate rejection with
   attributed cause is evidence, not failure.

## Repository split

This repository (`beaglabs/starlings`) remains the protocol core and the
documentation of record: `src/core`, `src/protocol`, `src/provenance`,
`grammars/`, `docs/`.

All finalization code executes in a new experiments repository
(`beaglabs/starlings-experiments`) that consumes this repository as a Zig
package dependency. No experiment code returns to this tree.

### S0 — experiments repository bootstrap

Create the experiments repository with:

~~~text
build.zig / build.zig.zon
  starlings protocol-core package dependency (git source, pinned rev)
src/
  substrate/    Stage 5A/7A/7C engines re-materialized from starlings
                git history at 176a0f9^ (frozen; no semantic changes)
  cli/          stage entry points
tools/          external runners (F4)
modules/        candidate substrate adapters (F1b)
trials/         gitignored generated outputs
~~~

Definition of done:

- `zig build test` reproduces the protocol-core suite through the package
  dependency;
- the re-materialized Stage 7C harness reproduces the frozen Stage 7C
  dataset byte-for-byte:

~~~text
SHA-256: c89d1985af0479191126fca91265b1fe7f49e7b34db471e13c74e8bb28195a36
~~~

- the re-materialized Stage 7A engine reproduces the named-control baseline
  corners exactly.

The byte-for-byte reproduction is the proof that the frozen policy and
harness semantics survived extraction. Nothing else in the run starts until
S0 passes.

## F1 — Contested-environment evidence

### F1a — canonical fault matrix on the deterministic substrate

The frozen Stage 7C first suite covers zero-fault asynchronous transfer.
F1a completes the contested envelope on the same substrate.

Frozen axes:

~~~text
profiles:
  theta37 theta51 theta93
  round_robin seeded novel_first

topologies:   ring, grid
world seeds:  0, 1, 2
N=8, F=32, R=2, B=2, max virtual ticks=4096

fault worlds:
  no_fault            reference (must reproduce the frozen first suite)
  loss                loss_permille in {50, 200}
  duplication         duplicate_permille in {250}
  latency_jitter      elevated base latency and jitter
  reordering          forced due-time inversions
  partition           timed two-component cut with reconnection
  crash_restart       timed node crash; persist_knowledge in {true, false}
  stale_view          delayed local observation application
  queue_capacity      bounded pending queue under load
  combined            loss + duplication + jitter + partition
~~~

Requirements:

- every injected fault and every terminal missing fact has a traceable
  cause in the run ledger:
  `never_transmitted`, `delivery_faulted`, `crashed_before_merge`,
  `pending_at_censor`;
- the no_fault world reproduces the frozen first-suite rows exactly;
- accounting identities hold in every world:

~~~text
transport_attempts
  = delivered + dropped + partitioned + crashed
  + queue_overflow + pending

communication_units = useful + duplicate
~~~

Dataset: `trials/f1a-fault-matrix.tsv`. Freeze the SHA-256 and the
per-profile fault-tolerance summary into `docs/stage-7c` (as an addendum) or
a dedicated fault-matrix report.

Gate: every world fully accounted, byte-identical replay, and no fault world
loses a fact without an attributed cause.

### F1b — P2Panda-wired transfer as a candidate substrate

History: the 2026-08-28 P2Panda candidate was rejected because identical
eight-node configurations sometimes converged and sometimes exhausted the
runtime with missing collector facts while reporting no errors. That attempt
had no envelope-level audit ledger. F1b re-evaluates P2Panda wiring with the
accounting machinery that now exists.

Re-materialize the historical adapter from starlings git history at
`39cf3e9^`:

~~~text
modules/p2panda/            Rust crate, edition 2024, rust-version 1.98
  p2panda dependency:       beaglabs/p2panda fork
                            rev 80051611b7b41250815a40c945ae7bece84aa249
                            (upstream v0.7.0)
  FFI:                      build.rs compiles the exact Zig policy and
                            links it into the Rust harness
~~~

Semantics:

- P2Panda core provides only network wiring: envelope movement between
  in-process nodes (gossip/replication over the pinned core). No sockets to
  external hosts in the validation gate.
- Starlings owns policy, topology, fact semantics, idempotent merge,
  completion, and the attempt ledger, exposed through the FFI boundary.
- every physical send/receive/attempt/drop at the P2Panda boundary is
  reported into the Starlings ledger; an envelope that cannot be accounted
  is a build-time interface violation, not a runtime mystery.

Evaluation:

- fault-free eight-node transfer: convergence, attempt-ledger completeness,
  and a K-rerun determinism audit at fixed seeds;
- contested subset: partition and crash/restart worlds with the same
  attribution requirement as F1a.

Outcome semantics are explicit:

- PASS: byte-stable results across K reruns and complete accounting under
  faults → record P2Panda wiring as a validated candidate transport for
  later real-substrate work, with an ADR;
- LIMITATION: measurable nondeterminism or unattributed loss → record the
  divergence with attributed cause and retain the deterministic substrate
  as the authoritative measurement layer. This supersedes the 2026-08-28
  rejection only to the extent the audit ledger explains it.

Dataset: `trials/f1b-p2panda-wired.tsv` plus a determinism-audit record.

## F2 — Asynchrony cost and scaling (delete after validation)

Two questions, one disposable scaffold.

### F2.1 — synchronous-to-asynchronous gap

Paired worlds: identical world configuration and seed evaluated under

~~~text
sync:   Stage 7A/5A synchronous engine (re-materialized in S0)
async:  Stage 7C asynchronous harness
~~~

for the three frozen theta profiles and the three named controls across the
F1a topology/seed box. Report per profile:

~~~text
completion:        rounds (sync) vs ticks and per-operator decision
                   counts (async)
communication:     units, useful, duplicate
failures:          success counts at matched budgets
gap:               async cost relative to sync, per dimension
~~~

Dataset: `trials/f2-gap.tsv`.

### F2.2 — asynchronous scaling

~~~text
N in {8, 16, 32, 64, 128}
F/N in {1, 2}
topologies: ring, grid
profiles: theta37 theta51 theta93 novel_first
seeds: 0, 1, 2
fixed decision budget per operator; right-censoring explicit
~~~

Report the feasibility boundary: the smallest N at which each profile
censors under the fixed budget, per density and topology.

Dataset: `trials/f2-scaling.tsv`.

### Freeze and delete

After both datasets are generated:

1. freeze SHA-256 hashes and the gap/scaling summaries into a dedicated
   report in this repository;
2. delete the F2 scaffold from the experiments repository;
3. regenerate-ability is guaranteed by git history, not by the working tree.

Gate: hashes recorded in documentation before the deletion commit.

## F3 — Local inference control

DICE names "local inference control": agents that decide not only what to
communicate but when and how much local computation to spend. Starlings
currently controls communication bandwidth (theta u) but not computation.

### Candidate design (frozen before F3 executes)

Extend the policy parameter:

~~~text
theta = (n, e, r, u, c)

c = inference-gating permille
~~~

Semantics:

- a policy tick may act on the cached local observation (zero inference
  cost) or refresh/recompute its observation and candidate ranking
  (inference cost = one inference unit);
- c gates refresh eligibility deterministically, keyed by
  (seed, operator, local round) exactly as retry gating is keyed in the
  Stage 7A policy;
- corner c=1000 must reproduce current Stage 7B behavior exactly
  (corner-delegation principle: refresh always eligible = today's
  semantics);
- the objective vector gains inference units as a minimized dimension
  alongside failure, rounds, communication units, duplicates, and
  computation calls.

### Experiment

- training box: the frozen Stage 7B training worlds;
- selection: feasibility-first, then Pareto over resource + inference
  dimensions;
- evaluation: Stage 7B validation split plus selected hard holdouts;
- question: can inference gating reduce inference/computation cost while
  preserving feasibility and the resource-cost advantages of the frozen
  family?

Validation criteria:

1. c=1000 corner reproduces Stage 7B results exactly;
2. determinism and accounting identities hold;
3. at least one gated theta preserves zero failures on validation while
   strictly reducing inference units;
4. hard-holdout behavior is compared against the ungated frozen family.

On success: inference control becomes an architectural candidate mechanism
with an ADR and a frozen dataset. On failure: record the observed limitation
and keep the four-dimensional policy as the validated surface.

Dataset: `trials/f3-inference-control.tsv`.

## F4 — Neutral heterogeneous AI operators

The core is operator-neutral by ADR 0002. F4 exercises that neutrality with
a live small language model as one operator class among deterministic
operators, and measures heterogeneous collectives.

### Model and serving

~~~text
weights:    ~/Downloads/models/gemma-4-E2B-it-Q4_K_M.gguf
server:     llama-server (Homebrew llama.cpp), localhost only
adapter:    re-materialized from tools/stage3f0_llama_cpp.py at 2d695fb^
            (RUNNER_VERSION semantics: self-test, dry-run, prompt-suite
            SHA-256 metadata sidecar, sampling-seed and environment-seed
            as separate factors)
~~~

The weights path is volatile; the experiments repository references it
through a models/ directory (gitignored) with a documented source location.

### Operator adapter

- the model emits protocol-vocabulary interactions only; the Starlings
  runtime parses, validates, and applies them deterministically;
- invalid model output is rejected and counted, never silently repaired;
- two arms, following Stage 3E/3F methodology:
  `typed_unconstrained` and `cfg_constrained`.

### Heterogeneous populations

~~~text
population mixes:
  deterministic-only      theta operators (control)
  mixed                   deterministic theta operators + gemma operators
                          on the same topology
  model-only              gemma operators only (diagnostic)

topologies: ring, grid
objective:  collector convergence on distributed facts
~~~

### Determinism discipline

- all substrate-side execution remains replay-invariant; nondeterminism is
  confined to the model adapter;
- sampling seeds are swept; results are aggregates over seeds;
- unique successful-trajectory hash counts are reported per configuration
  (Stage 3F.0 methodology) — many trajectory hashes with equal outcomes
  is the expected signature of a healthy model-backed arm;
- no scientific claim is made from a single trajectory.

Measurements: success rate, communication units, useful/duplicate split,
rejection counts, budget compliance, and the deterministic-vs-mixed
comparison.

Dataset: `trials/f4-heterogeneous.tsv` plus per-run metadata sidecars.

## Ordering and dependencies

~~~text
S0  experiments repository bootstrap
    |
    +-> F1a deterministic fault matrix          (pure Zig)
    |     |
    |     +-> F1b P2Panda-wired candidate       (Rust toolchain)
    |
    +-> F2 asynchrony gap + scaling             (pure Zig, delete after)
    |
    +-> F3 inference control                    (pure Zig)
    |
    +-> F4 heterogeneous operators              (llama.cpp + weights)
~~~

F1a is the prerequisite for F1b only. F2 and F3 are independent of the
P2Panda toolchain and can proceed in parallel with F1b. F4 last, because it
carries the most external dependencies.

## Exit criteria for the run

The finalization run is complete when:

1. S0 reproduces the frozen Stage 7C dataset byte-for-byte through the
   package dependency;
2. F1a is frozen with complete fault attribution;
3. F1b has a recorded PASS or LIMITATION verdict with attributed cause;
4. F2 hashes are frozen into documentation before its scaffold is deleted;
5. F3 has a frozen result or a recorded limitation;
6. F4 has aggregates over swept sampling seeds with trajectory-hash
   multiplicity reported;
7. every architectural consequence (validated mechanism or retained
   limitation) is recorded as an ADR in the protocol repository.

At that point the evidence table for decentralized coordination under
contested conditions, quantified asynchrony cost, local inference control,
and operator-neutral heterogeneous collectives is complete, and each row is
pinned by a dataset hash in this repository.
