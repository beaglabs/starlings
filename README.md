# starlings

Evidence-backed mathematical agent communication and collective coordination.

This repository is the protocol core: the operator-neutral coordination
substrate, the typed message vocabulary, content-addressed provenance, and
the formal protocol machinery. The staged experiment programs (Stages 0–7C)
that validated this core are complete; their code has been removed from this
tree and their evidence lives in `docs/` and in git history.

## What is in this repository

- deterministic operator state transitions with seeded experimental entropy
- a small typed message vocabulary
  (OBSERVE, QUERY, CLAIM, EVIDENCE, PROPOSE, ACCEPT, REJECT, CHALLENGE,
  RETRACT, DELEGATE)
- bounded message queues, logical clocks, replay-friendly execution traces,
  and explicit capacity/routing failures
- content-addressed causal provenance (BLAKE3, Merkle-DAG closure,
  replica divergence accounting)
- context-free protocol grammar parsing, malformed-sequence rejection,
  stress/generalization, and encoding measurement
- provider-agnostic model-evaluation record/summary machinery for
  grammar-constrained decoding experiments
- the operator-neutral formal population substrate
  `P = (A, G, X, M, F, Pi, C, Phi, J)` with pluggable local policies

## Validated architecture: content-addressed provenance

Stage 2 validated content-addressed causal DAG provenance and promoted it into
the required Starlings architecture.

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

See `docs/adr/0001-content-addressed-provenance.md` for the architectural
decision and `docs/adr/0002-operator-neutral-coordination-core.md` for the
operator-neutral core decision.

## Test

Using Zig 0.16.0 or a compatible newer compiler:

```sh
zig test src/root.zig
```

The suite (62 tests) covers the deterministic runtime, message routing,
seeded entropy, provenance validation and stress, fork/merge causal closure,
replica divergence, protocol traces and workflows, CFG parsing/stress, and
the model-evaluation record/summary machinery. CI runs the same command on
every push.

## Stage history and evidence

Stages 0–7C were executed against this core and are fully recorded:

- `docs/STAGES.md` — the staged research plan and validation protocol.
- `docs/stage-*.md` — per-stage reports with frozen canonical dataset
  hashes and conclusions (Stage 5A scaling, 5B predictive laws, 5C regime
  boundaries, 6/6.1 perturbation and robustness law, 7A parameterized
  policy, 7B policy search and generalization, 7C deterministic
  asynchronous transfer).
- `docs/adr/` — architectural decisions.

Experiment source code and CLIs were removed from this tree after Stage 7C
closed. Every canonical dataset is regenerable from the documented commands
and seeds at the corresponding commit in git history; dataset hashes in the
stage docs pin the evidence.

## Repository layout

~~~text
src/
  root.zig                 test/import root
  core/                    deterministic runtime and formal population substrate
  protocol/                typed protocol, CFG, traces, and model-eval machinery
  provenance/              content-addressed causal provenance

grammars/                  constrained-generation grammars
docs/                      stage reports and architecture decisions
modules/                   optional candidate integrations; not core deps
trials/                    local generated outputs only; ignored by Git
~~~

Generated trial outputs are intentionally kept out of version control;
canonical hashes and scientific conclusions belong in the stage
documentation.


## Optional modules

Candidate transport/runtime integrations live under `modules/` and are kept
outside the protocol-core dependency graph. The preserved P2Panda adapter lives
under `modules/p2panda/` with its own Rust toolchain and a frozen Zig
experiment snapshot.
