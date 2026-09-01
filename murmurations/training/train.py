"""Accelerate-based training entry point."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import torch
from accelerate import Accelerator
from accelerate.utils import set_seed
from torch.optim import AdamW
from torch.optim.lr_scheduler import LambdaLR
from torch.utils.data import DataLoader
from transformers import PreTrainedTokenizerFast
import yaml

from murmurations.training.data import (
    ProtocolCollator,
    ProtocolDataset,
    TokenBudgetBatchSampler,
)
from murmurations.training.losses import compute_losses
from murmurations.training.model import MurmurationConfig, MurmurationModel


def load_tokenizer(path: str) -> PreTrainedTokenizerFast:
    root = Path(path)
    metadata = json.loads((root / "tokenizer_config.json").read_text(encoding="utf-8"))
    return PreTrainedTokenizerFast(
        tokenizer_file=str(root / "tokenizer.json"),
        pad_token=metadata["pad_token"],
        bos_token=metadata["bos_token"],
        eos_token=metadata["eos_token"],
        unk_token=metadata["unk_token"],
        additional_special_tokens=metadata.get("control_tokens", []),
    )


def scheduler_lambda(step: int, *, warmup: int, total: int) -> float:
    if step < warmup:
        return float(step + 1) / max(1, warmup)
    progress = (step - warmup) / max(1, total - warmup)
    return 0.5 * (1.0 + math.cos(math.pi * min(1.0, progress)))


def _assert_finite_losses(losses: dict[str, torch.Tensor], *, where: str) -> None:
    bad = [
        name
        for name, value in losses.items()
        if not bool(torch.isfinite(value.detach()).all().item())
    ]
    if bad:
        raise FloatingPointError(
            f"non-finite Murmurations loss at {where}: {', '.join(sorted(bad))}"
        )


_FLOAT8_BACKBONE_SUFFIXES = (
    ".attn.qkv",
    ".attn.out",
    ".ffn.gate",
    ".ffn.up",
    ".ffn.down",
)


def _is_float8_backbone_linear(module: torch.nn.Module, fqn: str) -> bool:
    if not isinstance(module, torch.nn.Linear):
        return False
    if not fqn.startswith("blocks.") or not fqn.endswith(_FLOAT8_BACKBONE_SUFFIXES):
        return False
    return module.in_features % 16 == 0 and module.out_features % 16 == 0


def _configure_float8_backbone(model, train_cfg: dict[str, object]) -> dict[str, object]:
    if not bool(train_cfg.get("float8_backbone", False)):
        return {"enabled": False, "converted_linears": 0}

    try:
        from torchao.float8 import Float8LinearConfig, convert_to_float8_training
    except ImportError as exc:
        raise RuntimeError(
            "float8_backbone requires torchao; install a torchao build compatible "
            "with the active PyTorch/CUDA environment"
        ) from exc

    recipe_name = str(train_cfg.get("float8_recipe", "tensorwise"))
    config = Float8LinearConfig.from_recipe_name(recipe_name)
    converted: list[str] = []

    def module_filter_fn(module: torch.nn.Module, fqn: str) -> bool:
        selected = _is_float8_backbone_linear(module, fqn)
        if selected:
            converted.append(fqn)
        return selected

    convert_to_float8_training(
        model,
        config=config,
        module_filter_fn=module_filter_fn,
    )
    expected = len(model.blocks) * len(_FLOAT8_BACKBONE_SUFFIXES)
    if len(converted) != expected:
        raise RuntimeError(
            f"expected {expected} FP8 backbone linears but converted {len(converted)}"
        )
    return {
        "enabled": True,
        "recipe": recipe_name,
        "converted_linears": len(converted),
    }


def evaluate(accelerator: Accelerator, model, loader, loss_weights) -> float:
    model.eval()
    total = torch.tensor(0.0, device=accelerator.device)
    count = torch.tensor(0.0, device=accelerator.device)
    with torch.no_grad():
        for batch_index, batch in enumerate(loader):
            outputs = model(batch["input_ids"], batch["control_positions"])
            losses = compute_losses(outputs, batch, loss_weights)
            _assert_finite_losses(losses, where=f"eval batch {batch_index}")
            loss = losses["total"]
            total += loss.detach()
            count += 1
    total, count = accelerator.reduce(total, reduction="sum"), accelerator.reduce(count, reduction="sum")
    model.train()
    return (total / count.clamp_min(1)).item()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--resume", default=None)
    args = parser.parse_args()

    cfg = yaml.safe_load(Path(args.config).read_text(encoding="utf-8"))
    train_cfg = cfg["training"]
    accelerator = Accelerator(
        mixed_precision=train_cfg.get("mixed_precision", "bf16"),
        gradient_accumulation_steps=int(train_cfg.get("gradient_accumulation_steps", 1)),
    )
    set_seed(int(train_cfg.get("seed", 17)))

    tokenizer = load_tokenizer(cfg["tokenizer"]["path"])
    model_cfg = MurmurationConfig(**cfg["model"])
    if len(tokenizer) != model_cfg.vocab_size:
        raise ValueError(
            f"tokenizer has {len(tokenizer)} tokens but model expects {model_cfg.vocab_size}; "
            "train the tokenizer at the configured vocabulary size"
        )
    model = MurmurationModel(model_cfg)
    if bool(train_cfg.get("float8_backbone", False)):
        # torchao's Float8Linear training path expects the source Linear
        # modules and their activations to be CUDA BF16 before conversion.
        # Accelerate mixed precision alone only autocasts forward ops; it does
        # not convert the model parameters themselves.
        model = model.to(device=accelerator.device, dtype=torch.bfloat16)
    float8_report = _configure_float8_backbone(model, train_cfg)
    if accelerator.is_main_process:
        print(json.dumps({"float8": float8_report}, sort_keys=True), flush=True)

    if bool(train_cfg.get("torch_compile", False)):
        compile_mode = str(train_cfg.get("torch_compile_mode", "default"))
        functorch_config = getattr(torch, "_functorch", None)
        if functorch_config is not None:
            compile_config = getattr(functorch_config, "config", None)
            if (
                compile_config is not None
                and hasattr(compile_config, "backward_pass_autocast")
            ):
                compile_config.backward_pass_autocast = "off"
        model = torch.compile(
            model,
            mode=compile_mode,
            dynamic=bool(train_cfg.get("torch_compile_dynamic", True)),
        )
        if accelerator.is_main_process:
            print(
                json.dumps(
                    {
                        "torch_compile": True,
                        "mode": compile_mode,
                        "dynamic": bool(train_cfg.get("torch_compile_dynamic", True)),
                    },
                    sort_keys=True,
                ),
                flush=True,
            )

    max_tokens_per_batch = int(train_cfg.get("max_tokens_per_batch", 0) or 0)
    pretokenize = bool(train_cfg.get("pretokenize", False)) or max_tokens_per_batch > 0
    train_set = ProtocolDataset(
        train_cfg["train_data"],
        tokenizer,
        model_cfg.max_seq_len,
        pretokenize=pretokenize,
        cache_path=train_cfg.get("train_token_cache"),
    )
    eval_set = ProtocolDataset(
        train_cfg["eval_data"],
        tokenizer,
        model_cfg.max_seq_len,
        pretokenize=pretokenize,
        cache_path=train_cfg.get("eval_token_cache"),
    )
    collator = ProtocolCollator(tokenizer.pad_token_id)
    num_workers = int(train_cfg.get("num_workers", 0))

    train_batch_sampler = None
    if max_tokens_per_batch > 0:
        if train_set.lengths is None:
            raise ValueError(
                "token-budget batching requires pretokenized sequence lengths"
            )
        train_batch_sampler = TokenBudgetBatchSampler(
            train_set.lengths,
            max_tokens=max_tokens_per_batch,
            max_examples=int(train_cfg.get("max_examples_per_batch", 16)),
            bucket_size=int(train_cfg.get("length_bucket_size", 2048)),
            shuffle=True,
            seed=int(train_cfg.get("seed", 17)),
        )
        if accelerator.is_main_process:
            print(
                json.dumps(
                    {
                        "data_pipeline": "pretokenized_token_budget",
                        **train_batch_sampler.stats(),
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
        train_loader = DataLoader(
            train_set,
            batch_sampler=train_batch_sampler,
            collate_fn=collator,
            num_workers=num_workers,
        )
    else:
        train_loader = DataLoader(
            train_set,
            batch_size=int(train_cfg["micro_batch_size"]),
            shuffle=True,
            collate_fn=collator,
            num_workers=num_workers,
        )

    eval_loader = DataLoader(
        eval_set,
        batch_size=int(train_cfg.get("eval_batch_size", train_cfg["micro_batch_size"])),
        shuffle=False,
        collate_fn=collator,
        num_workers=num_workers,
    )

    optimizer = AdamW(
        model.parameters(),
        lr=float(train_cfg["learning_rate"]),
        betas=tuple(train_cfg.get("betas", [0.9, 0.95])),
        weight_decay=float(train_cfg.get("weight_decay", 0.1)),
    )
    max_steps = int(train_cfg["max_steps"])
    warmup_steps = int(train_cfg.get("warmup_steps", 0))
    scheduler = LambdaLR(
        optimizer,
        lambda step: scheduler_lambda(step, warmup=warmup_steps, total=max_steps),
    )

    model, optimizer, train_loader, eval_loader, scheduler = accelerator.prepare(
        model, optimizer, train_loader, eval_loader, scheduler
    )
    if args.resume:
        accelerator.load_state(args.resume)

    output_dir = Path(train_cfg["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    loss_weights = cfg.get("loss_weights", {})
    eval_every = int(train_cfg.get("eval_every", 500))
    save_every = int(train_cfg.get("save_every", 1000))
    log_every = int(train_cfg.get("log_every", 20))

    model.train()
    step = 0
    examples_seen = 0
    real_tokens_seen = 0
    padded_tokens_seen = 0
    accumulated_examples = 0
    accumulated_real_tokens = 0
    accumulated_padded_tokens = 0
    while step < max_steps:
        for batch in train_loader:
            batch_examples = int(batch["input_ids"].shape[0])
            batch_real_tokens = int(batch["sequence_lengths"].sum().item())
            batch_padded_tokens = int(batch["input_ids"].numel())
            accumulated_examples += batch_examples
            accumulated_real_tokens += batch_real_tokens
            accumulated_padded_tokens += batch_padded_tokens

            with accelerator.accumulate(model):
                outputs = model(batch["input_ids"], batch["control_positions"])
                losses = compute_losses(outputs, batch, loss_weights)
                _assert_finite_losses(losses, where=f"train step {step + 1}")
                accelerator.backward(losses["total"])
                if accelerator.sync_gradients:
                    accelerator.clip_grad_norm_(model.parameters(), float(train_cfg.get("max_grad_norm", 1.0)))
                optimizer.step()
                scheduler.step()
                optimizer.zero_grad(set_to_none=True)

            if accelerator.sync_gradients:
                step += 1
                examples_seen += accumulated_examples
                real_tokens_seen += accumulated_real_tokens
                padded_tokens_seen += accumulated_padded_tokens
                if accelerator.is_main_process and step % log_every == 0:
                    values = {name: float(value.detach().item()) for name, value in losses.items()}
                    values["lr"] = scheduler.get_last_lr()[0]
                    values["examples_in_step"] = accumulated_examples
                    values["real_tokens_in_step"] = accumulated_real_tokens
                    values["padded_tokens_in_step"] = accumulated_padded_tokens
                    values["padding_efficiency"] = (
                        accumulated_real_tokens / max(1, accumulated_padded_tokens)
                    )
                    values["examples_seen"] = examples_seen
                    values["real_tokens_seen"] = real_tokens_seen
                    print(json.dumps({"step": step, **values}, sort_keys=True))

                accumulated_examples = 0
                accumulated_real_tokens = 0
                accumulated_padded_tokens = 0

                if step % eval_every == 0:
                    score = evaluate(accelerator, model, eval_loader, loss_weights)
                    if accelerator.is_main_process:
                        print(json.dumps({"step": step, "eval_loss": score}))

                if step % save_every == 0:
                    checkpoint = output_dir / f"checkpoint-{step:08d}"
                    accelerator.save_state(str(checkpoint))
                    if accelerator.is_main_process:
                        (checkpoint / "model_config.json").write_text(
                            json.dumps(model_cfg.asdict(), indent=2, sort_keys=True) + "\n",
                            encoding="utf-8",
                        )

                if step >= max_steps:
                    break

    final_dir = output_dir / "final"
    accelerator.save_state(str(final_dir))
    if accelerator.is_main_process:
        (final_dir / "model_config.json").write_text(
            json.dumps(model_cfg.asdict(), indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(json.dumps({"parameters": accelerator.unwrap_model(model).parameter_count()}))


if __name__ == "__main__":
    main()
