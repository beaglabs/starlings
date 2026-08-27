# starlings

Experimental infrastructure for evidence-backed mathematical agent communication and collective coordination, implemented in Zig.

## Current scope: Stage 0–3E

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

Formal grammars remain a candidate architectural component under active Stage 3 validation: deterministic corpus, composition, stress, and encoding gates have passed locally, while model-backed constrained-generation evidence is still pending. Executable semantics, dynamic flocking topologies, VSAs, category-theoretic models, effect systems, and differential-geometric models also remain candidate components. Candidates should be integrated only after their hypotheses are experimentally validated; once validated, they become architectural commitments rather than optional features.

## Test

Using Zig 0.16.0 or a compatible newer compiler:

```sh
zig test src/root.zig
```

The suite covers deterministic runtime behavior, Stage 1 coordination benchmarks, provenance validation, duplicate-heavy provenance histories, fork/merge causal closure, replica divergence, content identity sensitivity, protocol trace analysis, deterministic workflow diversity, CFG parsing/encoding, CFG stress/generalization, and the Stage 3E model-evaluation machinery.
