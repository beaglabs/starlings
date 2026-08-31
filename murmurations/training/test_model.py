from __future__ import annotations

import unittest

import torch

from murmurations.training.model import MurmurationConfig, MurmurationModel
from murmurations.utils.protocol import ArgumentKind, Operation


class ModelTests(unittest.TestCase):
    def test_tiny_model_exposes_three_head_surface(self) -> None:
        cfg = MurmurationConfig(
            vocab_size=64,
            d_model=32,
            n_layers=2,
            n_heads=4,
            d_ff=64,
            max_seq_len=16,
            max_parents=4,
        )
        model = MurmurationModel(cfg)
        tokens = torch.randint(0, cfg.vocab_size, (2, 8))
        control = torch.tensor([5, 6])
        output = model(tokens, control)

        self.assertEqual(output["language_logits"].shape, (2, 8, 64))
        self.assertEqual(output["operation_logits"].shape, (2, len(Operation)))
        self.assertEqual(output["argument_kind_logits"].shape, (2, len(ArgumentKind)))
        self.assertEqual(output["argument_start_logits"].shape, (2, 8))
        self.assertEqual(output["argument_end_logits"].shape, (2, 8))
        self.assertEqual(output["parent_pointer_logits"].shape, (2, 4, 8))
        self.assertEqual(output["parent_count_logits"].shape, (2, 5))
        self.assertEqual(output["confidence"].shape, (2,))

    def test_default_architecture_parameter_count_is_stable(self) -> None:
        # Formula test avoids allocating a 503M-parameter model in unit tests.
        cfg = MurmurationConfig()
        embedding = cfg.vocab_size * cfg.d_model
        per_layer = (
            4 * cfg.d_model * cfg.d_model
            + 3 * cfg.d_model * cfg.d_ff
            + 2 * cfg.d_model
        )
        backbone = embedding + cfg.n_layers * per_layer + cfg.d_model
        operation = cfg.d_model * len(Operation) + len(Operation)
        argument = (
            cfg.d_model * len(ArgumentKind) + len(ArgumentKind)
            + cfg.d_model + 1
            + cfg.d_model * (cfg.max_parents + 1) + (cfg.max_parents + 1)
            + cfg.d_model
            + cfg.d_model
            + cfg.max_parents * cfg.d_model
        )
        self.assertEqual(backbone + operation + argument, 503_410_717)


if __name__ == "__main__":
    unittest.main()
