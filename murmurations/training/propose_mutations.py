"""Generate verifier-untrusted semantic mutation proposals with an LLM.

This stage never produces training labels. It emits exact source edits that the
Daytona verifier pipeline must independently accept or reject.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import shutil
import time
from typing import Any
import urllib.error
import urllib.request

from murmurations.training.environments.mutations import (
    MutationCandidate,
    enumerate_mutation_candidates,
)
from murmurations.training.environments.repositories import (
    RepoCatalog,
    RepoRecord,
    checkout_repository,
)


_SOURCE_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".go", ".h", ".hpp", ".java", ".js", ".jsx",
    ".py", ".rs", ".ts", ".tsx", ".zig",
}
_SKIP_DIRS = {
    ".git", ".venv", "node_modules", "target", "zig-cache", ".zig-cache",
    "vendor", "dist", "build", ".murmurations-build",
}


def _safe(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value)


def _source_files(
    root: Path,
    *,
    max_files: int,
) -> list[tuple[Path, int | None]]:
    anchors: dict[str, list[int]] = {}
    for candidate in enumerate_mutation_candidates(root):
        anchors.setdefault(candidate.relative_path, []).append(candidate.line_number)

    rows: list[tuple[int, int, str, Path, int | None]] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in _SOURCE_EXTENSIONS:
            continue
        relative = path.relative_to(root)
        if any(part in _SKIP_DIRS for part in relative.parts):
            continue
        lower_parts = {part.lower() for part in relative.parts}
        is_test = bool({"test", "tests"} & lower_parts) or path.stem.lower().startswith("test")
        if is_test:
            continue
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if size <= 0 or size > 256_000:
            continue

        relative_text = str(relative)
        candidate_lines = anchors.get(relative_text, [])
        anchor = (
            sorted(candidate_lines)[len(candidate_lines) // 2]
            if candidate_lines
            else None
        )
        rows.append(
            (
                0,
                -len(candidate_lines),
                relative_text,
                path,
                anchor,
            )
        )
    rows.sort(key=lambda item: (item[0], item[1], item[2]))
    return [(item[3], item[4]) for item in rows[:max_files]]


def _test_index(root: Path, *, limit: int = 80) -> list[str]:
    rows: list[str] = []
    for base in ("tests", "test"):
        test_root = root / base
        if not test_root.is_dir():
            continue
        for path in sorted(test_root.rglob("*")):
            if path.is_file() and path.suffix.lower() in _SOURCE_EXTENSIONS:
                rows.append(str(path.relative_to(root)))
                if len(rows) >= limit:
                    return rows
    return rows


def _numbered_excerpt(
    path: Path,
    *,
    max_lines: int,
    anchor_line: int | None = None,
) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    if not lines:
        return ""
    if anchor_line is None:
        start = 0
    else:
        start = max(0, min(len(lines) - 1, anchor_line - 1) - max_lines // 2)
    end = min(len(lines), start + max_lines)
    return "\n".join(
        f"{index + 1}: {lines[index]}"
        for index in range(start, end)
    )


def _request_json(
    *,
    base_url: str,
    model: str,
    api_key: str | None,
    prompt: str,
    timeout_seconds: int,
    temperature: float,
    request_retries: int,
) -> Any:
    url = base_url.rstrip("/") + "/chat/completions"
    payload = {
        "model": model,
        "temperature": temperature,
        "max_tokens": 1200,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You propose realistic software bugs for execution-verified "
                    "training data. Return JSON only. Never propose shell commands, "
                    "test outputs, repairs, or fabricated evidence."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "response_format": {"type": "json_object"},
    }
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    if request_retries <= 0:
        raise ValueError("request_retries must be positive")
    last_error: Exception | None = None
    body: Any = None
    for attempt in range(request_retries):
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                body = json.loads(response.read().decode("utf-8"))
            break
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            last_error = exc
            if attempt + 1 < request_retries:
                time.sleep(min(4.0, 0.5 * (2 ** attempt)))
    else:
        assert last_error is not None
        raise RuntimeError(f"semantic proposer request failed: {last_error}") from last_error

    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"semantic proposer response is malformed: {body!r}") from exc
    if isinstance(content, list):
        content = "".join(
            str(item.get("text") or "")
            for item in content
            if isinstance(item, dict)
        )
    text = str(content).strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"semantic proposer returned non-JSON content: {text[:1000]}") from exc


def _proposal_prompt(
    *,
    repo: RepoRecord,
    relative_path: str,
    excerpt: str,
    tests: list[str],
    candidates_per_file: int,
) -> str:
    return f"""Repository: {repo.name}
Pinned commit: {repo.commit}
Language: {repo.language or "unknown"}
Source file: {relative_path}

Known test files:
{json.dumps(tests, indent=2)}

Numbered source excerpt:
{excerpt}

Propose up to {candidates_per_file} realistic one-line semantic bugs in this
source excerpt that existing tests are plausibly able to detect.

Hard requirements:
- Change exactly one existing source line.
- Use the exact 1-based line number from the excerpt.
- Do not modify tests, comments, imports solely to break builds, generated files,
  formatting, or dependency manifests.
- Prefer realistic behavioral faults: boundary conditions, wrong branch,
  incorrect state update, wrong field/value, omitted guard semantics, wrong
  boolean composition, error-handling mistakes, or ordering mistakes.
- Keep the replacement syntactically plausible.
- Do not provide a repair, command, expected output, or explanation as evidence.
- Do not claim the bug is detected; execution will decide that.

Return one JSON object with exactly this shape:
{{
  "candidates": [
    {{
      "line": 123,
      "mutated_line": "replacement source line without a line-number prefix",
      "kind": "short_semantic_bug_class"
    }}
  ]
}}
"""


def _validated_candidates(
    *,
    root: Path,
    path: Path,
    payload: Any,
) -> list[MutationCandidate]:
    relative = str(path.relative_to(root))
    try:
        source_lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    except (OSError, UnicodeDecodeError):
        return []
    raw_candidates = (
        payload.get("candidates")
        if isinstance(payload, dict)
        else None
    )
    if not isinstance(raw_candidates, list):
        return []

    out: list[MutationCandidate] = []
    for raw in raw_candidates:
        if not isinstance(raw, dict):
            continue
        try:
            line_number = int(raw["line"])
            mutated_text = str(raw["mutated_line"])
        except (KeyError, TypeError, ValueError):
            continue
        index = line_number - 1
        if index < 0 or index >= len(source_lines):
            continue
        original = source_lines[index]
        stripped = original.lstrip()
        if stripped.startswith(("#", "//", "/*", "*", "import ", "from ", "package ")):
            continue
        if "\n" in mutated_text or "\r" in mutated_text or not mutated_text.strip():
            continue
        original_indent = original[: len(original) - len(original.lstrip())]
        mutated_indent = mutated_text[: len(mutated_text) - len(mutated_text.lstrip())]
        if mutated_indent != original_indent:
            continue
        newline = "\n" if original.endswith("\n") else ""
        mutated = mutated_text + newline
        if mutated == original:
            continue
        kind = str(raw.get("kind") or "llm_semantic")
        out.append(
            MutationCandidate(
                relative_path=relative,
                line_number=line_number,
                kind=kind[:80],
                original_line=original,
                mutated_line=mutated,
                source="llm",
            )
        )
    return out


def propose_for_repository(
    repo: RepoRecord,
    *,
    cache_dir: str | Path,
    base_url: str,
    model: str,
    api_key: str | None,
    max_files: int,
    max_lines_per_file: int,
    candidates_per_file: int,
    request_concurrency: int,
    timeout_seconds: int,
    temperature: float,
    request_retries: int,
    prune_checkout: bool,
) -> list[dict[str, Any]]:
    root: Path | None = None
    try:
        root = checkout_repository(repo, cache_dir)
        tests = _test_index(root)
        paths = _source_files(root, max_files=max_files)

        def propose(item: tuple[Path, int | None]) -> list[MutationCandidate]:
            path, anchor_line = item
            excerpt = _numbered_excerpt(
                path,
                max_lines=max_lines_per_file,
                anchor_line=anchor_line,
            )
            if not excerpt:
                return []
            payload = _request_json(
                base_url=base_url,
                model=model,
                api_key=api_key,
                prompt=_proposal_prompt(
                    repo=repo,
                    relative_path=str(path.relative_to(root)),
                    excerpt=excerpt,
                    tests=tests,
                    candidates_per_file=candidates_per_file,
                ),
                timeout_seconds=timeout_seconds,
                temperature=temperature,
                request_retries=request_retries,
            )
            return _validated_candidates(root=root, path=path, payload=payload)

        candidates: list[MutationCandidate] = []
        with ThreadPoolExecutor(max_workers=max(1, request_concurrency)) as executor:
            futures = {executor.submit(propose, item): item[0] for item in paths}
            for future in as_completed(futures):
                path = futures[future]
                try:
                    candidates.extend(future.result())
                except Exception as exc:
                    print(
                        f"[proposer] skip repo={repo.name} "
                        f"path={path.relative_to(root)} error={exc}",
                        flush=True,
                    )

        seen: set[str] = set()
        rows: list[dict[str, Any]] = []
        for candidate in sorted(
            candidates,
            key=lambda item: (
                item.relative_path,
                item.line_number,
                item.kind,
                item.mutated_line,
            ),
        ):
            fingerprint = candidate.fingerprint
            if fingerprint in seen:
                continue
            seen.add(fingerprint)
            rows.append(
                {
                    "repository": repo.name,
                    "commit": repo.commit,
                    "language": repo.language,
                    "path": candidate.relative_path,
                    "line": candidate.line_number,
                    "kind": candidate.kind,
                    "original_line": candidate.original_line,
                    "mutated_line": candidate.mutated_line,
                    "source": candidate.source,
                    "fingerprint": fingerprint,
                }
            )
        return rows
    finally:
        if (
            prune_checkout
            and root is not None
            and repo.path is None
            and root.exists()
        ):
            shutil.rmtree(root, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--cache-dir", default=".cache/murmurations/proposer-repos")
    parser.add_argument(
        "--base-url",
        default=os.environ.get("MURMURATIONS_PROPOSER_BASE_URL", "http://127.0.0.1:8000/v1"),
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("MURMURATIONS_PROPOSER_MODEL"),
        required=os.environ.get("MURMURATIONS_PROPOSER_MODEL") is None,
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("MURMURATIONS_PROPOSER_API_KEY"),
    )
    parser.add_argument("--max-files-per-repo", type=int, default=24)
    parser.add_argument("--max-lines-per-file", type=int, default=220)
    parser.add_argument("--candidates-per-file", type=int, default=4)
    parser.add_argument("--request-concurrency", type=int, default=8)
    parser.add_argument("--repository-concurrency", type=int, default=4)
    parser.add_argument("--request-retries", type=int, default=3)
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--temperature", type=float, default=0.6)
    parser.add_argument("--keep-checkouts", action="store_true")
    args = parser.parse_args()

    catalog = RepoCatalog.from_jsonl(args.catalog)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_name(output.name + ".tmp")
    total = 0
    by_repo: dict[str, int] = {}

    def generate_repo(repo: RepoRecord) -> list[dict[str, Any]]:
        return propose_for_repository(
            repo,
            cache_dir=args.cache_dir,
            base_url=args.base_url,
            model=args.model,
            api_key=args.api_key,
            max_files=args.max_files_per_repo,
            max_lines_per_file=args.max_lines_per_file,
            candidates_per_file=args.candidates_per_file,
            request_concurrency=args.request_concurrency,
            timeout_seconds=args.timeout_seconds,
            temperature=args.temperature,
            request_retries=args.request_retries,
            prune_checkout=not args.keep_checkouts,
        )

    try:
        rows_by_repo: dict[str, list[dict[str, Any]]] = {}
        with ThreadPoolExecutor(
            max_workers=max(1, args.repository_concurrency)
        ) as executor:
            futures = {
                executor.submit(generate_repo, repo): repo
                for repo in catalog.records
            }
            for future in as_completed(futures):
                repo = futures[future]
                rows = future.result()
                rows_by_repo[repo.name] = rows
                print(
                    f"[proposer] repo={repo.name} candidates={len(rows)}",
                    flush=True,
                )

        with tmp.open("w", encoding="utf-8") as handle:
            for repo in catalog.records:
                rows = rows_by_repo.get(repo.name, [])
                by_repo[repo.name] = len(rows)
                for row in rows:
                    handle.write(json.dumps(row, sort_keys=True) + "\n")
                total += len(rows)
        tmp.replace(output)
    finally:
        if tmp.exists():
            tmp.unlink()

    print(
        json.dumps(
            {
                "repositories": len(catalog.records),
                "candidates": total,
                "by_repository": by_repo,
                "output": str(output),
                "model": args.model,
                "base_url": args.base_url,
            },
            indent=2,
            sort_keys=True,
        )
    )
    if total == 0:
        raise SystemExit("semantic proposer produced zero valid candidates")


if __name__ == "__main__":
    main()
