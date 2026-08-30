# Emergence Packs v1 — Phase 1 Contract

An **Emergence Pack** is the deployable declaration of a Starlings population.

The pack declares:

- typed collective state;
- invariants over that state;
- heterogeneous operator capabilities;
- operator requirements and contributions;
- execution runtime descriptors;
- target variables;
- reserved action-policy metadata.

It does **not** declare an execution workflow.

The runtime trajectory is expected to emerge from state and operator eligibility. The following keys are deliberately rejected by the Phase 1 schema:

```text
workflow
steps
next
after
depends_on_operator
```

This is a semantic constraint, not a naming preference.

## Layout

The Phase 1 reference layout is:

```text
my-pack/
├── pack.yaml
├── variables.yaml
├── invariants.yaml
├── operators.yaml
└── policies/
    └── actions.yaml
```

The files referenced by `pack.yaml` must remain inside the pack root. Absolute paths and lexical `..` traversal are rejected.

Phase 1 uses one file per declaration class. Later pack versions may add directory expansion without changing the compiled contract.

## Manifest

```yaml
apiVersion: starlings/v1
kind: EmergencePack

metadata:
  name: coding-local
  version: 0.1.0

state:
  variables: variables.yaml
  invariants: invariants.yaml

population:
  operators: operators.yaml

policy:
  actions: policies/actions.yaml

targets:
  - patch.validated
```

`policy` is optional in Phase 1. The action-policy file is validated as a reserved pack resource; execution and approval semantics arrive with the operator/action plane.

## Variables

```yaml
variables:
  - name: task.text
    type: text
    merge: latest

  - name: task.embedding
    type: artifact_ref

  - name: patch.validated
    type: boolean
```

Supported value types map directly to SDK `ValueKind`:

```text
integer
float
boolean
text
artifact_ref
```

Supported merge policies map directly to SDK `MergePolicy`:

```text
latest
highest_confidence
retain_all_conflict
```

A variable may also declare `unit` and `freshness_rounds`.

## Invariants

```yaml
invariants:
  - name: candidate.compiles
    requires:
      - candidate.patch
      - compile.status
```

Phase 1 compiles invariant requirements to SDK variable IDs. It does not prescribe how the invariant is established; an operator may later contribute an `InvariantClaim`.

## Operators

```yaml
operators:
  - name: compiler
    runtime:
      kind: subprocess
      target: tools/compile_candidate

    requires:
      variables:
        - candidate.patch

    provides:
      variables:
        - compile.status
      invariants:
        - candidate.compiles
```

Phase 1 runtime kinds are:

```text
native
python
subprocess
```

`python` and `subprocess` require a non-empty `target`. Phase 1 only validates and preserves the runtime descriptor; process supervision belongs to Phase 3.

An operator may require/provide variables and invariants. These names compile to the existing SDK `OperatorManifest`.

There is intentionally no operator-to-operator edge. For example:

```yaml
after:
  - repo-search
```

is invalid. The equivalent Starlings declaration is that the later operator requires state that `repo-search` is capable of providing.

## Deterministic compiled IDs

Pack names are compiled into stable `u32` SDK identifiers using domain-separated BLAKE3:

```text
variable  -> BLAKE3("starlings-pack-variable-v1"  || 0x00 || name)
invariant -> BLAKE3("starlings-pack-invariant-v1" || 0x00 || name)
operator  -> BLAKE3("starlings-pack-operator-v1"  || 0x00 || name)
```

The low 32 bits are used as the SDK ID, with zero reserved. Collisions within a namespace fail closed.

This means reordering declarations does not silently change identity.

## Validation

Build the CLI:

```sh
zig build
```

Validate the included example:

```sh
zig-out/bin/starlings pack validate examples/packs/coding-local
```

or:

```sh
zig build run -- pack validate examples/packs/coding-local
```

Expected shape:

```text
VALID coding-local@0.1.0 variables=7 invariants=2 operators=5 targets=1
```

Inspect the compiled population:

```sh
zig-out/bin/starlings pack inspect examples/packs/coding-local
```

The inspector reports the variables, invariants, operators, runtime kinds, dependency counts, targets, and deterministic IDs.

## Fail-closed behavior

Phase 1 rejects:

- unsupported `apiVersion` or `kind`;
- unknown YAML schema fields;
- authored workflow keys;
- missing required manifest fields;
- duplicate variables, invariants, operators, dependencies, or targets;
- references to unknown variables/invariants/targets;
- invalid external runtime descriptors;
- pack references that escape the pack root;
- declaration counts beyond fixed contract limits;
- deterministic identifier collisions.

Phase 1 uses a small purpose-built YAML subset parser inside Starlings rather than depending on a third-party YAML package. The parser accepts only the mapping/list/scalar shapes used by the pack contract and fails closed on unknown structure, tabs, malformed indentation, malformed quoting, and unsupported fields.

The protocol/SDK core remains directly testable with:

```sh
zig test src/root.zig
```

The pack parser, compiler, CLI, and reference-pack gate run through:

```sh
zig build test
```

## Phase 1 acceptance gate

Phase 1 is complete when:

1. a real YAML pack is parsed;
2. the schema rejects workflow edges and unknown structure;
3. declarations compile into existing SDK `Variable`, `Invariant`, `RegisteredOperator`, and target IDs;
4. dangling or duplicate declarations fail deterministically;
5. `starlings pack validate` and `starlings pack inspect` work on the reference pack;
6. direct protocol-core tests remain independent of pack-file parsing.

Execution is deliberately not part of Phase 1. Reactive scheduling begins in Phase 2.
