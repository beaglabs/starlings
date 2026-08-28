#!/usr/bin/env python3
"""Stage 3F.1 communication-efficiency runner for llama.cpp.

Five model-backed workers coordinate over a deterministic ring. Each worker has
a fixed communication-unit budget, making selective information propagation
materially cheaper than broad redundant claims. Zig independently replays the
record and is authoritative for task and efficiency metrics.
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

WORKER_COUNT = 5
FACT_COUNT = 10
FULL_MASK = (1 << FACT_COUNT) - 1
TYPED = "typed_unconstrained"
CONSTRAINED = "cfg_constrained"
BACKEND_ERROR = "__BACKEND_ERROR__"
RUNNER_VERSION = 1
DEFAULT_WORKER_BUDGET = 16

PROTOCOL_SPEC = """You are one operator in a five-worker distributed coordination experiment.

Facts are A through J.

The only valid interactions are:
CLAIM <facts>
QUERY EVIDENCE <fact>

CLAIM announces one or more facts you currently know to both ring neighbors.
Write multiple facts comma-separated with no spaces, for example:
CLAIM E,F

Communication cost:
- CLAIM of N distinct facts costs 2*N units because the facts are sent to both neighbors.
- QUERY EVIDENCE costs 2 query units plus 1 evidence unit for each neighbor that knows the requested fact, so it costs 2 to 4 units.
- An interaction that exceeds your remaining communication budget is rejected and has no effect.
- You may only CLAIM facts listed in your current knowledge. Unknown-fact claims are rejected.

Choose your interaction autonomously. Prefer useful new information over
redundant retransmission. The collective objective is to make Worker 1 learn
all ten facts before communication budgets are exhausted.

Output exactly one interaction and nothing else.
"""


def fact_bit(index: int) -> int:
    return 1 << index


def initial_knowledge(environment_seed: int) -> list[int]:
    offset = environment_seed % FACT_COUNT
    result = []
    for worker in range(WORKER_COUNT):
        start = (worker * 2 + offset) % FACT_COUNT
        mask = 0
        for j in range(4):
            mask |= fact_bit((start + j) % FACT_COUNT)
        result.append(mask)
    return result


def generation_seed(sampling_seed: int, round_number: int, worker: int) -> int:
    mixed = (
        (sampling_seed * 1_000_003)
        + (round_number * 101)
        + worker
    ) & ((1 << 64) - 1)
    return mixed & 0x7FFF_FFFF


def ring_neighbors(worker_index: int) -> tuple[int, int]:
    return (
        (worker_index + WORKER_COUNT - 1) % WORKER_COUNT,
        (worker_index + 1) % WORKER_COUNT,
    )


def mask_text(mask: int) -> str:
    labels = [chr(ord("A") + i) for i in range(FACT_COUNT) if mask & fact_bit(i)]
    return ",".join(labels) if labels else "(none)"


def build_prompt(
    *,
    worker: int,
    round_number: int,
    private_facts: int,
    current_knowledge: int,
    remaining_budget: int,
    worker_budget: int,
) -> str:
    left, right = ring_neighbors(worker - 1)
    return (
        PROTOCOL_SPEC
        + "\n"
        + f"Your identity: Worker {worker}\n"
        + f"Your ring neighbors: Worker {left + 1}, Worker {right + 1}\n"
        + f"Round: {round_number}\n"
        + f"Your original private facts: {mask_text(private_facts)}\n"
        + f"Your current knowledge: {mask_text(current_knowledge)}\n"
        + f"Your communication budget: {remaining_budget}/{worker_budget} units remaining\n"
        + "Choose your next interaction."
    )


def parse_fact(text: str) -> int | None:
    if len(text) != 1 or text < "A" or text > "J":
        return None
    return fact_bit(ord(text) - ord("A"))


def parse_action(completion: str) -> tuple[str, int] | None:
    text = completion.strip()
    parts = text.split(" ")

    if len(parts) == 2 and parts[0] == "CLAIM":
        mask = 0
        for fact in parts[1].split(","):
            bit = parse_fact(fact)
            if bit is None:
                return None
            mask |= bit
        if mask == 0:
            return None
        return "claim", mask

    if len(parts) == 3 and parts[0] == "QUERY" and parts[1] == "EVIDENCE":
        bit = parse_fact(parts[2])
        if bit is None:
            return None
        return "query_evidence", bit

    return None


def apply_round(
    knowledge: list[int],
    remaining_budget: list[int],
    completions: list[str],
) -> tuple[list[int], list[int]]:
    snapshot = list(knowledge)
    next_state = list(snapshot)
    next_budget = list(remaining_budget)

    for sender, completion in enumerate(completions):
        parsed = parse_action(completion)
        if parsed is None:
            continue

        kind, facts = parsed
        neighbors = ring_neighbors(sender)

        if kind == "claim":
            if facts & ~snapshot[sender]:
                continue
            cost = facts.bit_count() * 2
            if cost > next_budget[sender]:
                continue
            next_budget[sender] -= cost
            for recipient in neighbors:
                next_state[recipient] |= facts
            continue

        responders = sum(1 for recipient in neighbors if snapshot[recipient] & facts)
        cost = 2 + responders
        if cost > next_budget[sender]:
            continue
        next_budget[sender] -= cost
        for recipient in neighbors:
            if snapshot[recipient] & facts:
                next_state[sender] |= facts

    return next_state, next_budget


def mode_order(environment_seed: int, sampling_seed: int) -> tuple[str, str]:
    if (environment_seed + sampling_seed) & 1:
        return CONSTRAINED, TYPED
    return TYPED, CONSTRAINED


def escape_completion(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )


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
        "reasoning_effort": "none",
        "chat_template_kwargs": {"enable_thinking": False},
    }
    if mode == CONSTRAINED:
        payload["grammar"] = grammar
    return payload


def request_json(url: str, payload: dict | None, api_key: str | None, timeout: float) -> dict:
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
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


def write_record(
    handle,
    *,
    environment_seed: int,
    sampling_seed: int,
    mode: str,
    round_number: int,
    worker: int,
    knowledge_before: int,
    budget_before: int,
    worker_budget: int,
    model_seed: int,
    completion_tokens: int,
    latency_us: int,
    completion: str,
) -> None:
    handle.write(
        f"{environment_seed}\t{sampling_seed}\t{mode}\t{round_number}\t{worker}\t"
        f"{knowledge_before}\t{budget_before}\t{worker_budget}\t{model_seed}\t"
        f"{completion_tokens}\t{latency_us}\t{escape_completion(completion)}\n"
    )
    handle.flush()


def write_metadata(
    *,
    output_path: pathlib.Path,
    model: str,
    grammar: str,
    args: argparse.Namespace,
) -> None:
    population_runs = args.environments * args.sampling_seeds * 2
    metadata = {
        "stage": "3F.1",
        "runner_version": RUNNER_VERSION,
        "record_schema_version": 1,
        "model": model,
        "base_url": args.base_url,
        "first_environment_seed": args.first_environment_seed,
        "environments": args.environments,
        "first_sampling_seed": args.first_sampling_seed,
        "sampling_seeds": args.sampling_seeds,
        "population_runs": population_runs,
        "worker_count": WORKER_COUNT,
        "fact_count": FACT_COUNT,
        "collector_worker": 1,
        "topology": "ring",
        "worker_budget": args.worker_budget,
        "max_rounds": args.max_rounds,
        "max_generations": population_runs * args.max_rounds * WORKER_COUNT,
        "temperature": args.temperature,
        "top_p": args.top_p,
        "top_k": args.top_k,
        "max_tokens": args.max_tokens,
        "cache_prompt": False,
        "reasoning_effort": "none",
        "chat_template_kwargs": {"enable_thinking": False},
        "prompt_spec_sha256": hashlib.sha256(PROTOCOL_SPEC.encode("utf-8")).hexdigest(),
        "grammar_sha256": hashlib.sha256(grammar.encode("utf-8")).hexdigest(),
        "grammar_path": args.grammar,
        "endpoint": "/v1/chat/completions",
        "resume_supported": False,
    }
    pathlib.Path(str(output_path) + ".meta.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def self_test() -> None:
    assert initial_knowledge(0) == [15, 60, 240, 960, 771]
    assert all(mask.bit_count() == 4 for mask in initial_knowledge(3))
    assert generation_seed(0, 1, 1) == 102
    assert parse_action("CLAIM A,E,J") == ("claim", 0b1000010001)
    assert parse_action("QUERY EVIDENCE H") == ("query_evidence", 0b0010000000)
    assert parse_action("CLAIM K") is None

    knowledge = initial_knowledge(0)
    budget = [DEFAULT_WORKER_BUDGET] * WORKER_COUNT
    knowledge, budget = apply_round(
        knowledge,
        budget,
        [
            "CLAIM A,B",
            "CLAIM E,F",
            "CLAIM G,H",
            "CLAIM G,H",
            "CLAIM I,J",
        ],
    )
    assert knowledge[0] != FULL_MASK
    knowledge, budget = apply_round(
        knowledge,
        budget,
        [
            "CLAIM A,B",
            "CLAIM G,H",
            "CLAIM G,H",
            "CLAIM I,J",
            "CLAIM I,J",
        ],
    )
    assert knowledge[0] == FULL_MASK

    grammar = 'root ::= "CLAIM A"'
    prompt = build_prompt(
        worker=1,
        round_number=1,
        private_facts=15,
        current_knowledge=15,
        remaining_budget=16,
        worker_budget=16,
    )
    typed = build_payload(
        model="m",
        prompt=prompt,
        seed=102,
        mode=TYPED,
        grammar=grammar,
        temperature=0.7,
        top_p=0.9,
        top_k=40,
        max_tokens=32,
    )
    constrained = build_payload(
        model="m",
        prompt=prompt,
        seed=102,
        mode=CONSTRAINED,
        grammar=grammar,
        temperature=0.7,
        top_p=0.9,
        top_k=40,
        max_tokens=32,
    )
    constrained_without_grammar = dict(constrained)
    assert constrained_without_grammar.pop("grammar") == grammar
    assert typed == constrained_without_grammar
    print("stage3f1 runner self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--model", default=None)
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--grammar", default="grammars/stage3f1.gbnf")
    parser.add_argument("--output", default="trials/stage3f1.tsv")
    parser.add_argument("--first-environment-seed", type=int, default=0)
    parser.add_argument("--environments", type=int, default=5)
    parser.add_argument("--first-sampling-seed", type=int, default=0)
    parser.add_argument("--sampling-seeds", type=int, default=4)
    parser.add_argument("--worker-budget", type=int, default=DEFAULT_WORKER_BUDGET)
    parser.add_argument("--max-rounds", type=int, default=8)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--top-p", type=float, default=0.9)
    parser.add_argument("--top-k", type=int, default=40)
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.environments <= 0:
        raise SystemExit("--environments must be > 0")
    if args.sampling_seeds <= 0:
        raise SystemExit("--sampling-seeds must be > 0")
    if args.max_rounds <= 0:
        raise SystemExit("--max-rounds must be > 0")
    if args.worker_budget <= 0 or args.worker_budget > 65535:
        raise SystemExit("--worker-budget must be between 1 and 65535")

    grammar = pathlib.Path(args.grammar).read_text(encoding="utf-8")
    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    population_runs = args.environments * args.sampling_seeds * 2
    max_generations = population_runs * args.max_rounds * WORKER_COUNT
    if args.dry_run:
        print(f"{population_runs} population runs")
        print(f"up to {max_generations} model generations")
        print(f"{args.worker_budget} communication units per worker")
        return 0

    model = args.model or discover_model(args.base_url, args.api_key, args.timeout)
    write_metadata(output_path=output_path, model=model, grammar=grammar, args=args)

    print(
        f"Stage 3F.1: model={model!r}, environments={args.environments}, "
        f"sampling_seeds={args.sampling_seeds}, population_runs={population_runs}, "
        f"worker_budget={args.worker_budget}, max_rounds={args.max_rounds}, "
        f"max_generations={max_generations}, output={output_path}",
        file=sys.stderr,
    )

    emitted = 0
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        for environment_seed in range(
            args.first_environment_seed,
            args.first_environment_seed + args.environments,
        ):
            private = initial_knowledge(environment_seed)

            for sampling_seed in range(
                args.first_sampling_seed,
                args.first_sampling_seed + args.sampling_seeds,
            ):
                for mode in mode_order(environment_seed, sampling_seed):
                    knowledge = list(private)
                    remaining_budget = [args.worker_budget] * WORKER_COUNT

                    for round_number in range(1, args.max_rounds + 1):
                        snapshot = list(knowledge)
                        budget_snapshot = list(remaining_budget)
                        completions: list[str] = []

                        for worker_index in range(WORKER_COUNT):
                            worker = worker_index + 1
                            model_seed = generation_seed(
                                sampling_seed,
                                round_number,
                                worker,
                            )
                            prompt = build_prompt(
                                worker=worker,
                                round_number=round_number,
                                private_facts=private[worker_index],
                                current_knowledge=snapshot[worker_index],
                                remaining_budget=budget_snapshot[worker_index],
                                worker_budget=args.worker_budget,
                            )
                            payload = build_payload(
                                model=model,
                                prompt=prompt,
                                seed=model_seed,
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
                            except (
                                urllib.error.URLError,
                                urllib.error.HTTPError,
                                TimeoutError,
                                RuntimeError,
                                ValueError,
                            ) as exc:
                                print(
                                    f"backend error environment={environment_seed} "
                                    f"sampling={sampling_seed} mode={mode} "
                                    f"round={round_number} worker={worker}: {exc}",
                                    file=sys.stderr,
                                )
                                completion, tokens, latency_us = BACKEND_ERROR, 0, 0

                            write_record(
                                handle,
                                environment_seed=environment_seed,
                                sampling_seed=sampling_seed,
                                mode=mode,
                                round_number=round_number,
                                worker=worker,
                                knowledge_before=snapshot[worker_index],
                                budget_before=budget_snapshot[worker_index],
                                worker_budget=args.worker_budget,
                                model_seed=model_seed,
                                completion_tokens=tokens,
                                latency_us=latency_us,
                                completion=completion,
                            )
                            completions.append(completion)
                            emitted += 1

                        knowledge, remaining_budget = apply_round(
                            knowledge,
                            remaining_budget,
                            completions,
                        )
                        if knowledge[0] == FULL_MASK:
                            break

                    spent = sum(args.worker_budget - x for x in remaining_budget)
                    print(
                        f"environment={environment_seed} sampling={sampling_seed} "
                        f"mode={mode} rounds={round_number} "
                        f"collector={mask_text(knowledge[0])} "
                        f"spent={spent}/{args.worker_budget * WORKER_COUNT} "
                        f"success={knowledge[0] == FULL_MASK}",
                        file=sys.stderr,
                    )

    print(f"done: emitted={emitted}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
