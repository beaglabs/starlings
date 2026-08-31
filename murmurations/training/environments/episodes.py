"""Merkle-DAG episode format and oracle bootstrap trace generation."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import random
import re
from typing import Any

from murmurations.training.environments.mutations import Mutation, repair_mutation
from murmurations.training.environments.repositories import RepoRecord
from murmurations.training.operator_retrieval import OperatorRegistry
from murmurations.training.operators import execute_operator
from murmurations.utils.dag import MerkleDag
from murmurations.utils.protocol import ActionFrame, ArgumentKind, Operation


@dataclass
class EpisodeEvent:
    id: str
    frame: dict[str, Any]
    grounding: str
    retrieval_query: str
    candidates: list[str]
    language_target: str = ""
    environment: dict[str, Any] = field(default_factory=dict)


@dataclass
class Episode:
    version: int
    producer: str
    repository: dict[str, Any]
    task: str
    mutation: dict[str, Any]
    events: list[EpisodeEvent]

    def record(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "producer": self.producer,
            "repository": self.repository,
            "task": self.task,
            "mutation": self.mutation,
            "events": [
                {
                    "id": event.id,
                    "frame": event.frame,
                    "grounding": event.grounding,
                    "retrieval_query": event.retrieval_query,
                    "candidates": event.candidates,
                    "language_target": event.language_target,
                    "environment": event.environment,
                }
                for event in self.events
            ],
        }


class EpisodeBuilder:
    def __init__(self, registry: OperatorRegistry) -> None:
        self.registry = registry
        self.dag = MerkleDag()
        self.events: list[EpisodeEvent] = []

    def add(
        self,
        operation: Operation,
        kind: ArgumentKind,
        argument: str | None,
        *,
        grounding: str,
        retrieval_query: str,
        operator_ref: str | None = None,
        parents: tuple[str, ...] = (),
        confidence_permille: int = 1000,
        language_target: str = "",
        environment: dict[str, Any] | None = None,
    ) -> str:
        hits = self.registry.retrieve(retrieval_query, top_k=7, available=("repo",))
        candidates = [hit.descriptor.name for hit in hits]
        if operator_ref is not None and operator_ref not in candidates:
            # Do not manufacture successful retrieval supervision. If the
            # bootstrap oracle expects an operator that OR did not actually
            # expose, the episode is invalid for operator-pointer training.
            self.registry.get(operator_ref)  # fail clearly if descriptor is unknown
            raise ValueError(
                f"operator retrieval miss for {operator_ref!r} "
                f"with query {retrieval_query!r}; candidates={candidates}"
            )
        frame = ActionFrame(
            operation,
            kind,
            argument,
            operator_ref=operator_ref,
            parents=parents,
            confidence_permille=confidence_permille,
        )
        node = self.dag.add(frame)
        self.events.append(
            EpisodeEvent(
                id=node.id,
                frame=frame.record(),
                grounding=grounding[-4000:],
                retrieval_query=retrieval_query,
                candidates=candidates,
                language_target=language_target,
                environment=environment or {},
            )
        )
        return node.id


_LOW_INFORMATION_TOKENS = {
    "return", "const", "var", "let", "pub", "fn", "def", "class", "struct",
    "impl", "func", "package", "import", "from", "true", "false", "none",
    "null", "this", "self", "else", "elif", "while", "for", "match",
}


def _search_term(mutation: Mutation) -> str:
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}", mutation.original_line)
    for token in tokens:
        if token.lower() not in _LOW_INFORMATION_TOKENS:
            return token
    return Path(mutation.relative_path).stem


def _enrichment_request(name: str, term: str) -> tuple[str, ArgumentKind, str]:
    if name == "type.check":
        return (
            "inspect compiler type diagnostics for the repository",
            ArgumentKind.ACTION,
            "run local compiler type check",
        )
    if name == "package.metadata":
        return (
            "inspect local package dependency metadata",
            ArgumentKind.ACTION,
            "inspect local package metadata",
        )
    if name == "docs.lookup":
        return (
            f"lookup local documentation for {term}",
            ArgumentKind.SYMBOL,
            term,
        )
    raise ValueError(f"unsupported enrichment operator: {name}")


def _selected_enrichment_operators(
    registry: OperatorRegistry,
    configured: tuple[str, ...],
    *,
    max_calls: int,
    seed: int,
) -> list[str]:
    if max_calls <= 0 or not configured:
        return []
    available = {descriptor.name for descriptor in registry.descriptors()}
    selected = [name for name in configured if name in available]
    random.Random(seed).shuffle(selected)
    return selected[:max_calls]


def make_oracle_bootstrap_episode(
    repo: RepoRecord,
    workspace_root: str | Path,
    mutation: Mutation,
    registry: OperatorRegistry,
    *,
    timeout_seconds: int = 120,
    episode_seed: int = 17,
    enrichment_operators: tuple[str, ...] = (),
    max_enrichment_calls: int = 0,
    command_runner=None,
) -> Episode:
    """Create an explicitly labeled bootstrap demonstration from known mutation truth."""

    root = Path(workspace_root)
    task = (
        f"Repair the verifier-caught regression in {mutation.relative_path} and "
        "restore the repository verifier."
    )
    builder = EpisodeBuilder(registry)

    observed = builder.add(
        Operation.OBSERVE,
        ArgumentKind.TEXT,
        task,
        grounding=task,
        retrieval_query="inspect repair task repository",
    )

    ask_verify = "verify repository tests"
    query_tests = builder.add(
        Operation.QUERY,
        ArgumentKind.CAPABILITY,
        ask_verify,
        grounding=ask_verify,
        retrieval_query=ask_verify,
        operator_ref="repo.tests",
        parents=(observed,),
    )

    run_tests = builder.add(
        Operation.EXECUTE,
        ArgumentKind.ACTION,
        "run repository tests",
        grounding="run repository tests",
        retrieval_query=ask_verify,
        operator_ref="repo.tests",
        parents=(query_tests,),
        environment={
            "exit_code": mutation.broken_verification.exit_code,
            "output": mutation.broken_verification.output[-8000:],
            "argv": list(mutation.broken_verification.argv),
            "sandbox_backend": mutation.broken_verification.backend,
            "sandbox_argv": list(mutation.broken_verification.sandbox_argv),
        },
    )

    failure_text = (mutation.broken_verification.output or "repository verifier failed")[-4000:]
    evidence = builder.add(
        Operation.EVIDENCE,
        ArgumentKind.TEXT,
        failure_text,
        grounding=failure_text,
        retrieval_query="inspect test failure source",
        parents=(run_tests,),
        confidence_permille=1000,
    )

    term = _search_term(mutation)
    evidence_parent = evidence
    for operator_name in _selected_enrichment_operators(
        registry,
        enrichment_operators,
        max_calls=max_enrichment_calls,
        seed=episode_seed,
    ):
        retrieval_query, argument_kind, execution_argument = _enrichment_request(
            operator_name, term
        )
        query_event = builder.add(
            Operation.QUERY,
            ArgumentKind.CAPABILITY,
            retrieval_query,
            grounding=retrieval_query,
            retrieval_query=retrieval_query,
            operator_ref=operator_name,
            parents=(evidence_parent,),
        )
        result = execute_operator(
            operator_name,
            execution_argument,
            root,
            timeout_seconds=timeout_seconds,
            command_runner=command_runner,
        )
        execute_event = builder.add(
            Operation.EXECUTE,
            argument_kind,
            execution_argument,
            grounding=execution_argument,
            retrieval_query=retrieval_query,
            operator_ref=operator_name,
            parents=(query_event,),
            environment={
                "ok": result.ok,
                "exit_code": result.exit_code,
                "output": result.text[-8000:],
                "argv": result.metadata.get("argv"),
                "sandbox_backend": result.metadata.get("sandbox_backend"),
                "sandbox_argv": result.metadata.get("sandbox_argv"),
            },
        )
        result_text = (
            result.text
            or f"{operator_name} completed with ok={result.ok} exit_code={result.exit_code}"
        )[-4000:]
        evidence_parent = builder.add(
            Operation.EVIDENCE,
            ArgumentKind.TEXT,
            result_text,
            grounding=result_text,
            retrieval_query=f"record evidence from {operator_name}",
            parents=(execute_event,),
            confidence_permille=1000,
        )

    inspect_query = f"search source for {term}"
    query_source = builder.add(
        Operation.QUERY,
        ArgumentKind.CAPABILITY,
        inspect_query,
        grounding=inspect_query,
        retrieval_query=inspect_query,
        operator_ref="repo.search",
        parents=(evidence_parent,),
    )
    search_result = execute_operator("repo.search", term, root, timeout_seconds=timeout_seconds)
    execute_search = builder.add(
        Operation.EXECUTE,
        ArgumentKind.SYMBOL,
        term,
        grounding=f"{term} {mutation.relative_path}",
        retrieval_query=inspect_query,
        operator_ref="repo.search",
        parents=(query_source,),
        environment={"ok": search_result.ok, "output": search_result.text[-8000:]},
    )

    search_text = (search_result.text or (
        f"{mutation.relative_path}:{mutation.line_number}:{mutation.mutated_line.strip()}"
    ))[-4000:]
    source_evidence = builder.add(
        Operation.EVIDENCE,
        ArgumentKind.SYMBOL,
        mutation.relative_path,
        grounding=f"{mutation.relative_path}\n{search_text}",
        retrieval_query="inspect source around failing line",
        parents=(execute_search,),
    )

    proposal = builder.add(
        Operation.PROPOSE,
        ArgumentKind.SYMBOL,
        mutation.relative_path,
        grounding=(
            f"{mutation.relative_path}:{mutation.line_number}\n"
            f"current={mutation.mutated_line.strip()}\n"
            f"known clean predecessor={mutation.original_line.strip()}"
        ),
        retrieval_query="repair source regression",
        parents=(source_evidence,),
        language_target=mutation.repair_text,
    )

    repair_mutation(root, mutation)
    repaired = execute_operator(
        "repo.tests",
        "",
        root,
        timeout_seconds=timeout_seconds,
        command_runner=command_runner,
    )
    verify_repair = builder.add(
        Operation.EXECUTE,
        ArgumentKind.ACTION,
        "run repository tests",
        grounding="run repository tests after repair candidate",
        retrieval_query=ask_verify,
        operator_ref="repo.tests",
        parents=(proposal,),
        environment={
            "ok": repaired.ok,
            "exit_code": repaired.exit_code,
            "output": repaired.text[-8000:],
            "argv": repaired.metadata.get("argv"),
            "sandbox_backend": repaired.metadata.get("sandbox_backend"),
            "sandbox_argv": repaired.metadata.get("sandbox_argv"),
        },
    )

    result_text = (repaired.text or (
        "repository verifier passed" if repaired.ok else "repository verifier failed"
    ))[-4000:]
    final_evidence = builder.add(
        Operation.EVIDENCE,
        ArgumentKind.TEXT,
        result_text,
        grounding=result_text,
        retrieval_query="verify repair result",
        parents=(verify_repair,),
        confidence_permille=1000 if repaired.ok else 0,
    )

    builder.add(
        Operation.ACCEPT if repaired.ok else Operation.REJECT,
        ArgumentKind.ACTION,
        "repair candidate",
        grounding="repair candidate",
        retrieval_query="decide repair from verifier evidence",
        parents=(final_evidence, proposal),
        confidence_permille=1000,
    )

    builder.dag.verify()
    return Episode(
        version=1,
        producer="oracle-bootstrap-v1",
        repository={
            "name": repo.name,
            "commit": repo.commit,
            "license": repo.license,
            "identity": repo.identity,
            "language": repo.language,
        },
        task=task,
        mutation={
            "path": mutation.relative_path,
            "line": mutation.line_number,
            "kind": mutation.kind,
            "original_line": mutation.original_line,
            "mutated_line": mutation.mutated_line,
        },
        events=builder.events,
    )
