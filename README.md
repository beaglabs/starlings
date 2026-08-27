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
- deterministic distributed-information benchmarks
- broadcast-all, centralized, and typed point-to-point baselines
- communication metrics for messages, bytes, rounds, payload duplication, operator use, and task success
- seeded randomized fact placement
- partitioned and overlapping/redundant task shapes
- deterministic per-message loss injection
- whole-worker failure injection
- aggregate benchmark summaries across seed ranges

Stage 1 currently uses five workers and a verifier. The partitioned task assigns one independent fact to each worker, while the overlapping task gives each worker two facts so that every fact exists at two workers. This lets the harness distinguish raw communication efficiency from resilience under information loss.

Higher-level structures such as Merkle DAG provenance, formal grammars, executable semantics, dynamic flocking topologies, VSAs, category-theoretic models, effect systems, and differential-geometric models are candidate architectural components. They should be integrated only after their hypotheses are experimentally validated; once validated, they become architectural commitments rather than optional features.

## Test

Using Zig 0.16.0 or a compatible newer compiler:

```sh
zig test src/root.zig
```

The suite checks deterministic routing/state transitions, causal trace ordering, reproducible seeded entropy, duplicate-operator rejection, explicit failure for unknown recipients, both Stage 1 task shapes, expected baseline communication tradeoffs, randomized placement reproducibility, sender-drop and worker-loss behavior, deterministic message loss, and aggregate multi-seed benchmark reproducibility.

## Stage 1 validation goals

The benchmark intentionally favors controlled experiments over realism. Before validating Merkle-DAG provenance, Stage 1 should establish that the measurement apparatus can reliably distinguish:

- successful from incomplete collective solutions
- useful transmission from duplicated information
- centralized from direct and broadcast communication costs
- brittle partitioned knowledge from deliberately redundant knowledge
- single-run behavior from aggregate behavior across seed ranges
- normal execution from deterministic message and operator failures

Once these measurements are trustworthy, the same harness becomes the baseline for asking whether content-addressed provenance measurably reduces redundant communication, improves synchronization/replay, or otherwise earns architectural integration.
