# ADR 0003 — Separate state-aware inference control from communication policy

## Status

Accepted — 2026-08-29.

## Context

Stage 7A/7B established the validated local communication-policy surface:

~~~text
theta = (n, e, r, u)
~~~

F3 tested whether local computation/inference should become a fifth policy
dimension.

F3a tried:

~~~text
theta = (n, e, r, u, c)
~~~

where `c` probabilistically/deterministically gated fresh inference and
otherwise reused a cached action.

That mechanism completed as a valid limitation: the validation frontier
preferred `c=1000`, or always-refresh behavior.

F3b then isolated inference control from communication policy. It held frozen
Stage 7B ids 37/51/93 fixed and compared deterministic state-aware controllers
against exact always-refresh twins.

The canonical F3b dataset is:

~~~text
rows: 85
SHA-256:
eb4237fdf5e6ac309b29f01c16345f9ff6507b8806ab986b15fbb3c9e080347a
~~~

The plain `knowledge_or_stale` controller was promoted for all three frozen
base policies with lower inference and zero failures across every hard
holdout.

## Decision

Keep the communication policy surface:

~~~text
theta = (n, e, r, u)
~~~

Do **not** add a probabilistic inference-gating parameter to theta.

Add local inference control as a separate deterministic controller.

The validated controller refreshes when:

~~~text
no cached action exists
OR local knowledge changed since last inference
OR the cached action became structurally invalid
OR the cached action is decision-stale:
     unsent local facts remain
     AND cached selected facts are already sent
~~~

Otherwise the operator may reuse the cached action without spending a fresh
inference unit.

## Rationale

This separation is supported directly by the paired experiment.

For frozen Stage 7B bases 37 and 51, `knowledge_or_stale` preserved identical
validation completion time and policy-call count while reducing both inference
and communication.

Most notably, base 51 achieved:

~~~text
inference delta     = -1559
communication delta = -2148
duplicate delta     = -2147
rounds delta        = 0
computation delta   = 0
hard failures       = 0
~~~

Base 93 also reduced inference by 1003 units and remained zero-failure on all
hard sets, though with modest increases in rounds, communication, duplicates
and policy calls. That tradeoff remained Pareto-relevant rather than being
silently scalarized away.

The age4/age8 variants did not improve canonical validation measurements over
plain `knowledge_or_stale`, so the simpler controller is preferred.

## Consequences

- The compact communication policy remains four-dimensional.
- Inference scheduling is a separate local mechanism rather than a theta
  parameter.
- Every policy opportunity must remain exactly accounted as fresh inference or
  cache reuse.
- Cache reuse is allowed only while the cached action remains valid and
  decision-relevant under current local state.
- F4 model-backed operators should begin with this state-aware controller as
  the validated local inference-control candidate, while retaining an
  always-refresh control arm.
- Future uncertainty/model-confidence/token-cost controls are additional
  controller experiments, not extensions of the communication theta by
  default.

## Evidence

F3a negative control:

~~~text
SHA-256:
42e60db5b999d19319f00a254eafda0eebe3ae5c1c37a824ca155bcbd074bfb2
~~~

F3b successful state-aware control:

~~~text
SHA-256:
eb4237fdf5e6ac309b29f01c16345f9ff6507b8806ab986b15fbb3c9e080347a
~~~

Detailed evidence:

~~~text
docs/f3-local-inference-control.md
~~~

Canonical conclusion:

~~~text
F3 PASS:
state-aware local inference control is validated as a separate controller
layer above the four-dimensional communication policy
~~~
