# Process Supervision — Phase 3B

Phase 3B gives Starlings a real operating-system transport for external
operators.

Phase 3A established the replayable data/control plane. Phase 3B connects that
plane to actual Python and subprocess processes without introducing a workflow
engine.

## Execution boundary

An external invocation now follows this shape:

```text
reactive eligibility
      |
      v
operator_started
      |
      v
canonical wire request
      |
      v
supervised child process
      |
      +-- timeout ----------> operator_failed(timeout)
      +-- nonzero/crash ---> operator_failed(crash)
      +-- malformed output -> operator_failed(validation/execution)
      |
      v
canonical OperatorOutput
      |
      v
claims / invariants / artifacts / actions
      |
      v
operator_completed
```

The runtime still chooses an operator only from declared state, invariants,
eligibility, and deterministic arbitration. The supervisor does not prescribe
operator order.

## Supported invocation forms

The existing external SDK remains the protocol boundary:

- arbitrary argv subprocesses;
- Python scripts;
- Python modules.

Python invocation is translated to argv by `PythonAdapter`; both forms then
use the same process supervisor.

## Supervision guarantees

`process_supervisor.Supervisor` owns the real child-process lifecycle:

- spawn with piped stdin/stdout/stderr;
- write the complete canonical request and close stdin;
- concurrently drain stdout and stderr;
- enforce a whole-response deadline;
- bound stdout and stderr independently;
- terminate a child on timeout or over-limit output;
- wait/reap normally completed children;
- distinguish clean exit from nonzero/signal/crash termination.

The canonical runtime maps `OperatorTimeout` and `OperatorCrashed` to the
failure kinds introduced in Phase 3A.

Spawn failure and output-limit failure remain explicit execution errors rather
than being mislabeled as process crashes.

## Output lifetime

Wire-v1 responses may contain borrowed text:

- text-valued claims;
- action names;
- action payloads.

Returning an `OperatorOutput` parsed from a stack-local response buffer would
leave those slices dangling.

`BufferedExternalOperator` therefore owns persistent request and response
storage. Returned wire strings remain valid until that buffered operator is
invoked again.

A buffered operator context must outlive the Runner activation that uses it.
The current Runner is sequential; concurrent reuse of one buffered operator is
not supported.

## Diagnostics

The supervisor retains bounded stderr from the most recent completed child.
This is diagnostic data, not canonical state. It is intentionally excluded from
claim/event identity so nondeterministic diagnostic text cannot change replay.

## Phase 3B acceptance

The branch includes tests for:

- real subprocess stdin/stdout round-trip;
- nonzero exit -> `OperatorCrashed`;
- deadline expiry -> `OperatorTimeout`;
- real subprocess output parsed through `ExternalOperator`;
- persistent wire-string lifetime;
- full Runner -> supervised subprocess -> claim + approval action path.

The real subprocess tests are skipped on Windows in this initial slice because
the fixture uses `/bin/sh`. The supervisor itself uses Zig's cross-platform
`std.process` API.

## Remaining Phase 3 work

Phase 3B does not yet persist artifact bytes. Phase 3A records content-addressed
artifact emissions, but the bytes still need a durable artifact store.

The next logical slice after 3B is:

1. content-addressed artifact byte storage;
2. validation that emitted `ArtifactRef` IDs match stored bytes;
3. durable restart/replay with artifact retrieval;
4. a runnable pack/execution entry point that binds declared operators to
   native/Python/subprocess implementations.

That closes the remaining gap between the SDK substrate and a complete
heterogeneous Phase 3 execution acceptance test.
