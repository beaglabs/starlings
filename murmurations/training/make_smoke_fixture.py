"""Build a fully local end-to-end Murmurations smoke training fixture."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys

from tokenizers import Tokenizer
import yaml

from murmurations.training.environments.episodes import make_oracle_bootstrap_episode
from murmurations.training.environments.mutations import inject_verified_mutation
from murmurations.training.environments.repositories import RepoRecord
from murmurations.training.materialize import materialize_episode
from murmurations.training.operators import default_operator_registry
from murmurations.training.tokenizer import train_tokenizer


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def _make_repo(root: Path) -> None:
    if root.exists():
        shutil.rmtree(root)
    (root / "src").mkdir(parents=True)
    (root / "tests").mkdir()
    (root / "src" / "__init__.py").write_text("", encoding="utf-8")
    (root / "src" / "logic.py").write_text(
        "def same(a, b):\n"
        "    return a == b\n\n"
        "def bounded(x, limit):\n"
        "    return x <= limit\n",
        encoding="utf-8",
    )
    (root / "tests" / "test_logic.py").write_text(
        "import unittest\n"
        "from src.logic import bounded, same\n\n"
        "class LogicTests(unittest.TestCase):\n"
        "    def test_same(self):\n"
        "        self.assertTrue(same(3, 3))\n"
        "        self.assertFalse(same(3, 4))\n\n"
        "    def test_bounded(self):\n"
        "        self.assertTrue(bounded(4, 4))\n"
        "        self.assertFalse(bounded(5, 4))\n",
        encoding="utf-8",
    )


def _preflight_lengths(
    rows_by_split: dict[str, list[dict]],
    tokenizer_path: str | Path,
    max_seq_len: int,
) -> dict[str, int]:
    tokenizer = Tokenizer.from_file(str(Path(tokenizer_path) / "tokenizer.json"))
    act = tokenizer.encode("<ACT>", add_special_tokens=False).ids
    if len(act) != 1:
        raise ValueError("<ACT> must remain a single tokenizer token")

    maxima: dict[str, int] = {}
    for split, rows in rows_by_split.items():
        maximum = 0
        for index, row in enumerate(rows):
            length = (
                len(tokenizer.encode(str(row["context"]), add_special_tokens=False).ids)
                + 1
                + len(
                    tokenizer.encode(
                        str(row.get("language_target", "")),
                        add_special_tokens=False,
                    ).ids
                )
                + 1
            )
            maximum = max(maximum, length)
            if length > max_seq_len:
                raise ValueError(
                    f"smoke {split} row {index} encodes to {length} tokens, "
                    f"exceeding max_seq_len={max_seq_len}"
                )
        maxima[split] = maximum
    return maxima


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".cache/murmurations/smoke")
    parser.add_argument(
        "--tokenizer-output",
        default="murmurations/models/murmuration-500m-v0/tokenizer",
    )
    parser.add_argument("--vocab-size", type=int, default=512)
    args = parser.parse_args()

    root = Path(args.root).resolve()
    source = root / "clean"
    _make_repo(source)
    verifier = [sys.executable, "-m", "unittest", "discover", "-s", "tests"]

    all_episodes: list[dict] = []
    split_rows: dict[str, list[dict]] = {}
    for offset, split in enumerate(("train", "eval")):
        workspace = root / f"work-{split}"
        mutation = inject_verified_mutation(
            source,
            workspace,
            verifier,
            seed=17 + offset,
            timeout_seconds=20,
        )
        repo = RepoRecord(
            name=f"smoke-{split}",
            commit=f"fixture-{split}",
            license="MIT",
            path=str(source),
            language="python",
        )
        episode = make_oracle_bootstrap_episode(
            repo,
            workspace,
            mutation,
            default_operator_registry(workspace),
            timeout_seconds=20,
        )
        record = episode.record()
        all_episodes.append(record)
        split_rows[split] = materialize_episode(record)

    data_root = Path("data/murmurations")
    episodes_path = data_root / "smoke-episodes.jsonl"
    train_path = data_root / "smoke-train.jsonl"
    eval_path = data_root / "smoke-eval.jsonl"
    _write_jsonl(episodes_path, all_episodes)
    _write_jsonl(train_path, split_rows["train"])
    _write_jsonl(eval_path, split_rows["eval"])

    corpus_path = root / "tokenizer-corpus.txt"
    with corpus_path.open("w", encoding="utf-8") as handle:
        # Repeated structured identifiers give the tiny smoke corpus enough
        # byte-pair statistics to reach the requested test vocabulary.
        for repeat in range(3):
            for index in range(1200):
                handle.write(
                    f"operator_{index:04d} symbol_{index:04d} package_{index:04d} "
                    f"repair compiler evidence challenge execute query value_{repeat}_{index}\n"
                )

    tokenizer_size = train_tokenizer(
        [str(train_path), str(eval_path), str(corpus_path)],
        args.tokenizer_output,
        args.vocab_size,
    )

    smoke_cfg = yaml.safe_load(
        Path("murmurations/training/configs/smoke.yaml").read_text(encoding="utf-8")
    )
    max_seq_len = int(smoke_cfg["model"]["max_seq_len"])
    max_lengths = _preflight_lengths(
        split_rows,
        args.tokenizer_output,
        max_seq_len,
    )

    print(
        json.dumps(
            {
                "episodes": str(episodes_path),
                "train": str(train_path),
                "eval": str(eval_path),
                "tokenizer": str(Path(args.tokenizer_output)),
                "tokenizer_size": tokenizer_size,
                "max_seq_len": max_seq_len,
                "max_encoded_lengths": max_lengths,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
