# starlings

Experimental infrastructure for evidence-backed mathematical agent communication and collective coordination, implemented in Zig.

## Current scope: Stage 0–1

The foundation intentionally contains only the machinery needed to run reproducible experiments and compare coordination strategies:

- deterministic operator state transitions
- a small typed message vocabulary
- bounded message queues and traces
- logical clocks and causal references
- seeded deterministic experimental entropy
- explicit capacity and routing failures
- replay-friendly execution traces
- a deterministic distributed-information benchmark
- broadcast-all, centralized, and typed point-to-point baselines
- communication metrics for messages, bytes, rounds, payload duplication, operator use, and task success
- benchmark-level sender-drop fault injection

The Stage 1 benchmark distributes five independent facts across five operators. No individual worker owns the complete solution; the benchmark measures how different communication strategies reconstruct the complete fact set at a verifier.

Higher-level structures such as Merkle DAG provenance, formal grammars, executable semantics, dynamic flocking topologies, VSAs, category-theoretic models, effect systems, and differential-geometric models are candidate architectural components. They should be integrated only after their hypotheses are experimentally validated; once validated, they become architectural commitments rather than optional features.

## Test

Using Zig 0.16.0:

```sh
zig test src/root.zig
```

The suite checks deterministic routing/state transitions, causal trace ordering, reproducible seeded entropy, duplicate-operator rejection, explicit failure for unknown recipients, baseline benchmark correctness, expected communication tradeoffs, benchmark reproducibility, and missing-information behavior under sender-drop fault injection.

## Current Stage 1 baseline

The initial benchmark intentionally favors clarity over realism. Its purpose is to validate the measurement apparatus before introducing adaptive topology or learned operators. Once these measurements are trustworthy, the same harness becomes the baseline for validating content-addressed provenance and later coordination mechanisms.
