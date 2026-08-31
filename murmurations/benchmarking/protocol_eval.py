"""Teacher-forced evaluation for all three Murmurations heads."""

from __future__ import annotations

import math
from collections import defaultdict
from typing import Any

import torch
from torch.utils.data import DataLoader

from murmurations.training.data import ProtocolCollator, ProtocolDataset


def _accuracy(logits: torch.Tensor, labels: torch.Tensor, ignore: int | None = None) -> tuple[int, int]:
    prediction = logits.argmax(dim=-1)
    if ignore is None:
        mask = torch.ones_like(labels, dtype=torch.bool)
    else:
        mask = labels != ignore
    correct = ((prediction == labels) & mask).sum().item()
    return int(correct), int(mask.sum().item())


def evaluate_protocol_heads(
    model,
    tokenizer: Any,
    data_path: str,
    *,
    device: torch.device,
    batch_size: int = 1,
) -> dict[str, float]:
    dataset = ProtocolDataset(data_path, tokenizer, model.config.max_seq_len)
    loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=False,
        collate_fn=ProtocolCollator(tokenizer.pad_token_id),
    )
    totals = defaultdict(float)
    counts = defaultdict(int)
    span_exact = 0
    span_count = 0
    language_nll = 0.0
    language_tokens = 0
    confidence_abs_error = 0.0
    confidence_count = 0

    with torch.no_grad():
        for batch in loader:
            batch = {key: value.to(device) for key, value in batch.items()}
            outputs = model(batch["input_ids"], batch["control_positions"])

            op_c, op_n = _accuracy(outputs["operation_logits"], batch["operation_labels"])
            kind_c, kind_n = _accuracy(
                outputs["argument_kind_logits"], batch["argument_kind_labels"]
            )
            start_c, start_n = _accuracy(
                outputs["argument_start_logits"], batch["argument_start_labels"], -100
            )
            end_c, end_n = _accuracy(
                outputs["argument_end_logits"], batch["argument_end_labels"], -100
            )
            operator_c, operator_n = _accuracy(
                outputs["operator_pointer_logits"], batch["operator_pointer_labels"], -100
            )
            parent_c, parent_n = _accuracy(
                outputs["parent_pointer_logits"], batch["parent_pointer_labels"], -100
            )
            count_c, count_n = _accuracy(
                outputs["parent_count_logits"], batch["parent_count_labels"]
            )

            for name, correct, count in (
                ("operation", op_c, op_n),
                ("argument_kind", kind_c, kind_n),
                ("argument_start", start_c, start_n),
                ("argument_end", end_c, end_n),
                ("operator_pointer", operator_c, operator_n),
                ("parent_pointer", parent_c, parent_n),
                ("parent_count", count_c, count_n),
            ):
                totals[name] += correct
                counts[name] += count

            span_mask = (
                (batch["argument_start_labels"] != -100)
                & (batch["argument_end_labels"] != -100)
            )
            if torch.any(span_mask):
                predicted_start = outputs["argument_start_logits"].argmax(dim=-1)
                predicted_end = outputs["argument_end_logits"].argmax(dim=-1)
                exact = (
                    (predicted_start == batch["argument_start_labels"])
                    & (predicted_end == batch["argument_end_labels"])
                    & span_mask
                )
                span_exact += int(exact.sum().item())
                span_count += int(span_mask.sum().item())

            labels = batch["language_labels"]
            valid = labels != -100
            if torch.any(valid):
                logits = outputs["language_logits"].reshape(-1, outputs["language_logits"].shape[-1])
                flat_labels = labels.reshape(-1)
                token_loss = torch.nn.functional.cross_entropy(
                    logits[valid.reshape(-1)], flat_labels[valid.reshape(-1)], reduction="sum"
                )
                language_nll += float(token_loss.item())
                language_tokens += int(valid.sum().item())

            mask = batch["confidence_mask"].bool()
            if torch.any(mask):
                confidence_abs_error += float(
                    (outputs["confidence"][mask] - batch["confidence_targets"][mask]).abs().sum().item()
                )
                confidence_count += int(mask.sum().item())

    result = {
        f"{name}_accuracy": totals[name] / max(1, counts[name])
        for name in totals
    }
    result["argument_span_exact"] = span_exact / max(1, span_count)
    result["confidence_mae"] = confidence_abs_error / max(1, confidence_count)
    if language_tokens:
        mean_nll = language_nll / language_tokens
        result["language_nll"] = mean_nll
        result["language_perplexity"] = math.exp(min(20.0, mean_nll))
    else:
        result["language_nll"] = 0.0
        result["language_perplexity"] = 1.0
    result["examples"] = float(len(dataset))
    return result
