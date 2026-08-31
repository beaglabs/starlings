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

from murmurations.training.data import ProtocolCollator, ProtocolDataset
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


def evaluate(accelerator: Accelerator, model, loader, loss_weights) -> float:
    model.eval()
    total = torch.tensor(0.0, device=accelerator.device)
    count = torch.tensor(0.0, device=accelerator.device)
    with torch.no_grad():
        for batch in loader:
            outputs = model(batch["input_ids"], batch["control_positions"])
            loss = compute_losses(outputs, batch, loss_weights)["total"]
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

    train_set = ProtocolDataset(train_cfg["train_data"], tokenizer, model_cfg.max_seq_len)
    eval_set = ProtocolDataset(train_cfg["eval_data"], tokenizer, model_cfg.max_seq_len)
    collator = ProtocolCollator(tokenizer.pad_token_id)
    train_loader = DataLoader(
        train_set,
        batch_size=int(train_cfg["micro_batch_size"]),
        shuffle=True,
        collate_fn=collator,
        num_workers=int(train_cfg.get("num_workers", 0)),
    )
    eval_loader = DataLoader(
        eval_set,
        batch_size=int(train_cfg.get("eval_batch_size", train_cfg["micro_batch_size"])),
        shuffle=False,
        collate_fn=collator,
        num_workers=int(train_cfg.get("num_workers", 0)),
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
    while step < max_steps:
        for batch in train_loader:
            with accelerator.accumulate(model):
                outputs = model(batch["input_ids"], batch["control_positions"])
                losses = compute_losses(outputs, batch, loss_weights)
                accelerator.backward(losses["total"])
                if accelerator.sync_gradients:
                    accelerator.clip_grad_norm_(model.parameters(), float(train_cfg.get("max_grad_norm", 1.0)))
                optimizer.step()
                scheduler.step()
                optimizer.zero_grad(set_to_none=True)

            if accelerator.sync_gradients:
                step += 1
                if accelerator.is_main_process and step % log_every == 0:
                    values = {name: float(value.detach().item()) for name, value in losses.items()}
                    values["lr"] = scheduler.get_last_lr()[0]
                    print(json.dumps({"step": step, **values}, sort_keys=True))

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
