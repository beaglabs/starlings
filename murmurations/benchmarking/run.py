"""Murmurations benchmark CLI."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

from murmurations.benchmarking.model_io import load_model
from murmurations.benchmarking.protocol_eval import evaluate_protocol_heads
from murmurations.benchmarking.replay_eval import evaluate_replay
from murmurations.training.train import load_tokenizer


def choose_device(name: str) -> torch.device:
    if name != "auto":
        return torch.device(name)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    heads = sub.add_parser("heads")
    heads.add_argument("--checkpoint", required=True)
    heads.add_argument("--tokenizer", required=True)
    heads.add_argument("--data", required=True)
    heads.add_argument("--batch-size", type=int, default=1)
    heads.add_argument("--device", default="auto")

    replay = sub.add_parser("replay")
    replay.add_argument("--trace", required=True)

    args = parser.parse_args()
    if args.command == "heads":
        device = choose_device(args.device)
        model = load_model(args.checkpoint, device)
        tokenizer = load_tokenizer(args.tokenizer)
        result = evaluate_protocol_heads(
            model,
            tokenizer,
            args.data,
            device=device,
            batch_size=args.batch_size,
        )
    else:
        result = evaluate_replay(args.trace)

    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
