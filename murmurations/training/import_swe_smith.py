"""Import execution-grounded SWE-smith ATIF trajectories into Murmurations episodes.

The source is the Agent Data Protocol standardized SWE-smith split.  Import is
pure transformation: no repository checkout, sandbox, test execution, or LLM is
required.  Only source trajectories marked resolved are admitted.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
from typing import Any, Iterable
import urllib.error
import urllib.parse
import urllib.request

from murmurations.training.environments.episodes import Episode, EpisodeBuilder
from murmurations.training.operator_retrieval import OperatorDescriptor, OperatorRegistry
from murmurations.utils.canonical import canonical_id
from murmurations.utils.protocol import ArgumentKind, Operation


DEFAULT_DATASET = "neulab/agent-data-collection"
DEFAULT_CONFIG = "swe-smith"
DEFAULT_SPLIT = "raw"
DEFAULT_REVISION = "17f755bd6c6588d98a91ae6512576d9772919ab2"


_TEST_RE = re.compile(
    r"(?:^|[;&|]\s*)(?:python\d*\s+-m\s+pytest|pytest|tox|nox|"
    r"cargo\s+test|go\s+test|zig\s+build\s+test|"
    r"(?:npm|pnpm|yarn)\s+(?:run\s+)?test|mvn\s+.*test|gradle\s+.*test)",
    re.IGNORECASE,
)
_TYPE_RE = re.compile(
    r"(?:mypy|pyright|tsc(?:\s|$)|cargo\s+check|go\s+vet|"
    r"zig\s+build\s+check|ruff\s+check|eslint(?:\s|$))",
    re.IGNORECASE,
)
_SEARCH_RE = re.compile(
    r"(?:^|[;&|]\s*)(?:rg|grep|git\s+grep|find|fd|"
    r"cat|head|tail|sed\s+-n|awk)(?:\s|$)",
    re.IGNORECASE,
)
_METADATA_RE = re.compile(
    r"(?:cargo\s+metadata|go\s+list\s+-m|npm\s+pkg\s+get|"
    r"pip\s+show|python\d*\s+-m\s+pip\s+show)",
    re.IGNORECASE,
)
_DOCS_RE = re.compile(
    r"(?:go\s+doc|python\d*\s+-m\s+pydoc|pydoc(?:\s|$))",
    re.IGNORECASE,
)

_RETRIEVABLE_OPERATORS = {
    "repo.search",
    "repo.tests",
    "type.check",
    "package.metadata",
    "docs.lookup",
}


def import_operator_registry() -> OperatorRegistry:
    return OperatorRegistry(
        [
            OperatorDescriptor(
                name="repo.search",
                description="Inspect or search repository source, files, symbols, and text.",
                kind="tool",
                tags=("repo", "search", "grep", "find", "read", "view", "source"),
                requires=("repo",),
                provides=("search.matches",),
                cost_millis=5,
            ),
            OperatorDescriptor(
                name="repo.tests",
                description="Run repository tests or a targeted test command.",
                kind="tool",
                tags=("repo", "test", "tests", "pytest", "verify"),
                requires=("repo",),
                provides=("test.result",),
                cost_millis=1000,
            ),
            OperatorDescriptor(
                name="type.check",
                description="Run compiler, linter, or type-check diagnostics.",
                kind="tool",
                tags=("type", "check", "compiler", "mypy", "tsc", "lint"),
                requires=("repo",),
                provides=("type.diagnostics",),
                cost_millis=500,
            ),
            OperatorDescriptor(
                name="package.metadata",
                description="Inspect package, dependency, or manifest metadata.",
                kind="tool",
                tags=("package", "metadata", "dependency", "manifest"),
                requires=("repo",),
                provides=("package.metadata",),
                cost_millis=25,
            ),
            OperatorDescriptor(
                name="docs.lookup",
                description="Look up local package, language, or symbol documentation.",
                kind="tool",
                tags=("docs", "documentation", "lookup", "symbol"),
                requires=("repo",),
                provides=("docs.lookup",),
                cost_millis=50,
            ),
        ]
    )


def _as_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def _as_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return []
        return parsed if isinstance(parsed, list) else []
    return []


_FUNCTION_CALL_RE = re.compile(
    r"<function=([^>\s]+)>\s*(.*?)</function>",
    re.IGNORECASE | re.DOTALL,
)
_PARAMETER_RE = re.compile(
    r"<parameter=([^>]+)>(.*?)</parameter>",
    re.IGNORECASE | re.DOTALL,
)


def _parse_raw_tool_call(
    content: str,
    *,
    call_id: str,
) -> tuple[str, dict[str, Any], str] | None:
    """Parse one SWE-smith XML tool call from an assistant message."""

    match = _FUNCTION_CALL_RE.search(content)
    if match is None:
        return None
    function_name = match.group(1).strip()
    body = match.group(2)
    arguments = {
        name.strip(): value
        for name, value in _PARAMETER_RE.findall(body)
        if name.strip()
    }
    message = (content[: match.start()] + content[match.end() :]).strip()

    normalized_name = function_name.lower()
    if normalized_name == "bash":
        function_name = "terminal"
    elif normalized_name == "submit":
        function_name = "finish"

    return function_name, arguments, message


def _raw_to_atif_record(record: dict[str, Any]) -> dict[str, Any] | None:
    """Normalize original SWE-smith messages into the importer ATIF subset."""

    messages = _as_list(record.get("messages"))
    if not messages:
        return None

    steps: list[dict[str, Any]] = []
    index = 0
    step_id = 0
    while index < len(messages):
        raw_message = messages[index]
        index += 1
        if not isinstance(raw_message, dict):
            continue

        role = str(raw_message.get("role") or "").strip().lower()
        content = str(raw_message.get("content") or "")
        if role not in {"system", "user", "assistant"}:
            continue

        step_id += 1
        if role == "system":
            steps.append(
                {"step_id": step_id, "source": "system", "message": content}
            )
            continue
        if role == "user":
            steps.append(
                {"step_id": step_id, "source": "user", "message": content}
            )
            continue

        call_id = f"raw_call_{step_id}"
        parsed = _parse_raw_tool_call(content, call_id=call_id)
        if parsed is None:
            steps.append(
                {"step_id": step_id, "source": "agent", "message": content}
            )
            continue

        function_name, arguments, message = parsed
        step: dict[str, Any] = {
            "step_id": step_id,
            "source": "agent",
            "message": message,
            "tool_calls": [
                {
                    "tool_call_id": call_id,
                    "function_name": function_name,
                    "arguments": arguments,
                }
            ],
        }

        # SWE-smith raw trajectories put the environment/tool observation in
        # the immediately following user turn. Consume it into this tool step
        # instead of treating it as a second task/user instruction.
        if index < len(messages):
            candidate = messages[index]
            if (
                isinstance(candidate, dict)
                and str(candidate.get("role") or "").strip().lower() == "user"
            ):
                observation = str(candidate.get("content") or "")
                step["observation"] = {
                    "results": [
                        {
                            "source_call_id": call_id,
                            "content": observation,
                        }
                    ]
                }
                index += 1

        steps.append(step)

    resolved = record.get("resolved")
    raw = {
        "instance_id": record.get("instance_id"),
        "resolved": resolved,
        "model": record.get("model"),
        "traj_id": record.get("traj_id"),
        "patch": record.get("patch", ""),
    }
    trajectory_id = str(record.get("traj_id") or record.get("id") or "").strip()
    if not trajectory_id:
        return None
    return {
        "id": trajectory_id,
        "steps": steps,
        "extra": {
            "raw": raw,
            "source_dataset": "swe-smith",
            "source_format": "raw",
        },
    }


def _normalize_source_record(record: dict[str, Any]) -> dict[str, Any] | None:
    if "steps" in record:
        return record
    if "messages" in record:
        return _raw_to_atif_record(record)
    return None


def _repo_name(instance_id: str) -> str:
    prefix = instance_id.split(".", 1)[0]
    if "__" in prefix:
        owner, name = prefix.split("__", 1)
        return f"{owner}/{name}"
    return prefix or "unknown/unknown"


def _base_revision(instance_id: str) -> str:
    parts = instance_id.split(".")
    if len(parts) >= 2 and parts[1].strip():
        return parts[1].strip()
    return "unknown"


def _task_text(steps: list[dict[str, Any]]) -> str:
    for step in steps:
        if str(step.get("source") or "").lower() != "user":
            continue
        message = str(step.get("message") or "").strip()
        if message:
            return message[-8000:]
    return "Repair the repository task described by the trajectory."


def _resolved(extra: dict[str, Any]) -> bool:
    raw = _as_dict(extra.get("raw"))
    value = raw.get("resolved")
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() == "true"
    return False


def _tool_observations(step: dict[str, Any]) -> dict[str, str]:
    observation = _as_dict(step.get("observation"))
    out: dict[str, str] = {}
    for result in _as_list(observation.get("results")):
        if not isinstance(result, dict):
            continue
        call_id = str(result.get("source_call_id") or "")
        if not call_id:
            continue
        content = result.get("content")
        if isinstance(content, list):
            text = "\n".join(str(item) for item in content)
        else:
            text = str(content or "")
        out[call_id] = text[-8000:]
    return out


def classify_tool_call(
    function_name: str,
    arguments: dict[str, Any],
) -> tuple[str | None, str, ArgumentKind]:
    name = function_name.strip().lower()
    command = str(arguments.get("command") or "").strip()
    editor_command = str(arguments.get("command") or "").strip().lower()

    if name in {"str_replace_editor", "editor", "read_file", "write_file"}:
        if editor_command in {"view", "read"} or name == "read_file":
            path = str(arguments.get("path") or arguments.get("file_path") or "")
            return "repo.search", f"inspect repository file {path}".strip(), ArgumentKind.ARTIFACT
        return "repo.edit", "edit repository source", ArgumentKind.ARTIFACT

    if name in {"terminal", "bash", "shell", "execute_bash", "execute"}:
        if _TEST_RE.search(command):
            return "repo.tests", "run repository tests", ArgumentKind.ACTION
        if _TYPE_RE.search(command):
            return "type.check", "inspect compiler or type diagnostics", ArgumentKind.ACTION
        if _METADATA_RE.search(command):
            return "package.metadata", "inspect package metadata", ArgumentKind.ACTION
        if _DOCS_RE.search(command):
            return "docs.lookup", "look up local documentation", ArgumentKind.SYMBOL
        if _SEARCH_RE.search(command):
            return "repo.search", "search or inspect repository source", ArgumentKind.SYMBOL
        return "repo.command", "execute repository terminal command", ArgumentKind.ACTION

    return "repo.command", f"execute repository tool {function_name}", ArgumentKind.ACTION


def _tool_argument(function_name: str, arguments: dict[str, Any]) -> str:
    return json.dumps(
        {"tool": function_name, "arguments": arguments},
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )[-4000:]


def convert_atif_record(record: dict[str, Any]) -> dict[str, Any] | None:
    normalized = _normalize_source_record(record)
    if normalized is None:
        return None
    record = normalized
    extra = _as_dict(record.get("extra"))
    if not _resolved(extra):
        return None

    raw = _as_dict(extra.get("raw"))
    trajectory_id = str(raw.get("traj_id") or record.get("id") or "").strip()
    instance_id = str(raw.get("instance_id") or trajectory_id).strip()
    if not trajectory_id or not instance_id:
        return None

    steps = [item for item in _as_list(record.get("steps")) if isinstance(item, dict)]
    if not steps:
        return None

    repository_name = _repo_name(instance_id)
    repository_identity = canonical_id(
        {
            "source": "swe-smith",
            "repository": repository_name,
        }
    )
    task = _task_text(steps)
    registry = import_operator_registry()
    builder = EpisodeBuilder(registry)
    parent: str | None = None
    tool_events = 0
    accepted = False

    observed = builder.add(
        Operation.OBSERVE,
        ArgumentKind.TEXT,
        task[-4000:],
        grounding=task,
        retrieval_query="inspect software repair task",
    )
    parent = observed

    for step in steps:
        source = str(step.get("source") or "").lower()
        message = str(step.get("message") or "").strip()
        calls = [item for item in _as_list(step.get("tool_calls")) if isinstance(item, dict)]
        observations = _tool_observations(step)

        if source == "user" and message and message != task:
            parent = builder.add(
                Operation.OBSERVE,
                ArgumentKind.TEXT,
                message[-4000:],
                grounding=message,
                retrieval_query="observe additional task information",
                parents=(parent,) if parent else (),
            )
            continue

        if source != "agent":
            continue

        if message:
            editing = any(
                classify_tool_call(
                    str(call.get("function_name") or ""),
                    _as_dict(call.get("arguments")),
                )[0]
                == "repo.edit"
                for call in calls
            )
            operation = Operation.PROPOSE if editing else Operation.CLAIM
            parent = builder.add(
                operation,
                ArgumentKind.TEXT,
                message[-4000:],
                grounding=message,
                retrieval_query=(
                    "propose repository repair"
                    if editing
                    else "reason from current software evidence"
                ),
                parents=(parent,) if parent else (),
                language_target=message[-4000:],
            )

        for call in calls:
            function_name = str(call.get("function_name") or "tool")
            arguments = _as_dict(call.get("arguments"))
            call_id = str(call.get("tool_call_id") or "")
            if function_name.strip().lower() == "finish":
                parent = builder.add(
                    Operation.ACCEPT,
                    ArgumentKind.ACTION,
                    "task completed",
                    grounding=message or "source trajectory finished successfully",
                    retrieval_query="accept completed verified software task",
                    parents=(parent,) if parent else (),
                    confidence_permille=1000,
                )
                accepted = True
                continue

            semantic_action, query, argument_kind = classify_tool_call(
                function_name, arguments
            )
            exact_argument = _tool_argument(function_name, arguments)
            environment = {
                "external_execution": True,
                "source_dataset": "swe-smith",
                "tool_name": function_name,
                "tool_call_id": call_id,
                "tool_arguments": arguments,
                "semantic_action": semantic_action,
                "output": observations.get(call_id, "")[-8000:],
            }
            if "command" in arguments:
                environment["command"] = str(arguments.get("command") or "")[-4000:]

            if semantic_action in _RETRIEVABLE_OPERATORS:
                query_id = builder.add(
                    Operation.QUERY,
                    ArgumentKind.CAPABILITY,
                    query,
                    grounding=message or query,
                    retrieval_query=f"{semantic_action} {query}",
                    operator_ref=semantic_action,
                    parents=(parent,) if parent else (),
                )
                execute_parent = query_id
                execute_operator_ref = semantic_action
                execute_query = f"{semantic_action} {query}"
            else:
                execute_parent = parent
                execute_operator_ref = None
                execute_query = query

            execute_id = builder.add(
                Operation.EXECUTE,
                argument_kind,
                exact_argument,
                grounding=exact_argument,
                retrieval_query=execute_query,
                operator_ref=execute_operator_ref,
                parents=(execute_parent,) if execute_parent else (),
                environment=environment,
            )
            tool_events += 1

            output = observations.get(call_id, "")
            if output:
                parent = builder.add(
                    Operation.EVIDENCE,
                    ArgumentKind.TEXT,
                    output[-4000:],
                    grounding=output,
                    retrieval_query=f"record evidence from {semantic_action}",
                    parents=(execute_id,),
                    confidence_permille=1000,
                )
            else:
                parent = execute_id

    if tool_events == 0:
        return None
    if not accepted:
        parent = builder.add(
            Operation.ACCEPT,
            ArgumentKind.ACTION,
            "resolved trajectory",
            grounding="source dataset marks this trajectory resolved",
            retrieval_query="accept resolved software trajectory",
            parents=(parent,) if parent else (),
            confidence_permille=1000,
        )

    builder.dag.verify()
    episode = Episode(
        version=1,
        producer="swe-smith-atif-import-v1",
        repository={
            "name": repository_name,
            "commit": _base_revision(instance_id),
            "license": "unknown",
            "identity": repository_identity,
            "language": "Python",
        },
        task=task,
        mutation={
            "path": "",
            "line": 0,
            "kind": "imported_swe_smith",
            "original_line": "",
            "mutated_line": "",
            "fingerprint": canonical_id(
                {"source": "swe-smith", "trajectory_id": trajectory_id}
            ),
        },
        events=builder.events,
    )
    result = episode.record()
    result["generation"] = {
        "candidate_source": "external_execution_trace",
        "source_dataset": "swe-smith",
        "source_dataset_license": "MIT",
        "source_revision": DEFAULT_REVISION,
        "trajectory_id": trajectory_id,
        "instance_id": instance_id,
        "resolved": True,
        "model": raw.get("model"),
    }
    return result


def _iter_local(path: str | Path) -> Iterable[dict[str, Any]]:
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid JSONL") from exc
            if isinstance(row, dict):
                yield row


def _iter_huggingface(
    *,
    dataset: str,
    config: str,
    split: str,
    revision: str,
) -> Iterable[dict[str, Any]]:
    """Stream the pinned SWE-smith JSONL file directly from Hugging Face.

    The first serious shard uses the raw split because it preserves the source
    success metadata (`resolved`) and original message/tool exchange without
    depending on a particular generation of the ADP standardized schema.
    """

    if split not in {"raw", "std"}:
        raise ValueError("SWE-smith importer split must be 'raw' or 'std'")

    encoded_dataset = urllib.parse.quote(dataset, safe="/")
    encoded_revision = urllib.parse.quote(revision, safe="")
    encoded_path = urllib.parse.quote(f"{config}/full_{split}.jsonl", safe="/")
    source_url = (
        f"https://huggingface.co/datasets/{encoded_dataset}/resolve/"
        f"{encoded_revision}/{encoded_path}?download=true"
    )
    request = urllib.request.Request(
        source_url,
        headers={
            "User-Agent": "starlings-murmurations/0.1",
            "Accept-Encoding": "identity",
        },
    )

    try:
        response = urllib.request.urlopen(request, timeout=60)
    except (OSError, urllib.error.URLError) as exc:
        raise RuntimeError(
            f"failed to open SWE-smith trajectory stream: {source_url}: {exc}"
        ) from exc

    with response:
        for line_no, raw_line in enumerate(response, 1):
            if not raw_line.strip():
                continue
            try:
                row = json.loads(raw_line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValueError(
                    f"SWE-smith stream line {line_no}: invalid JSONL"
                ) from exc
            if isinstance(row, dict):
                yield row


def import_swe_smith(
    output_path: str | Path,
    *,
    input_jsonl: str | Path | None = None,
    dataset: str = DEFAULT_DATASET,
    config: str = DEFAULT_CONFIG,
    split: str = DEFAULT_SPLIT,
    revision: str = DEFAULT_REVISION,
    target_rows: int = 12000,
    min_episodes: int = 500,
    min_repositories: int = 20,
    max_episodes: int = 1200,
    exclude_repositories: set[str] | None = None,
) -> dict[str, Any]:
    if target_rows <= 0:
        raise ValueError("target_rows must be positive")
    if min_episodes <= 0:
        raise ValueError("min_episodes must be positive")
    if min_repositories <= 0:
        raise ValueError("min_repositories must be positive")
    if max_episodes < min_episodes:
        raise ValueError("max_episodes must be >= min_episodes")

    source = (
        _iter_local(input_jsonl)
        if input_jsonl is not None
        else _iter_huggingface(
            dataset=dataset,
            config=config,
            split=split,
            revision=revision,
        )
    )
    excluded = set(exclude_repositories or ())
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)

    scanned = 0
    written = 0
    trajectory_rows = 0
    skipped = 0
    repositories: set[str] = set()
    operators: Counter[str] = Counter()
    external_execution_events = 0

    with output.open("w", encoding="utf-8") as handle:
        for raw_record in source:
            scanned += 1
            if scanned == 1 or scanned % 250 == 0:
                print(
                    f"[swe-smith] scanned={scanned} accepted={written} "
                    f"events={trajectory_rows} repos={len(repositories)}",
                    flush=True,
                )
            episode = convert_atif_record(raw_record)
            if episode is None:
                skipped += 1
                continue
            if str(episode["repository"]["name"]) in excluded:
                skipped += 1
                continue
            handle.write(json.dumps(episode, sort_keys=True) + "\n")
            written += 1
            repositories.add(str(episode["repository"]["name"]))
            trajectory_rows += len(episode["events"])
            for event in episode["events"]:
                frame = event.get("frame") or {}
                operator = frame.get("operator_ref")
                if operator:
                    operators[str(operator)] += 1
                environment = event.get("environment") or {}
                if environment.get("external_execution"):
                    external_execution_events += 1

            if written >= max_episodes:
                break
            if (
                trajectory_rows >= target_rows
                and written >= min_episodes
                and len(repositories) >= min_repositories
            ):
                break

    if written == 0:
        raise RuntimeError("SWE-smith import produced zero resolved trajectories")
    return {
        "mode": "import",
        "source_dataset": dataset,
        "source_config": config,
        "source_split": split,
        "source_revision": revision,
        "resolved_only": True,
        "target_rows": target_rows,
        "min_episodes": min_episodes,
        "min_repositories": min_repositories,
        "source_scanned": scanned,
        "source_skipped": skipped,
        "requested": written,
        "written": written,
        "failed": 0,
        "success_rate": 1.0,
        "unique_mutations": written,
        "trajectory_rows": trajectory_rows,
        "dynamic_repositories": len(repositories),
        "dynamic_languages": ["Python"],
        "repositories": len(repositories),
        "operators": dict(sorted(operators.items())),
        "external_execution_events": external_execution_events,
        "output": str(output),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--input-jsonl", default=None)
    parser.add_argument("--dataset", default=DEFAULT_DATASET)
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--split", default=DEFAULT_SPLIT)
    parser.add_argument("--revision", default=DEFAULT_REVISION)
    parser.add_argument("--target-rows", type=int, default=12000)
    parser.add_argument("--min-episodes", type=int, default=500)
    parser.add_argument("--min-repositories", type=int, default=20)
    parser.add_argument("--max-episodes", type=int, default=1200)
    args = parser.parse_args()
    report = import_swe_smith(
        args.output,
        input_jsonl=args.input_jsonl,
        dataset=args.dataset,
        config=args.config,
        split=args.split,
        revision=args.revision,
        target_rows=args.target_rows,
        min_episodes=args.min_episodes,
        min_repositories=args.min_repositories,
        max_episodes=args.max_episodes,
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
