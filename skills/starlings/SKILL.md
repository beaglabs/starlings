---
name: starlings
description: Author and modify Starlings controlled-emergence populations using the SDK and YAML operator contracts.
---

# Starlings population authoring

Use this skill when creating, reviewing, or modifying a Starlings population.

## Core rule

A population declares capabilities and epistemic dependencies. It never declares
a workflow.

Never add operator-order fields such as:

- `workflow`
- `steps`
- `next`
- `after`
- `depends_on_operator`

If one capability must become applicable after another contributes evidence,
express that relationship through typed variables or invariants in
`requires`/`provides`.

## Population files

Keep the existing YAML structure:

```text
pack.yaml
variables.yaml
invariants.yaml
operators.yaml
```

Variables are the typed epistemic medium shared by the population. Prefer clear
names such as `method.candidate`, `resource.gpu`, `validation.error`, and
`candidate.executable`.

Use `retain_all_conflict` when independent operators should be allowed to
disagree rather than silently overwrite one another.

## Operator roles

Choose the role that describes the capability:

- `model`: learned inference or interpretation
- `collector`: observes the environment and introduces evidence
- `tool`: bounded callable computation
- `transform`: deterministic or general state transformation
- `validator`: independently checks claims or artifacts
- `actor`: proposes an external effect/action

Role is semantic metadata. Execution still obeys the same operator contract.

## Runtime adapters

Use:

- `native` for host-linked Zig/native capabilities
- `python` for supervised Python operators
- `subprocess` for supervised argv processes
- `model` for a host-injected shared model provider

For model operators, prefer multiple logical operators sharing one named model
provider over loading duplicate weights. Differentiate them through profiles,
requirements, provided variables, local evidence, and validation policy.

Example:

```yaml
- name: interpreter
  role: model
  runtime:
    kind: model
    target: shared-local
    profile: interpreter
  requires:
    variables:
      - source.text
  provides:
    variables:
      - method.candidate
```

## Model safety boundary

A model operator is not a global planner. Do not implement model-driven calls to
other operators. A model returns claims/invariants/artifacts/actions; those
outputs alter state and may independently make other operators eligible.

## SDK usage

Prefer the high-level `Population` and `Agent` APIs. Applications inject
observations and call `Agent.step()` when they want local progress. Do not
reintroduce a CLI as the primary runtime surface.

Use the lower-level Runner only for reference-semantics tests, replay, or formal
experiments.

## Acceptance checks

For repository changes run:

```sh
zig test src/root.zig
zig build test
python3 -m unittest discover -s python -p 'test_*.py'
```

For emergence-oriented tests, prefer fixtures that prove at least one of:

- two independent operators can disagree on one variable;
- failure/conflict makes a different validator or capability eligible;
- several logical model operators share one physical provider;
- a collector changes eligibility by introducing new evidence;
- no operator directly invokes another operator.
