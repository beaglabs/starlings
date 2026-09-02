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
      F1b P2Panda-wired transfer candidate (runtime limitation)
      F1c thin zquic transport candidate (validated)
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

#### S0 completion record — 2026-08-29

S0 passed on macOS with Zig 0.16.0 through
`starling-experiments` PR #2.

~~~text
frozen sources: 6 byte-identical blobs

Stage 5A:
  runs:       27
  successes:  27
  violations: 0

Stage 7A:
  baseline_corner_checks:          18
  baseline_corner_mismatches:      0
  interior_determinism_checks:      6
  interior_determinism_mismatches:  0

Stage 7C:
  theta37:      success=yes accounted=yes violations=0
  theta51:      success=yes accounted=yes violations=0
  theta93:      success=yes accounted=yes violations=0
  novel_first:  success=yes accounted=yes violations=0

dataset bytes: 2961
SHA-256:
c89d1985af0479191126fca91265b1fe7f49e7b34db471e13c74e8bb28195a36
~~~

The reproduced SHA-256 exactly matches the frozen Stage 7C first-suite hash.
The S0 dependency gate is therefore closed and F1a may proceed.

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

#### F1a completion record — 2026-08-29

F1a passed through `starling-experiments` PR #4.

~~~text
canonical rows: 432
successes:      397
non-convergent: 35

byte_identical_replay:          yes
envelope_accounting_failures:   0
missing_accounting_failures:    0
unattributed_missing:           0
violations:                     0

dataset bytes: 68973
SHA-256:
c9d6b93937467ebf363ee14a02b2028ba0993d50a282770c547eaa3d35ed3ae5
~~~

Per-profile fault-tolerance summary:

~~~text
novel_first  successes=66/72  terminal_missing=22  communication_units=181035
round_robin  successes=67/72  terminal_missing=18  communication_units=176508
seeded       successes=66/72  terminal_missing=17  communication_units=238524
theta37      successes=66/72  terminal_missing=19  communication_units=181687
theta51      successes=66/72  terminal_missing=21  communication_units=180593
theta93      successes=66/72  terminal_missing=21  communication_units=116470
~~~

All 35 non-convergent canonical worlds terminate with fully attributed missing
facts. F1a therefore closes as a successful contested-environment evidence
stage; convergence under every injected fault is not required by the gate.

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

#### F1b disposition — 2026-08-29

The P2Panda candidate did not become the validated real-transport substrate.

During local validation, the pinned P2Panda/iroh dependency stack repeatedly
panicked in a background thread inside `futures-lite` after an
`Unfold` stream had already terminated. The panic recurred in independent
fault-free worlds while the child process itself continued returning success,
which meant the candidate runtime could conceal a transport failure from a
naive process-exit gate.

The verifier was hardened to capture background stderr/panics explicitly, but
the transport was not upgraded in place because changing the pinned dependency
would change the candidate under evaluation.

F1b therefore remains the recorded P2Panda limitation that motivated a thinner
replacement candidate rather than a validated transport result.

### F1c — thin zquic transport candidate

F1c replaces the P2Panda runtime with a deliberately smaller boundary:

~~~text
Starlings semantics
  -> minimal length-prefixed envelope
  -> zquic raw application stream
  -> QUIC / TLS 1.3 / loss recovery / congestion control
  -> UDP loopback
~~~

Frozen dependency:

~~~text
zigstack/zquic
tag:          v1.7.48
commit:       4bd041ac95425fb0aa229b74c9d3316c74aaf829
package hash: zquic-1.7.0-2zRc1PSAFgDCESpm-vZsUr4O02HM0dpzmVJSx5WXW6ES
Zig:          0.16.0
~~~

There is no discovery, mDNS, DHT, libp2p, replication runtime, database, HTTP,
WebSocket, Rust runtime, or FFI in the F1c path.

Starlings remains authoritative for policy, topology, logical attempt identity,
fact semantics, idempotent merge, the frozen Stage 7C asynchronous schedule,
fault injection, accounting, and completion. QUIC retransmissions remain
transport-internal and never create new Starlings attempts.

#### F1c completion record — 2026-08-29

F1c passed the canonical local verifier on macOS with Zig 0.16.0.

~~~text
canonical rows: 42
dataset bytes:  8007
SHA-256:
6ef0b88e5c06c1ceb3ce41ec08e1fcec89a08743e7e2440e5d48a097b3e66ddb

fault-free successes: 24/24
determinism audit:    12 rows, K=3
contested rows:        6

envelope_accounting_failures:      0
missing_accounting_failures:       0
communication_accounting_failures: 0
protocol_violations:                0
send_failures:                      0
malformed_frames:                   0
unattributed_missing:               0
pending_at_censor:                  0
transport_panics:                   0
backpressure_events:                0

udp_datagrams: 37396
~~~

All four fixed determinism worlds were full-row stable across K=3 reruns:

~~~text
novel_first / grid / seed 2  6d24eee242cc7dbc
theta37     / ring / seed 0  45f9f003bc89eab4
theta51     / grid / seed 1  9926f2289bf713c8
theta93     / ring / seed 2  608d12243989469e
~~~

F1c therefore closes as a PASS. The deterministic Zig substrate remains the
authoritative measurement layer; the pinned zquic path is a validated
real-transport candidate beneath the Starlings protocol boundary.

Detailed evidence is frozen in `docs/f1c-zquic-transport.md`.

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

#### F2.1 completion record — 2026-08-29

F2.1 passed the canonical local verifier on macOS with Zig 0.16.0.

~~~text
canonical rows: 36
dataset bytes: 5695
SHA-256:
34531d63dc8628a7592f01f4c06cc0be632e0c2428f43e933beeec0b1a5293cd

byte_identical_replay: yes
stage7c_parity_rows: 36/36
budget_bound_rows: 0

sync_successes: 36/36
async_successes: 36/36
async_censored: 0

violations: 0
stage7c_parity_failures: 0
accounting_failures: 0
communication_failures: 0
invalid_censoring: 0
~~~

Per-profile aggregate deltas across six paired worlds:

~~~text
novel_first  communication=+819   duplicate=+779   policy=+267  tick-round=+120
round_robin  communication=+1092  duplicate=+1040  policy=+315  tick-round=+149
seeded       communication=+1374  duplicate=+1356  policy=+405  tick-round=+289
theta37      communication=+478   duplicate=+427   policy=+192  tick-round=+103
theta51      communication=+144   duplicate=+162   policy=+135  tick-round=+94
theta93      communication=+691   duplicate=+644   policy=+380  tick-round=+205
~~~

Aggregate across all 36 paired worlds:

~~~text
communication_delta = +4598
duplicate_delta     = +4408
policy_call_delta   = +1694
tick_round_delta    = +960
~~~

F2.1 therefore closes as a PASS. Asynchrony preserves convergence across the
entire frozen N=8 box while adding measurable communication, duplication,
policy-call, and completion-time cost. Detailed evidence is frozen in
`docs/f2-1-asynchrony-gap.md`.

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

#### F2.2 completion record — 2026-08-29

F2.2 passed the canonical local verifier on macOS with Zig 0.16.0.

~~~text
canonical rows: 240
dataset bytes: 35712
SHA-256:
25f828b00b74b93f27826c91193057b3bfb1148ae0127c32be1afa79f1911773

byte_identical_replay: yes
successes: 240/240
censored: 0
violations: 0
accounting_failures: 0
communication_failures: 0
queue_overflow: 0
unexpected_fault_terminals: 0
~~~

Per-profile totals:

~~~text
theta37      successes=60/60  communication=1816013  duplicate=1434263
theta51      successes=60/60  communication=1720228  duplicate=1338138
theta93      successes=60/60  communication=1737538  duplicate=1355694
novel_first  successes=60/60  communication=7575655  duplicate=7193975
~~~

All 16 `profile × topology × F/N` groups are 3/3 successful at every tested
population:

~~~text
N=8    3/3
N=16   3/3
N=32   3/3
N=64   3/3
N=128  3/3
~~~

Thus no feasibility boundary was observed inside the frozen F2.2 box.
The correct measured conclusion is a lower bound, not a threshold:

~~~text
observed feasibility boundary:
  N > 128
~~~

F2.2 therefore closes as a PASS. Together with F2.1, F2 is scientifically
complete: F2.1 quantifies the N=8 asynchrony cost, while F2.2 establishes that
the tested policies remain feasible throughout the frozen scaling range.

Detailed evidence is frozen in `docs/f2-2-asynchronous-scaling.md`.

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

### F3 completion record — 2026-08-29

F3 completed in two mechanism-specific subexperiments.

#### F3a — blind inference gating

~~~text
rows: 187
dataset bytes: 25506
SHA-256:
42e60db5b999d19319f00a254eafda0eebe3ae5c1c37a824ca155bcbd074bfb2

byte_identical_replay: yes
violations: 0
inference_accounting_failures: 0
c1000_corner_mismatches: 0
stage7b_anchor: PASS
~~~

F3a produced a valid **LIMITATION**. Its validation frontier contained only
`c=1000` always-refresh policies. Blind seed/operator/round-indexed cache
reuse was therefore not promoted.

#### F3b — state-aware inference control

F3b held the frozen Stage 7B ids 37/51/93 fixed and varied only deterministic
local refresh control.

~~~text
rows: 85
dataset bytes: 11329
SHA-256:
eb4237fdf5e6ac309b29f01c16345f9ff6507b8806ab986b15fbb3c9e080347a

byte_identical_replay: yes
violations: 0
inference_accounting_failures: 0
communication_accounting_failures: 0
paired_baseline_mismatches: 0
~~~

The `knowledge_or_stale` controller was promoted for all three frozen base
policies with lower inference and zero failures across all six hard holdout
families.

Paired validation deltas against exact always-refresh twins:

~~~text
base37:
  inference       -1167
  rounds              0
  communication    -723
  duplicates       -711
  computation         0
  hard failures       0

base51:
  inference       -1559
  rounds              0
  communication   -2148
  duplicates      -2147
  computation         0
  hard failures       0

base93:
  inference       -1003
  rounds             +2
  communication    +256
  duplicates       +215
  computation      +128
  hard failures       0
~~~

F3 therefore closes as a **PASS** with a mechanistic qualification:

~~~text
blind probabilistic/round-indexed gating:
  LIMITATION

state-aware knowledge/staleness gating:
  PASS
~~~

The architectural consequence is recorded in ADR 0003:

~~~text
communication policy:
  theta=(n,e,r,u)

local inference control:
  separate deterministic state-aware controller
~~~

The validated controller refreshes when no cache exists, local knowledge has
changed, the cached action became invalid, or it is decision-stale because
unsent local facts remain while its selected facts are already sent.
Otherwise the cached action may be reused.

Detailed evidence is frozen in `docs/f3-local-inference-control.md`.

Canonical verdict:

~~~text
F3 PASS:
state-aware local inference control reduces fresh inference while preserving
zero-failure validation and hard-holdout behavior
~~~

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

### F4 completion record — 2026-08-29

The canonical 86-population live-model experiment completed successfully.

Frozen identities:

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

byte_identical_replay: yes
backend_errors: 0
token_budget_violations: 0
~~~

All deterministic controls passed:

~~~text
ring: 3/3
grid: 3/3
~~~

Primary state-aware mixed-population result:

~~~text
ring / cfg_constrained:
  9/9 success
  invalid=0

grid / cfg_constrained:
  9/9 success
  invalid=0

ring / typed_unconstrained:
  6/9 success
  invalid=30

grid / typed_unconstrained:
  3/9 success
  invalid=65
~~~

Model-only diagnostic:

~~~text
ring / cfg_constrained: 9/9
grid / cfg_constrained: 9/9
ring / typed_unconstrained: 0/9
grid / typed_unconstrained: 0/9
~~~

The trajectory-diversity condition also passed. Fixed mixed environments
produced multiple successful semantic trajectory hashes across sampling seeds.

Canonical verdict:

~~~text
F4 PASS: heterogeneous model-backed operator evidence complete
~~~

Architectural consequence:

~~~text
model-backed operators remain untrusted policy adapters;
Starlings retains deterministic authority over parsing,
semantic validation, topology, transitions, accounting and success.
~~~

This is recorded in ADR 0004.

The strong CFG result is retained as evidence for this tested model/protocol
pair, not generalized into a universal requirement for all future model
adapters.

Detailed evidence is frozen in
`docs/f4-heterogeneous-model-operators.md`.

## Ordering and dependencies

~~~text
S0  experiments repository bootstrap
    |
    +-> F1a deterministic fault matrix          (pure Zig)
    |     |
    |     +-> F1b P2Panda candidate             (runtime limitation)
    |           |
    |           +-> F1c zquic candidate         (pure Zig, PASS)
    |
    +-> F2 asynchrony gap + scaling             (pure Zig, delete after)
    |
    +-> F3 inference control                    (pure Zig)
    |
    +-> F4 heterogeneous operators              (llama.cpp + weights)
~~~

F1a is the prerequisite for the real-transport candidate sequence. F1b
records the P2Panda runtime limitation; F1c records the validated thin zquic
replacement. F2 and F3 remain independent of the transport candidate. F4
last, because it carries the most external dependencies.

## Exit criteria for the run

The finalization run is complete when:

1. S0 reproduces the frozen Stage 7C dataset byte-for-byte through the
   package dependency;
2. F1a is frozen with complete fault attribution;
3. F1b has its P2Panda runtime limitation recorded and F1c has a frozen
   PASS/LIMITATION verdict for the replacement real-transport candidate;
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

### Finalization run status

As of 2026-08-29 all seven exit criteria are satisfied.

~~~text
S0   PASS
F1a  PASS
F1b  measured P2Panda runtime limitation
F1c  PASS
F2.1 PASS
F2.2 PASS
F3a  LIMITATION
F3b  PASS
F3   PASS
F4   PASS
~~~

The finalization run is therefore **complete**.
