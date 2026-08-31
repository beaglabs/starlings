from __future__ import annotations

import unittest

import torch

from murmurations.training.losses import _safe_cross_entropy


class LossTests(unittest.TestCase):
    def test_all_ignored_pointer_loss_is_finite_zero(self) -> None:
        logits = torch.full(
            (2, 2048),
            torch.finfo(torch.float32).min,
            dtype=torch.float32,
            requires_grad=True,
        )
        # The first position represents a valid unmasked slot while the rest
        # reproduce the pointer-head masking pattern.
        with torch.no_grad():
            logits[0, 0] = 0.25
            logits[1, 0] = -0.5
        labels = torch.full((2,), -100, dtype=torch.long)

        loss = _safe_cross_entropy(logits, labels)
        self.assertTrue(torch.isfinite(loss).item())
        self.assertEqual(float(loss.item()), 0.0)

        loss.backward()
        self.assertIsNotNone(logits.grad)
        self.assertTrue(torch.isfinite(logits.grad).all().item())
        self.assertEqual(float(logits.grad.abs().sum().item()), 0.0)

    def test_masked_pointer_loss_with_target_is_finite(self) -> None:
        logits = torch.full(
            (1, 8),
            torch.finfo(torch.float32).min,
            dtype=torch.float32,
            requires_grad=True,
        )
        with torch.no_grad():
            logits[0, :4] = torch.tensor([0.0, 1.0, 2.0, 3.0])
        labels = torch.tensor([2], dtype=torch.long)

        loss = _safe_cross_entropy(logits, labels)
        self.assertTrue(torch.isfinite(loss).item())
        loss.backward()
        self.assertTrue(torch.isfinite(logits.grad).all().item())


if __name__ == "__main__":
    unittest.main()
