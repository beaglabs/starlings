# starlings

Experimental infrastructure for evidence-backed mathematical agent communication and collective coordination, implemented in Zig.

## Current scope: Stage 0

The initial foundation intentionally contains only the machinery needed to run reproducible experiments:

- deterministic operator state transitions
- a small typed message vocabulary
- bounded message queues and traces
- logical clocks and causal references
- seeded deterministic experimental entropy
- explicit capacity and routing failures
- replay-friendly execution traces

Higher-level structures such as Merkle DAG provenance, formal grammars, executable semantics, dynamic flocking topologies, VSAs, category-theoretic models, effect systems, and differential-geometric models are candidate architectural components. They should be integrated only after their hypotheses are experimentally validated; once validated, they become architectural commitments rather than optional features.

## Test

Using Zig 0.16.0:

```sh
zig test src/root.zig
```

The Stage 0 test suite checks deterministic routing/state transitions, causal trace ordering, reproducible seeded entropy, duplicate-operator rejection, and explicit failure for unknown recipients.
