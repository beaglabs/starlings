"""Multi-head Murmurations training objective."""

from __future__ import annotations

from typing import Mapping

import torch
from torch import Tensor
import torch.nn.functional as F


def _differentiable_zero(logits: Tensor) -> Tensor:
    """Return a gradient-connected zero without reducing masked sentinel values.

    Pointer heads mask invalid positions with torch.finfo(dtype).min. Summing a
    large masked tensor can overflow to -inf, and -inf * 0 becomes NaN. A single
    finite tensor element is sufficient to keep a zero connected to autograd.
    """

    if logits.numel() == 0:
        return torch.zeros((), dtype=logits.dtype, device=logits.device)
    return logits.reshape(-1)[0] * 0.0


def _safe_cross_entropy(logits: Tensor, labels: Tensor) -> Tensor:
    flat_labels = labels.reshape(-1)
    valid = flat_labels != -100
    if not torch.any(valid):
        return _differentiable_zero(logits)
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
    losses["operator_pointer"] = _safe_cross_entropy(
        outputs["operator_pointer_logits"], batch["operator_pointer_labels"]
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
        losses["confidence"] = _differentiable_zero(outputs["confidence"])

    total = _differentiable_zero(outputs["language_logits"])
    for name, loss in losses.items():
        total = total + float(weights.get(name, 1.0)) * loss
    losses["total"] = total
    return losses
