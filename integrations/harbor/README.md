# Harbor integration

Starlings supports two Harbor integration surfaces:

1. **normal open-source Harbor** — the primary evaluation path, including
   Molab as the Harbor host and Daytona CPU sandboxes as task environments;
2. **ACP / Hosted Harbor** — optional compatibility for Hosted Harbor access.

Hosted Harbor is not required to evaluate Starlings.

## Primary architecture: Molab + Harbor + Daytona CPU

```text
Molab
├── Harbor CLI
├── A: BaselineAgent
├── B: StarlingsAgent
├── C: DeterministicStarlingsAgent
├── Zig Starlings runtime
└── A/B model calls → hosted inference provider
       │
       └── Harbor environment.exec()
               ↓
          Daytona CPU task sandboxes
```

There is no Daytona GPU controller and no local Docker requirement. Daytona is
only Harbor's remote task-environment provider.

### Conditions

| Condition | Harbor agent | Model |
| --- | --- | --- |
| A | `integrations.harbor.local_agents:BaselineAgent` | hosted model |
| B | `integrations.harbor.local_agents:StarlingsAgent` | exact same hosted model |
| C | `integrations.harbor.local_agents:DeterministicStarlingsAgent` | none |

A and B share the same:

- model name;
- LiteLLM provider path and credentials;
- decision prompt and parser;
- bounded history;
- shell execution surface;
- MCP helper surface;
- turn and command-output budgets.

B differs by routing task/history revisions through the real Zig
`starlings.Population` / `starlings.Agent` scheduler before the same model
decision function is activated.

C uses the same Zig bridge and deterministic population with zero model calls.

## Molab setup

From a fresh Molab shell:

```sh
git clone https://github.com/beaglabs/starlings.git
cd starlings
git switch feat/hosted-harbor-agents

python3 -m pip install -U "harbor[daytona]==0.22.0" "ziglang==0.16.0"

export DAYTONA_API_KEY='...'
export OPENAI_API_KEY='...'
```

No Docker daemon is needed in Molab.

### 1. Three-condition hello-world smoke

```sh
harbor run -c benchmarks/harbor-molab/abc-hello-world.yaml
```

This creates exactly three Daytona CPU trials: A, B and C.

### 2. One task from each first-suite benchmark

```sh
harbor run -c benchmarks/harbor-molab/abc-first-suite-smoke.yaml
```

This creates 12 trials: four matched tasks × three conditions.

### 3. Ten matched SkillsBench tasks

```sh
harbor run -c benchmarks/harbor-molab/abc-skillsbench-10.yaml
```

This creates 30 trials concurrently.

To use another model, edit **both** A and B `model_name` entries to the same
provider/model string. Never change one without the other in a controlled run.

## MCP tasks such as tau3

A and B still expose one architectural action surface: shell execution. When a
Harbor task declares a `streamable-http` MCP server, setup uploads
`mcp_bridge.py` into the Daytona sandbox and ensures the Python MCP client is
available there. The task instruction receives deterministic helper commands:

```text
python3 /tmp/starlings-harbor-mcp.py list <URL>
python3 /tmp/starlings-harbor-mcp.py call <URL> TOOL_NAME 'JSON_ARGUMENT_OBJECT'
```

This matters because service names such as `tau3-runtime` are reachable from
inside the Daytona task network, not from the Molab host.

Both A and B receive the exact same augmented instruction and MCP surface.

## Model accounting

Normal Harbor mode uses LiteLLM, already a Harbor dependency. Each model call is
recorded in a per-trial `model-usage.jsonl`; the external agents populate
Harbor's `AgentContext` with input tokens, output tokens, cache tokens and
estimated cost.

Condition C produces zero model usage.

## Local checks

```sh
python3 -m pip install -U "harbor==0.22.0" "ziglang==0.16.0"
python3 -m unittest discover -s integrations/harbor/tests
python3 -m ziglang build test
```

`zig build test` compiles `starlings-harbor-bridge`.

## Optional Hosted Harbor / ACP compatibility

The three `harbor-agent-*.json` manifests and the
`starlings_harbor.{baseline,starlings,deterministic}` ACP entrypoints remain
available for Hosted Harbor users. They are not used by the Molab workflow.

## Starlings wire boundary

The canonical external-operator protocol rejects commas and newlines in raw text
values. Arbitrary benchmark instructions, histories, commands and final answers
therefore cross the Starlings boundary as base64 text variables:

```text
task.b64
history.b64
action.b64
final.b64
```

The encoding is transport-only.
