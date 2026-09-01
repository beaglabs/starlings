from __future__ import annotations

import unittest

import torch

from murmurations.training.train import _is_float8_backbone_linear


class Float8SelectionTests(unittest.TestCase):
    def test_selects_only_backbone_linears_with_supported_shapes(self) -> None:
        good = torch.nn.Linear(1792, 5376, bias=False)
        self.assertTrue(
            _is_float8_backbone_linear(good, "blocks.0.attn.qkv")
        )

        protocol_head = torch.nn.Linear(1792, 12)
        self.assertFalse(
            _is_float8_backbone_linear(protocol_head, "operation_head")
        )

        wrong_name = torch.nn.Linear(1792, 1792, bias=False)
        self.assertFalse(
            _is_float8_backbone_linear(wrong_name, "blocks.0.not_backbone")
        )

        bad_shape = torch.nn.Linear(1792, 1793, bias=False)
        self.assertFalse(
            _is_float8_backbone_linear(bad_shape, "blocks.0.attn.out")
        )


if __name__ == "__main__":
    unittest.main()
