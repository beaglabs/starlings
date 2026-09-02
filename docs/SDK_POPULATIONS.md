# SDK-First Populations

Starlings is an embeddable SDK for controlled-emergent populations. YAML declares
state and operator capability contracts; applications own lifecycle, persistence,
model backends, process bindings, transport, and user experience.

The SDK deliberately does not expose a workflow language. Operators declare only
what they require and what they can provide. Authored keys such as `workflow`,
`steps`, `next`, `after`, and `depends_on_operator` remain forbidden.

## Public surface

The high-level types are exported at the package root:

```zig
const starlings = @import("starlings");

var population = try starlings.Population.load(
    io,
    gpa,
    arena,
    "population",
);

var agent = try starlings.Agent.init(
    io,
    gpa,
    arena,
    &population,
    42,
    .{ .models = model_providers, .native = native_bindings },
);
defer agent.deinit();

_ = try agent.observe(.{
    .name = "source.text",
    .status = .observed,
    .value = .{ .text = "..." },
});

while (try agent.step() == .progress) {}
```

`Agent.step()` is the deterministic single-node reference semantics. It is a
host-controlled primitive, not a product-level "run to completion" workflow.
Long-lived applications may interleave observations, actions, persistence and
future peer communication between steps.

## Operator roles

An operator may declare semantic metadata independently from its execution
adapter:

```yaml
operators:
  - name: method-interpreter
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

  - name: resource-observer
    role: collector
    runtime:
      kind: native
      target: host-resources
    provides:
      variables:
        - resources.memory

  - name: equation-check
    role: validator
    runtime:
      kind: python
      target: operators/check.py
    requires:
      variables:
        - method.candidate
    provides:
      variables:
        - method.valid
```

Supported roles are `model`, `collector`, `tool`, `transform`,
`validator`, and `actor`. Roles do not create a scheduler or change the
requires/provides semantics.

Supported runtime adapters are `native`, `python`, `subprocess`, and
`model`.

## Shared model providers

A model runtime names a host-injected `ModelProvider`. Multiple logical model
operators may bind to one provider:

```text
                     one resident model
                           |
              +------------+------------+
              |                         |
       interpreter operator       skeptic operator
       profile=interpreter        profile=skeptic
              |                         |
              +-------- typed claims ---+
```

The operators remain distinct because each activation has a different operator
identity, profile, declared observations, provided capabilities and event
history. The model provider does not receive planner privileges and cannot
invoke another Starlings operator. It can only return an `OperatorOutput`.

This allows a small machine to host a large logical population without loading
one copy of the weights per operator.

## External operators

Python and subprocess operators use the supervised external wire boundary.
Requests contain only declared readable variables/invariants plus the stable IDs
the operator is authorized to provide:

```text
STARLINGS/1 REQUEST
operator=<id>
round=<round>
var=<id>,<status>,<typed-value>
inv=<id>,<status>
provide_var=<id>
provide_inv=<id>
END
```

No external operator receives an authored next-step instruction.

## Persistence

The existing event sink, durable run store, content-addressed artifact store,
action approval and replay APIs remain available through the SDK. Removing the
CLI does not remove durable replay; it removes the command-line product surface.

## Architectural boundary

This phase remains a deterministic, single-node reference implementation.
Future decentralized work should introduce local Agent state and peer claim
exchange without changing the YAML rule that global operator order is not
authored.
