"""Stream ordinary code/document continuation windows from repositories."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

from murmurations.training.environments.repositories import RepoCatalog, checkout_repository
from murmurations.training.materialize import split_for_repo


_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".go", ".h", ".hpp", ".java", ".js", ".jsx",
    ".md", ".py", ".rs", ".toml", ".ts", ".tsx", ".txt", ".yaml", ".yml", ".zig",
}
_SKIP = {".git", ".venv", "node_modules", "target", "zig-cache", ".zig-cache"}


def _files(root: Path) -> Iterable[Path]:
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in _EXTENSIONS:
            continue
        if any(part in _SKIP for part in path.relative_to(root).parts):
            continue
        yield path


def _windows(text: str, chunk_chars: int) -> Iterable[tuple[str, str]]:
    for offset in range(0, len(text), chunk_chars):
        chunk = text[offset : offset + chunk_chars]
        if len(chunk) < 192:
            continue
        pivot = max(96, int(len(chunk) * 0.67))
        if pivot >= len(chunk):
            continue
        yield chunk[:pivot], chunk[pivot:]


def materialize_repository_code(
    catalog_path: str | Path,
    train_output: str | Path,
    eval_output: str | Path,
    *,
    cache_dir: str | Path = ".cache/murmurations/repos",
    eval_fraction: float = 0.1,
    chunk_chars: int = 6000,
    max_files_per_repo: int = 2000,
) -> dict[str, object]:
    catalog = RepoCatalog.from_jsonl(catalog_path)
    counts = {"train": 0, "eval": 0}
    repo_counts: dict[str, int] = {}
    failures: list[dict[str, str]] = []

    train_path = Path(train_output)
    eval_path = Path(eval_output)
    train_path.parent.mkdir(parents=True, exist_ok=True)
    eval_path.parent.mkdir(parents=True, exist_ok=True)

    with (
        train_path.open("w", encoding="utf-8") as train_handle,
        eval_path.open("w", encoding="utf-8") as eval_handle,
    ):
        for record in catalog.records:
            try:
                root = checkout_repository(record, cache_dir)
            except Exception as exc:
                failures.append({"repository": record.name, "error": str(exc)})
                continue

            split = split_for_repo(record.identity, eval_fraction)
            handle = eval_handle if split == "eval" else train_handle
            produced = 0
            for index, path in enumerate(_files(root)):
                if index >= max_files_per_repo:
                    break
                try:
                    text = path.read_text(encoding="utf-8")
                except (OSError, UnicodeDecodeError):
                    continue
                rel = path.relative_to(root)
                for prefix, continuation in _windows(text, chunk_chars):
                    row = {
                        "context": (
                            f"REPOSITORY: {record.name} commit={record.commit} "
                            f"license={record.license}
FILE: {rel}
{prefix}"
                        ),
                        "language_target": continuation,
                        "operation": "NOOP",
                        "argument": {
                            "kind": "NONE",
                            "text": None,
                            "operator": None,
                            "parents": [],
                            "confidence_permille": 1000,
                        },
                        "provenance": {
                            "source_type": "repository_code",
                            "repository_identity": record.identity,
                            "repository": record.name,
                            "language": record.language,
                            "license": record.license,
                            "commit": record.commit,
                            "path": str(rel),
                        },
                    }
                    handle.write(json.dumps(row, sort_keys=True) + "
")
                    counts[split] += 1
                    produced += 1
            repo_counts[record.name] = produced

    return {
        "train_rows": counts["train"],
        "eval_rows": counts["eval"],
        "repositories": dict(sorted(repo_counts.items())),
        "failures": failures,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--train-output", required=True)
    parser.add_argument("--eval-output", required=True)
    parser.add_argument("--cache-dir", default=".cache/murmurations/repos")
    parser.add_argument("--eval-fraction", type=float, default=0.1)
    parser.add_argument("--chunk-chars", type=int, default=6000)
    parser.add_argument("--max-files-per-repo", type=int, default=2000)
    args = parser.parse_args()
    result = materialize_repository_code(
        args.catalog,
        args.train_output,
        args.eval_output,
        cache_dir=args.cache_dir,
        eval_fraction=args.eval_fraction,
        chunk_chars=args.chunk_chars,
        max_files_per_repo=args.max_files_per_repo,
    )
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
