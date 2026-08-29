# ADR 0003 — Retain the four-dimensional policy surface after F3 inference-control limitation

## Status

Accepted — 2026-08-29.

## Context

Stage 7A/7B established the validated compact local policy surface:

~~~text
theta = (n, e, r, u)
~~~

F3 tested a fifth parameter:

~~~text
theta = (n, e, r, u, c)

c = inference-gating permille
~~~

The candidate mechanism allowed each operator to either:

- refresh its local observation and compute a fresh Stage 7A action; or
- reuse its previously cached action at zero inference cost.

The canonical F3 experiment preserved historical Stage 7B provenance, passed
all `c=1000` regression checks, replayed byte-identically, and maintained
exact inference accounting.

Its canonical dataset is:

~~~text
rows: 187
SHA-256:
42e60db5b999d19319f00a254eafda0eebe3ae5c1c37a824ca155bcbd074bfb2
~~~

The validation-selected frontier contained only:

~~~text
id=3  theta=(500,0,250,1000,1000)
id=5  theta=(750,250,0,500,1000)
~~~

Both use `c=1000`: always refresh.

No candidate with `c<1000` survived feasibility-first validation Pareto
selection.

## Decision

Retain:

~~~text
theta = (n, e, r, u)
~~~

as the validated protocol policy surface.

Do **not** add the tested cached-action inference-gating parameter `c` to the
protocol core.

The F3 implementation remains experimental evidence only and may be removed
from the experiments working tree after the result is frozen, consistent with
the finalization evidence lifecycle.

## Rationale

The negative result is scientifically interpretable because:

- the historical Stage 7B reference was anchored to the canonical report;
- all 134 Stage 7B candidates reproduced through the `c=1000` corner on
  training and validation;
- the search candidate set was valid and deterministic;
- inference accounting was exact;
- the full evidence dataset replayed byte-for-byte;
- there were zero protocol violations.

Therefore the absence of a selected gated policy is not explained by harness
drift or accounting failure.

Within this parameterization, cached-action reuse reduced fresh computation
only by changing decision freshness in a way that was not competitive after
feasibility and the remaining resource dimensions were considered.

## Consequences

- The four-dimensional Stage 7A/7B policy remains authoritative.
- F4 does not depend on the F3 `c` parameter.
- Model-backed operators should initially use the validated ungated policy
  semantics.
- Future inference-control work, if pursued, should use a materially different
  trigger rather than simply widening or resampling the same `c` search.

Reasonable future mechanisms include:

- refresh on local-state change;
- refresh on newly learned facts;
- uncertainty/confidence-triggered inference;
- explicit cached-action invalidation;
- adaptive per-operator compute budgets;
- model/token-cost-aware scheduling.

Any such mechanism is a new experiment and must preserve the same corner,
determinism, accounting, and evidence discipline before promotion.

## Evidence

Detailed F3 evidence:

~~~text
docs/f3-local-inference-control.md
~~~

Canonical verdict:

~~~text
F3 LIMITATION: local inference-control evidence complete
~~~
