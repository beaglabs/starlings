"""Multi-head Murmurations training objective."""

from __future__ import annotations

from typing import Mapping

import torch
from torch import Tensor
import torch.nn.functional as F


def _safe_cross_entropy(logits: Tensor, labels: Tensor) -> Tensor:
    flat_labels = labels.reshape(-1)
    valid = flat_labels != -100
    if not torch.any(valid):
        return logits.sum() * 0.0
    flat_logits = logits.reshape(-1, logits.shape[-1])
    return F.cross_entropy(flat_logits[valid], flat_labels[valid])


def compute_losses(
    outputs: Mapping[str, Tensor],
    batch: Mapping[str, Tensor],
    weights: Mapping[str, float],
) -> dict[str, Tensor]:
    losses: dict[str, Tensor] = {}
    losses["language"] = _safe_cross_entropy(outputs["language_logits"], batch["language_labels"])
    losses["operation"] = F.cross_entropy(outputs["operation_logits"], batch["operation_labels"])
    losses["argument_kind"] = F.cross_entropy(
        outputs["argument_kind_logits"], batch["argument_kind_labels"]
    )
    losses["argument_start"] = _safe_cross_entropy(
        outputs["argument_start_logits"], batch["argument_start_labels"]
    )
    losses["argument_end"] = _safe_cross_entropy(
        outputs["argument_end_logits"], batch["argument_end_labels"]
    )
    losses["parent_pointer"] = _safe_cross_entropy(
        outputs["parent_pointer_logits"], batch["parent_pointer_labels"]
    )
    losses["parent_count"] = F.cross_entropy(
        outputs["parent_count_logits"], batch["parent_count_labels"]
    )

    confidence_mask = batch["confidence_mask"].bool()
    if torch.any(confidence_mask):
        losses["confidence"] = F.smooth_l1_loss(
            outputs["confidence"][confidence_mask],
            batch["confidence_targets"][confidence_mask],
        )
    else:
        losses["confidence"] = outputs["confidence"].sum() * 0.0

    total = outputs["language_logits"].sum() * 0.0
    for name, loss in losses.items():
        total = total + float(weights.get(name, 1.0)) * loss
    losses["total"] = total
    return losses
