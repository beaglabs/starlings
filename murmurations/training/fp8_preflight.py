"""Fast CUDA/torchao FP8 compile preflight for Murmurations."""

from __future__ import annotations

import argparse
import json
import time

import torch
from torch import nn


class _Probe(nn.Module):
    def __init__(self, width: int, hidden: int) -> None:
        super().__init__()
        self.qkv = nn.Linear(width, 3 * width, bias=False)
        self.out = nn.Linear(width, width, bias=False)
        self.gate = nn.Linear(width, hidden, bias=False)
        self.up = nn.Linear(width, hidden, bias=False)
        self.down = nn.Linear(hidden, width, bias=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        qkv = self.qkv(x)
        attn_like = self.out(qkv[..., : x.shape[-1]])
        ffn = self.down(torch.nn.functional.silu(self.gate(x)) * self.up(x))
        return attn_like + ffn


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--width", type=int, default=1792)
    parser.add_argument("--hidden", type=int, default=7168)
    parser.add_argument("--batch", type=int, default=4)
    parser.add_argument("--seq", type=int, default=128)
    parser.add_argument("--dynamic", action="store_true")
    args = parser.parse_args()

    if not torch.cuda.is_available():
        raise RuntimeError("FP8 preflight requires CUDA")

    from torchao.float8 import Float8LinearConfig, convert_to_float8_training
    from torchao.float8.float8_linear import Float8Linear

    device = torch.device("cuda")
    model = _Probe(args.width, args.hidden).to(device=device, dtype=torch.bfloat16)
    config = Float8LinearConfig.from_recipe_name("tensorwise")
    convert_to_float8_training(model, config=config)

    converted = sum(isinstance(module, Float8Linear) for module in model.modules())
    if converted != 5:
        raise RuntimeError(f"expected 5 Float8Linear modules, got {converted}")

    model = torch.compile(model, dynamic=args.dynamic)

    shapes = [
        (args.batch, args.seq, args.width),
        (args.batch, args.seq + 1, args.width),
    ]
    if not args.dynamic:
        shapes = shapes[:1]

    torch.cuda.reset_peak_memory_stats()
    started = time.perf_counter()
    for shape in shapes:
        x = torch.randn(*shape, device=device, dtype=torch.bfloat16, requires_grad=True)
        y = model(x)
        loss = y.float().square().mean()
        loss.backward()
        if not bool(torch.isfinite(loss).item()):
            raise FloatingPointError("FP8 preflight produced non-finite loss")

    torch.cuda.synchronize()
    elapsed = time.perf_counter() - started
    print(
        json.dumps(
            {
                "fp8_preflight": "pass",
                "dynamic": args.dynamic,
                "converted_linears": converted,
                "shapes": shapes,
                "elapsed_seconds": elapsed,
                "peak_gpu_memory_gib": torch.cuda.max_memory_allocated() / (1024**3),
                "torch": torch.__version__,
                "cuda": torch.version.cuda,
                "gpu": torch.cuda.get_device_name(0),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
