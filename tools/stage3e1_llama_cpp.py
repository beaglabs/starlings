#!/usr/bin/env python3
"""Stage 3E.1 paired llama.cpp live-trial runner.

Stdlib-only transport. Starlings' Zig evaluator remains authoritative for
protocol parsing, task scoring, and experiment summaries.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

PROTOCOL_SPEC = """You communicate using only this protocol vocabulary:
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
CLAIM may repeat one or more times as a claim batch.
A session may contain one or more valid interactions.

Return only the protocol terminal sequence required by the task.
Do not include explanations, punctuation, prose, or code fences.

Task:
"""

WORKFLOWS = (
    (
        "observe_claim",
        "A coordinator gives an observation to an analyst; the analyst must state the resulting claim.",
    ),
    (
        "query_evidence",
        "A coordinator requests a known fact from a worker; the worker must return supporting evidence.",
    ),
    (
        "proposal_accept",
        "A coordinator proposes an allowed action; the evaluator must accept it.",
    ),
    (
        "proposal_reject",
        "A coordinator proposes an action outside the allowed set; the evaluator must reject it.",
    ),
    (
        "challenge_retract",
        "A coordinator challenges an active claim; the claimant must retract the challenged claim.",
    ),
    (
        "delegation",
        "A coordinator delegates an information request to a worker; the worker queries a specialist, receives evidence, and forwards evidence to the coordinator.",
    ),
)

TYPED = "typed_unconstrained"
CONSTRAINED = "cfg_constrained"
BACKEND_ERROR = "__BACKEND_ERROR__"
RUNNER_VERSION = 2


def escape_completion(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )


def record_key(workflow: str, seed: int, mode: str, attempt: int) -> tuple[str, int, str, int]:
    return workflow, seed, mode, attempt

def task_prompt(task: str) -> str:
    return PROTOCOL_SPEC + task


def mode_order(seed: int, workflow_index: int) -> tuple[str, str]:
    # Alternate which mode runs first so latency/cache/order effects are balanced.
    if (seed + workflow_index) & 1:
        return CONSTRAINED, TYPED
    return TYPED, CONSTRAINED


def build_payload(
    *,
    model: str,
    prompt: str,
    seed: int,
    mode: str,
    grammar: str,
    temperature: float,
    top_p: float,
    top_k: int,
    max_tokens: int,
) -> dict:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "seed": seed,
        "temperature": temperature,
        "top_p": top_p,
        "top_k": top_k,
        "max_tokens": max_tokens,
        "stream": False,
        "cache_prompt": False,
    }
    if mode == CONSTRAINED:
        payload["grammar"] = grammar
    return payload


def request_json(url: str, payload: dict | None, api_key: str | None, timeout: float) -> dict:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def discover_model(base_url: str, api_key: str | None, timeout: float) -> str:
    data = request_json(f"{base_url.rstrip('/')}/v1/models", None, api_key, timeout)
    models = data.get("data") or []
    if not models or not isinstance(models[0], dict) or not models[0].get("id"):
        raise RuntimeError("llama.cpp /v1/models returned no model id")
    return str(models[0]["id"])


def run_completion(
    *,
    base_url: str,
    api_key: str | None,
    timeout: float,
    payload: dict,
) -> tuple[str, int, int]:
    started = time.perf_counter_ns()
    data = request_json(
        f"{base_url.rstrip('/')}/v1/chat/completions",
        payload,
        api_key,
        timeout,
    )
    latency_us = (time.perf_counter_ns() - started) // 1_000

    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("response contains no choices")
    message = choices[0].get("message") or {}
    content = message.get("content")
    if not isinstance(content, str):
        raise RuntimeError("response choice has no string message.content")

    usage = data.get("usage") or {}
    completion_tokens = int(usage.get("completion_tokens") or 0)
    return content, completion_tokens, latency_us


def load_completed(path: pathlib.Path) -> set[tuple[str, int, str, int]]:
    completed: set[tuple[str, int, str, int]] = set()
    if not path.exists():
        return completed

    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.rstrip("\n")
            if not raw or raw.startswith("#"):
                continue
            fields = raw.split("\t", 6)
            if len(fields) != 7:
                continue
            workflow, seed, mode, attempt = fields[0], fields[1], fields[2], fields[3]
            try:
                completed.add(record_key(workflow, int(seed), mode, int(attempt)))
            except ValueError:
                continue
    return completed


def write_record(
    handle,
    *,
    workflow: str,
    seed: int,
    mode: str,
    attempt: int,
    completion_tokens: int,
    latency_us: int,
    completion: str,
) -> None:
    row = (
        f"{workflow}\t{seed}\t{mode}\t{attempt}\t"
        f"{completion_tokens}\t{latency_us}\t{escape_completion(completion)}\n"
    )
    handle.write(row)
    handle.flush()


def write_metadata(
    *,
    output_path: pathlib.Path,
    model: str,
    grammar: str,
    args: argparse.Namespace,
) -> None:
    metadata = {
        "stage": "3E.1",
        "runner_version": RUNNER_VERSION,
        "model": model,
        "base_url": args.base_url,
        "first_seed": args.first_seed,
        "seeds": args.seeds,
        "workflows": [name for name, _ in WORKFLOWS],
        "prompt_suite_sha256": hashlib.sha256(
            "\n\0\n".join(task_prompt(task) for _, task in WORKFLOWS).encode("utf-8")
        ).hexdigest(),
        "base_generations": args.seeds * len(WORKFLOWS) * 2,
        "temperature": args.temperature,
        "top_p": args.top_p,
        "top_k": args.top_k,
        "max_tokens": args.max_tokens,
        "cache_prompt": False,
        "grammar_sha256": hashlib.sha256(grammar.encode("utf-8")).hexdigest(),
        "grammar_path": args.grammar,
        "endpoint": "/v1/chat/completions",
    }
    meta_path = pathlib.Path(str(output_path) + ".meta.json")
    if args.resume and meta_path.exists():
        existing = json.loads(meta_path.read_text(encoding="utf-8"))
        if existing != metadata:
            raise RuntimeError(
                f"resume metadata mismatch for {meta_path}; use a new output file or matching parameters"
            )
        return
    meta_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def self_test() -> None:
    grammar = 'root ::= "QUERY EVIDENCE"'
    typed = build_payload(
        model="m",
        prompt="same",
        seed=42,
        mode=TYPED,
        grammar=grammar,
        temperature=0.7,
        top_p=0.9,
        top_k=40,
        max_tokens=16,
    )
    constrained = build_payload(
        model="m",
        prompt="same",
        seed=42,
        mode=CONSTRAINED,
        grammar=grammar,
        temperature=0.7,
        top_p=0.9,
        top_k=40,
        max_tokens=16,
    )

    assert typed["messages"] == constrained["messages"]
    assert typed["seed"] == constrained["seed"]
    assert typed["temperature"] == constrained["temperature"]
    assert typed["top_p"] == constrained["top_p"]
    assert typed["top_k"] == constrained["top_k"]
    assert typed["max_tokens"] == constrained["max_tokens"]
    assert "grammar" not in typed
    assert constrained["grammar"] == grammar
    for terminal in (
        "OBSERVE",
        "QUERY",
        "CLAIM",
        "EVIDENCE",
        "PROPOSE",
        "ACCEPT",
        "REJECT",
        "CHALLENGE",
        "RETRACT",
        "DELEGATE",
    ):
        assert terminal in PROTOCOL_SPEC
    for interaction in (
        "OBSERVE CLAIM",
        "QUERY EVIDENCE",
        "PROPOSE ACCEPT",
        "PROPOSE REJECT",
        "CHALLENGE RETRACT",
        "DELEGATE QUERY EVIDENCE EVIDENCE",
    ):
        assert interaction in PROTOCOL_SPEC
    for _, task in WORKFLOWS:
        assert task_prompt(task).startswith(PROTOCOL_SPEC)
    assert mode_order(0, 0) == (TYPED, CONSTRAINED)
    assert mode_order(1, 0) == (CONSTRAINED, TYPED)
    assert escape_completion("A\tB\nC\\D") == "A\\tB\\nC\\\\D"
    print("stage3e1 runner self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--model", default=None, help="llama.cpp model id; auto-discovered when omitted")
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--grammar", default="grammars/starlings.gbnf")
    parser.add_argument("--output", default="trials/stage3e1.tsv")
    parser.add_argument("--first-seed", type=int, default=0)
    parser.add_argument("--seeds", type=int, default=100)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--top-p", type=float, default=0.9)
    parser.add_argument("--top-k", type=int, default=40)
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.seeds <= 0:
        raise SystemExit("--seeds must be > 0")

    grammar_path = pathlib.Path(args.grammar)
    grammar = grammar_path.read_text(encoding="utf-8")
    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    total = args.seeds * len(WORKFLOWS) * 2
    if args.dry_run:
        print(f"{total} base generations")
        return 0

    model = args.model or discover_model(args.base_url, args.api_key, args.timeout)
    write_metadata(output_path=output_path, model=model, grammar=grammar, args=args)
    completed = load_completed(output_path) if args.resume else set()
    file_mode = "a" if args.resume else "w"

    print(
        f"Stage 3E.1: model={model!r}, seeds={args.seeds}, "
        f"base_generations={total}, output={output_path}",
        file=sys.stderr,
    )

    emitted = 0
    skipped = 0
    with output_path.open(file_mode, encoding="utf-8", newline="") as handle:
        for seed in range(args.first_seed, args.first_seed + args.seeds):
            for workflow_index, (workflow, task) in enumerate(WORKFLOWS):
                prompt = task_prompt(task)
                for mode in mode_order(seed, workflow_index):
                    key = record_key(workflow, seed, mode, 0)
                    if key in completed:
                        skipped += 1
                        continue

                    payload = build_payload(
                        model=model,
                        prompt=prompt,
                        seed=seed,
                        mode=mode,
                        grammar=grammar,
                        temperature=args.temperature,
                        top_p=args.top_p,
                        top_k=args.top_k,
                        max_tokens=args.max_tokens,
                    )

                    try:
                        completion, tokens, latency_us = run_completion(
                            base_url=args.base_url,
                            api_key=args.api_key,
                            timeout=args.timeout,
                            payload=payload,
                        )
                    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, RuntimeError, ValueError) as exc:
                        print(
                            f"backend error workflow={workflow} seed={seed} mode={mode}: {exc}",
                            file=sys.stderr,
                        )
                        completion, tokens, latency_us = BACKEND_ERROR, 0, 0

                    write_record(
                        handle,
                        workflow=workflow,
                        seed=seed,
                        mode=mode,
                        attempt=0,
                        completion_tokens=tokens,
                        latency_us=latency_us,
                        completion=completion,
                    )
                    emitted += 1

                    if emitted % 25 == 0:
                        print(f"recorded {emitted}/{total - skipped}", file=sys.stderr)

    print(f"done: emitted={emitted}, skipped={skipped}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
