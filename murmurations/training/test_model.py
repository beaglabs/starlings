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
        self.assertEqual(output["operator_pointer_logits"].shape, (2, 8))
        self.assertEqual(output["parent_pointer_logits"].shape, (2, 4, 8))
        self.assertEqual(output["parent_count_logits"].shape, (2, 5))
        self.assertEqual(output["confidence"].shape, (2,))

    def test_pointer_heads_exclude_control_token_itself(self) -> None:
        cfg = MurmurationConfig(
            vocab_size=64,
            d_model=32,
            n_layers=1,
            n_heads=4,
            d_ff=64,
            max_seq_len=16,
            max_parents=4,
        )
        model = MurmurationModel(cfg)
        tokens = torch.randint(0, cfg.vocab_size, (2, 8))
        control = torch.tensor([5, 6])
        output = model(tokens, control)

        minimum = torch.finfo(output["operator_pointer_logits"].dtype).min
        for batch_index, control_index in enumerate(control.tolist()):
            self.assertEqual(
                float(output["argument_start_logits"][batch_index, control_index].item()),
                float(minimum),
            )
            self.assertEqual(
                float(output["argument_end_logits"][batch_index, control_index].item()),
                float(minimum),
            )
            self.assertEqual(
                float(output["operator_pointer_logits"][batch_index, control_index].item()),
                float(minimum),
            )
            self.assertTrue(
                torch.all(
                    output["parent_pointer_logits"][
                        batch_index, :, control_index
                    ]
                    == minimum
                ).item()
            )

    def test_pointer_projection_receives_gradient(self) -> None:
        cfg = MurmurationConfig(
            vocab_size=64,
            d_model=32,
            n_layers=1,
            n_heads=4,
            d_ff=64,
            max_seq_len=16,
            max_parents=4,
            pointer_dim=16,
        )
        model = MurmurationModel(cfg)
        tokens = torch.randint(0, cfg.vocab_size, (2, 8))
        control = torch.tensor([6, 6])
        output = model(tokens, control)

        target = torch.tensor([2, 3])
        loss = torch.nn.functional.cross_entropy(
            output["operator_pointer_logits"], target
        )
        loss.backward()

        for parameter in (
            model.argument_head.pointer_key.weight,
            model.argument_head.operator_query.weight,
        ):
            self.assertIsNotNone(parameter.grad)
            self.assertTrue(torch.isfinite(parameter.grad).all().item())
            self.assertGreater(float(parameter.grad.abs().sum().item()), 0.0)

    def test_default_architecture_parameter_count_is_stable(self) -> None:
        cfg = MurmurationConfig()
        embedding = cfg.vocab_size * cfg.d_model
        per_layer = (
            4 * cfg.d_model * cfg.d_model
            + 3 * cfg.d_model * cfg.d_ff
            + 2 * cfg.d_model
        )
        backbone = embedding + cfg.n_layers * per_layer + cfg.d_model
        operation = cfg.d_model * len(Operation) + len(Operation)
        pointer_dim = min(cfg.pointer_dim, cfg.d_model)
        argument = (
            cfg.d_model * len(ArgumentKind) + len(ArgumentKind)
            + cfg.d_model + 1
            + cfg.d_model * (cfg.max_parents + 1) + (cfg.max_parents + 1)
            + (4 + cfg.max_parents) * cfg.d_model * pointer_dim
        )
        self.assertEqual(backbone + operation + argument, 504_455_199)


if __name__ == "__main__":
    unittest.main()
