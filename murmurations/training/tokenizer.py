"""Train a byte-level BPE tokenizer for language, code, and protocol traces."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

from tokenizers import Tokenizer, decoders, models, pre_tokenizers, trainers

from murmurations.utils.protocol import CONTROL_TOKENS

BASE_SPECIAL_TOKENS = ("<PAD>", "<BOS>", "<EOS>", "<UNK>")


def iter_corpus(paths: list[str]) -> Iterable[str]:
    for raw_path in paths:
        path = Path(raw_path)
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if not line:
                    continue
                if path.suffix == ".jsonl":
                    row = json.loads(line)
                    for key in ("context", "language_target", "text", "code"):
                        value = row.get(key)
                        if isinstance(value, str) and value:
                            yield value
                else:
                    yield line


def train_tokenizer(paths: list[str], output_path: str | Path, vocab_size: int) -> int:
    output = Path(output_path)
    output.mkdir(parents=True, exist_ok=True)

    tokenizer = Tokenizer(models.BPE(unk_token="<UNK>"))
    tokenizer.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tokenizer.decoder = decoders.ByteLevel()
    trainer = trainers.BpeTrainer(
        vocab_size=vocab_size,
        min_frequency=2,
        special_tokens=list(BASE_SPECIAL_TOKENS) + list(CONTROL_TOKENS),
        initial_alphabet=pre_tokenizers.ByteLevel.alphabet(),
        show_progress=True,
    )
    tokenizer.train_from_iterator(iter_corpus(paths), trainer=trainer)
    actual = tokenizer.get_vocab_size()
    if actual != vocab_size:
        raise ValueError(
            f"tokenizer produced {actual} tokens, expected exactly {vocab_size}; "
            "provide a larger/more varied corpus or lower vocab_size"
        )
    tokenizer.save(str(output / "tokenizer.json"))

    metadata = {
        "vocab_size": actual,
        "pad_token": "<PAD>",
        "bos_token": "<BOS>",
        "eos_token": "<EOS>",
        "unk_token": "<UNK>",
        "control_tokens": list(CONTROL_TOKENS),
    }
    (output / "tokenizer_config.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return actual


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", nargs="+", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--vocab-size", type=int, default=32768)
    args = parser.parse_args()
    train_tokenizer(args.input, args.output, args.vocab_size)


if __name__ == "__main__":
    main()
