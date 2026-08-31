"""Portable single-process checkpoint loading for benchmarks."""

from __future__ import annotations

import json
from pathlib import Path

import torch
from safetensors.torch import load_file

from murmurations.training.model import MurmurationConfig, MurmurationModel


def load_model(checkpoint: str | Path, device: torch.device) -> MurmurationModel:
    root = Path(checkpoint)
    cfg_path = root / "model_config.json"
    if not cfg_path.exists():
        raise FileNotFoundError(f"missing {cfg_path}")
    cfg = MurmurationConfig(**json.loads(cfg_path.read_text(encoding="utf-8")))
    model = MurmurationModel(cfg)

    safe = root / "model.safetensors"
    binary = root / "pytorch_model.bin"
    if safe.exists():
        state = load_file(str(safe), device=str(device))
    elif binary.exists():
        state = torch.load(binary, map_location=device, weights_only=True)
    else:
        raise FileNotFoundError(
            "benchmark loader expects a consolidated model.safetensors or pytorch_model.bin; "
            "merge distributed/FSDP shards before evaluation"
        )
    model.load_state_dict(state)
    model.to(device)
    model.eval()
    return model
