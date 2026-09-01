# Hosted Harbor integration

This directory exposes three ACP agents for a controlled Starlings architecture
evaluation in Hosted Harbor.

| Condition | Agent manifest | Model |
| --- | --- | --- |
| A | `harbor-agent-baseline.json` | Hosted model selected by Harbor |
| B | `harbor-agent-starlings.json` | The exact same hosted model |
| C | `harbor-agent-deterministic.json` | None |

## Experimental control

A and B share:

- the same ACP terminal execution path;
- the same model-selection contract;
- the same `HOSTED_INFERENCE_URL` / `HOSTED_INFERENCE_TOKEN`;
- the same decision prompt and parser;
- the same bounded observation history;
- the same turn and terminal-output budgets.

The architectural difference is that A calls the decision function directly,
while B injects task/history observations into the real Zig
`starlings.Population` / `starlings.Agent` runtime. The model-backed planner is
a Starlings external operator and is reactivated by input revision changes.

C uses the same Zig runtime and ACP terminal executor but replaces the hosted
planner with a deterministic external operator. It never reads hosted inference
credentials and Harbor should launch it without a `model_name`.

## Hosted Harbor source configuration

Use the repository root as the source path so the Zig bridge can compile against
the exact Starlings revision Harbor pins:

```json
{
  "name": "acp",
  "source": {
    "type": "github",
    "repo": "beaglabs/starlings",
    "ref": "<commit-or-branch>",
    "path": ".",
    "manifest": "integrations/harbor/harbor-agent-starlings.json"
  },
  "model_name": "<provider>/<model>",
  "secrets": ["<PROVIDER_API_KEY>"]
}
```

For A, change the manifest to `harbor-agent-baseline.json`. Keep
`model_name` and `secrets` identical.

For C:

```json
{
  "name": "acp",
  "source": {
    "type": "github",
    "repo": "beaglabs/starlings",
    "ref": "<same-commit>",
    "path": ".",
    "manifest": "integrations/harbor/harbor-agent-deterministic.json"
  },
  "secrets": []
}
```

## Local contract checks

```sh
uv sync --frozen --project integrations/harbor
uv run --project integrations/harbor \
  python -m unittest discover -s integrations/harbor/tests
zig build test
```

`zig build test` also compiles `starlings-harbor-bridge`.

## Starlings wire boundary

The external operator protocol rejects commas and newlines in text values.
Arbitrary benchmark instructions, history, shell commands, and answers therefore
cross that boundary as base64-encoded text variables:

```text
task.b64
history.b64
action.b64
final.b64
```

The encoding is transport-only; decoded task/history passed to the model are the
same strings used by condition A.
