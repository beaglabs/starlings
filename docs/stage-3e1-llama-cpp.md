# Stage 3E.1 — llama.cpp live CFG trial runner

Stage 3E.1 is the first live-model experiment for the Stage 3 CFG candidate.

It intentionally separates:

- **transport** — a small stdlib-only Python runner that talks to llama.cpp;
- **evidence** — raw paired trial records;
- **evaluation** — the existing Zig protocol parser/evaluator.

No real-model conclusion is committed in this stage. The result of the live run determines whether CFG proceeds toward promotion, revision, or rejection.

## Experiment

For every seed and workflow, the runner sends two requests to the same llama.cpp model:

```text
same model
same workflow
same prompt
same seed
same sampler settings
same token budget

typed_unconstrained
        vs
cfg_constrained
```

The constrained request adds exactly one treatment field:

```json
"grammar": "<contents of grammars/starlings.gbnf>"
```

The unconstrained request does not contain a `grammar` field.

Both modes receive the same explicit protocol specification in the prompt:

```text
You communicate using only this protocol vocabulary:
OBSERVE
QUERY
CLAIM
EVIDENCE
PROPOSE
ACCEPT
REJECT
CHALLENGE
RETRACT
DELEGATE

Valid interaction forms are:
OBSERVE CLAIM
QUERY EVIDENCE
PROPOSE ACCEPT
PROPOSE REJECT
CHALLENGE RETRACT
DELEGATE QUERY EVIDENCE EVIDENCE
...
Task:
<workflow-specific task>
```

This removes a confound discovered in the first smoke run: previously the constrained decoder implicitly knew the terminal vocabulary through the grammar while the unconstrained model prompt did not.

The runner uses llama.cpp's OpenAI-compatible:

```text
POST /v1/chat/completions
```

and sends identical generation controls in both modes:

```json
{
  "cache_prompt": false,
  "reasoning_effort": "none",
  "chat_template_kwargs": {
    "enable_thinking": false
  }
}
```

Reasoning is disabled deliberately so the shared completion-token budget measures visible protocol generation rather than hidden/thinking output. The constrained arm still differs only by the additional `grammar` field.

## GBNF

`grammars/starlings.gbnf` is the llama.cpp form of the Stage 3C grammar:

```text
root ::= session
session ::= interaction (" " interaction)*
interaction ::= claim-batch | observe-claim | query-evidence | propose-decision | challenge-retract | delegation
claim-batch ::= "CLAIM" (" CLAIM")*
observe-claim ::= "OBSERVE CLAIM"
query-evidence ::= "QUERY EVIDENCE"
propose-decision ::= "PROPOSE " decision
decision ::= "ACCEPT" | "REJECT"
challenge-retract ::= "CHALLENGE RETRACT"
delegation ::= "DELEGATE QUERY EVIDENCE EVIDENCE"
```

## Why the runner is Python

HTTP/provider transport is not part of the Starlings mathematical core.

The runner uses only Python's standard library. It performs requests and records raw completions; it does not decide whether a completion is valid or whether it follows the benchmark's canonical trajectory.

Those decisions remain in Zig.

## Start llama.cpp

Use one model and one decoding slot for the first experiment:

```sh
llama-server \
  -m ./models/model.gguf \
  --port 8080 \
  -np 1 \
  -c 4096
```

A single slot reduces concurrency/scheduling noise.

The runner automatically queries `/v1/models` when `--model` is omitted.

## Validate the runner

First run its built-in request-pairing tests:

```sh
python3 tools/stage3e1_llama_cpp.py --self-test
```

Expected output:

```text
stage3e1 runner self-test passed
```

Then verify the experiment size without calling the model:

```sh
python3 tools/stage3e1_llama_cpp.py --dry-run
```

With the default 100 seeds:

```text
1200 base generations
```

because:

```text
100 seeds × 6 workflows × 2 modes = 1,200
```

## Smoke-run versioning

The original 24-generation Gemma smoke run was produced with runner version 1, before the shared protocol specification was added to the prompt. It is useful as evidence that the grammar transport worked, but it is **not comparable** to post-fix Stage 3E.1 results.

Runner version 2 records a prompt-suite SHA-256 in the metadata sidecar. Use a new TSV filename for the rerun; do not append to or resume the original smoke file.

Runner version 3 additionally disables reasoning/thinking in both A/B arms and raises the common output-token budget from 16 to 32. This follows a Gemma 4 E2B smoke run in which every unconstrained trial consumed the full 16-token budget while returning zero visible content bytes. Version 3 isolates visible protocol generation from that reasoning-budget confound.

## Run the live experiment

Example:

```sh
python3 tools/stage3e1_llama_cpp.py \
  --base-url http://127.0.0.1:8080 \
  --seeds 100 \
  --output trials/stage3e1-model-a.tsv
```

Defaults:

- first seed: `0`
- seeds: `100`
- temperature: `0.7`
- top-p: `0.9`
- top-k: `40`
- max output tokens: `32`
- grammar: `grammars/starlings.gbnf`
- one generation attempt per trial

The first Stage 3E.1 experiment deliberately uses one attempt only. This keeps the live run at exactly 1,200 base generations and measures first-try behavior directly.

## Pair ordering

Always running unconstrained first could bias latency/cache behavior.

The runner therefore alternates pair order deterministically from seed and workflow index:

```text
typed → constrained
constrained → typed
typed → constrained
...
```

The treatment itself is unchanged.

## Raw records

The runner emits the existing seven-column Stage 3E TSV shape:

```text
workflow<TAB>seed<TAB>mode<TAB>attempt<TAB>completion_tokens<TAB>latency_us<TAB>completion
```

Example:

```text
query_evidence	42	typed_unconstrained	0	6	18433	I think QUERY EVIDENCE
query_evidence	42	cfg_constrained	0	2	19102	QUERY EVIDENCE
```

Tabs, CR, LF, and backslashes inside completions are escaped so malformed output is preserved on one TSV line.

A request-level transport failure is recorded as:

```text
__BACKEND_ERROR__
```

and counted separately by the Zig evaluator.

## Run provenance

The runner also creates:

```text
<output>.meta.json
```

containing:

- model ID;
- endpoint;
- seed range;
- generation count;
- sampler parameters;
- token budget;
- reasoning effort;
- chat-template thinking setting;
- workflow list;
- grammar path;
- grammar SHA-256;
- runner version.

When `--resume` is used, this metadata must exactly match the existing run. The runner refuses to mix records produced with different experimental parameters.

## Resume an interrupted run

```sh
python3 tools/stage3e1_llama_cpp.py \
  --base-url http://127.0.0.1:8080 \
  --seeds 100 \
  --output trials/stage3e1-model-a.tsv \
  --resume
```

Already recorded workflow/seed/mode keys are skipped.

## Summarize with Zig

The authoritative summary command is:

```sh
zig run src/experiments/stage3/stage3e1_summary.zig -- trials/stage3e1-model-a.tsv
```

It reports overall and per-workflow metrics for:

- trials;
- first-try protocol validity;
- canonical trajectory match;
- grammar rejections;
- backend errors;
- completion tokens;
- generated completion bytes;
- average latency.

It also reports constrained-minus-unconstrained deltas.

`trajectory-match` is intentionally narrower than task success: it means the generated protocol sequence exactly equals the canonical fixture sequence for that workflow. A structurally valid alternative trajectory is therefore `protocol-valid` but may be `trajectory-match = false`. Stage 3E.1 does not claim that such an alternative failed the underlying task; true task success belongs to later multi-operator experiments that score resulting collective state/outcomes.

If the file contains malformed records or unbalanced typed/constrained counts, the command prints a warning and exits nonzero. Such a run should not be used for a CFG promotion decision.

## Important raw-output rule

The runner does not clean model output before recording it.

For example:

```text
I think QUERY EVIDENCE
```

is preserved as generated. The Zig evaluator will count it as a protocol-format rejection.

This is essential: silently extracting `QUERY EVIDENCE` would erase the actual unconstrained failure mode we are trying to measure.

## Tests

Run the normal Zig suite:

```sh
zig test src/root.zig
```

This includes raw TSV tests for:

- prose rejection;
- escaped whitespace;
- backend failure accounting;
- syntax-versus-task correctness;
- Stage 3E.1 base-attempt enforcement;
- compilation of the summary command.

Also run:

```sh
python3 tools/stage3e1_llama_cpp.py --self-test
```

## Initial decision criteria

Do not promote CFG merely because constrained decoding reaches 100% syntactic validity.

The first live result is favorable only if constrained decoding produces a system-level improvement such as:

- higher first-try validity;
- equal or better canonical trajectory match, interpreted only as a diagnostic;
- no workflow-specific collapse;
- no unacceptable latency/token regression.

After the first model, the strongest next step is replication on a materially different model family using the same runner and evaluator.


## Metric semantics

Stage 3E.1 separates protocol control from eventual collective outcome:

```text
protocol validity
    !=
canonical trajectory match
    !=
task success
```

- **protocol validity** asks whether the generated sequence belongs to the allowed Starlings language.
- **trajectory match** asks whether it exactly equals the benchmark's canonical fixture sequence.
- **task success** is intentionally not measured by this live syntax experiment. It will be measured in later controlled-emergence experiments from the resulting multi-operator world/state outcome.

Exact trajectory matching remains useful for diagnosing whether a model follows the canonical protocol mapping, but it must not be interpreted as the definition of successful coordination.
