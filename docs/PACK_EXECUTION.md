# Pack Execution — Phase 3D

Phase 3D binds a compiled Emergence Pack to the Phase 3 runtime and adds the
first real pack execution entry point:

```text
starlings run <pack-dir> [--set name=value]... [--seed N] [--max-activations N]
```

The pack remains declarative. It declares state, invariants, operator
capabilities, runtime implementations, policy surfaces, and goals. It does not
declare operator order or workflow edges.

## Execution path

```text
pack.yaml + state/population files
        |
        v
load + compile
        |
        v
bind implementations
  native      -> host NativeBinding registry
  python      -> supervised Python process
  subprocess  -> supervised argv process
        |
        v
Runner configuration snapshot
        |
        +--> durable event store
        +--> durable artifact store
        |
        v
typed seed observations
        |
        v
reactive eligibility + deterministic arbitration
        |
        v
operator activations
        |
        v
canonical claims / invariants / artifacts / actions
        |
        v
target outcome
```

The CLI never schedules one operator after another. Operator activation remains
a consequence of the Runner's declared-variable/invariant eligibility rules.

## Runtime declarations

Runtime declarations now support a bounded timeout and subprocess argv:

```yaml
runtime:
  kind: subprocess
  target: /usr/bin/env
  timeout_ms: 5000
  args:
    - python3
    - ./operators/check.py
```

Rules:

- `python` requires `target` and currently uses the default Python
  interpreter with script mode.
- `subprocess` requires `target` and may declare up to the bounded runtime
  argument capacity.
- `native` may use `target` as a host binding name. If omitted, the operator
  name is the binding name.
- runtime timeouts must be positive.
- authored workflow keys remain forbidden.

For runtime arguments, an argument beginning with `./` is resolved relative
to the pack directory. Other arguments are passed literally.

## Native bindings

A generic CLI executable cannot invent or dynamically discover linked Zig
functions. Native implementations are therefore explicit host bindings:

```zig
const bindings = [_]pack_runtime.NativeBinding{
    .{
        .name = "my-native-binding",
        .context = &context,
        .execute_fn = MyOperator.execute,
    },
};
```

A pack with:

```yaml
runtime:
  kind: native
  target: my-native-binding
```

is bound to that implementation by the embedding host.

The generic `starlings run` CLI supplies no application-specific native
bindings. If a pack contains an unbound native operator, execution fails closed
with `UnboundNativeOperator`.

Python/subprocess-only packs can run directly from the generic CLI.

## External wire execution context

Phase 3D extends the existing wire-v1 request compatibly.

External operators now receive:

```text
STARLINGS/1 REQUEST
operator=<operator-id>
round=<logical-round>
var=<variable-id>,<status>,<typed-value>
inv=<invariant-id>,<status>
provide_var=<authorized-output-variable-id>
provide_inv=<authorized-output-invariant-id>
END
```

The `provide_*` records solve an important binding problem: implementations
do not need to hardcode Starlings' stable hashed IDs for their output
capabilities.

The Python helper exposes these as:

```python
ctx["variables"]
ctx["invariants"]
ctx["provides"]["variables"]
ctx["provides"]["invariants"]
```

Existing wire callers remain valid because the new records are only added by
the execution-aware request builder.

## Typed CLI inputs

`--set name=value` is parsed according to the variable declaration:

- `integer`
- `float`
- `boolean` using `true` / `false`
- `text`
- `artifact_ref` using a 64-character content ID

Inputs become canonical observed claims after the durable run is created and
its event/artifact sinks are attached.

Example:

```sh
starlings run examples/packs/phase3-run \
  --set input.value=7 \
  --seed 1 \
  --max-activations 8
```

A successful execution prints the durable run ID, outcome, event head, and
each declared target.

## Durability order

The CLI performs execution setup in this order:

1. load and compile the pack;
2. bind all operator implementations;
3. snapshot the immutable Runner configuration into a new durable run;
4. attach the artifact verifier;
5. attach the event sink;
6. append typed seed observations;
7. execute until quiescence or the activation budget.

This ensures every state transition after the configuration snapshot is
represented in the append-only event stream.

## Runnable example

`examples/packs/phase3-run` is an external-only CLI example:

```text
input.value
    |
    v
python-derive
    |
    v
python.value
    |
    v
subprocess-check
    |
    v
final.ok
```

That diagram describes the emergent dependency structure for explanation only.
The pack itself contains no workflow edge. The runtime derives eligibility from
the variables declared in `requires` and `provides`.

The subprocess operator uses an argv declaration rather than a shell command
string.

## Full heterogeneous acceptance

The Phase 3D SDK test exercises a single durable Runner containing:

- a host-linked native operator;
- a supervised Python operator;
- a supervised generic subprocess operator;
- variable dependencies;
- an invariant produced by native code and carried across the external wire;
- durable event persistence;
- final target success.

Expected state progression for the fixture is:

```text
input.value = 6
native.value = 7
native.ready = satisfied
python.value = 8
final.ok = true
```

Again, this progression emerges from eligibility. No authored operator ordering
is stored in the pack.

## Phase 3D acceptance

The slice is complete when all of the following pass on Zig 0.16.0:

```sh
zig test src/root.zig
zig build test
python3 -m unittest discover -s python -p 'test_*.py'
```

and the runnable external example succeeds with:

```sh
zig build run -- run examples/packs/phase3-run --set input.value=7 --seed 1 --max-activations 8
```

The expected target is:

```text
TARGET final.ok status=derived value=true
```

At that point Phase 3 has a complete executable path from declarative pack
through heterogeneous operator execution, canonical data/control-plane events,
durable run persistence, artifact verification, and replay.
