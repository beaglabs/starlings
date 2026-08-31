"""~500M protocol-native causal transformer with three output heads."""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from typing import Any

import torch
from torch import Tensor, nn
import torch.nn.functional as F

from murmurations.utils.protocol import ArgumentKind, Operation


@dataclass
class MurmurationConfig:
    vocab_size: int = 32768
    d_model: int = 1024
    n_layers: int = 28
    n_heads: int = 16
    d_ff: int = 4096
    max_seq_len: int = 4096
    rope_base: float = 10000.0
    rms_eps: float = 1e-6
    dropout: float = 0.0
    max_parents: int = 4

    def asdict(self) -> dict[str, Any]:
        return asdict(self)


class RMSNorm(nn.Module):
    def __init__(self, width: int, eps: float) -> None:
        super().__init__()
        self.weight = nn.Parameter(torch.ones(width))
        self.eps = eps

    def forward(self, x: Tensor) -> Tensor:
        norm = x.float().pow(2).mean(dim=-1, keepdim=True)
        return x * torch.rsqrt(norm + self.eps).to(x.dtype) * self.weight


class RotaryEmbedding(nn.Module):
    def __init__(self, dim: int, max_seq_len: int, base: float) -> None:
        super().__init__()
        inv_freq = 1.0 / (base ** (torch.arange(0, dim, 2).float() / dim))
        positions = torch.arange(max_seq_len).float()
        freqs = torch.outer(positions, inv_freq)
        self.register_buffer("cos", freqs.cos(), persistent=False)
        self.register_buffer("sin", freqs.sin(), persistent=False)

    def forward(self, q: Tensor, k: Tensor, seq_len: int) -> tuple[Tensor, Tensor]:
        cos = self.cos[:seq_len].to(dtype=q.dtype)[None, None, :, :]
        sin = self.sin[:seq_len].to(dtype=q.dtype)[None, None, :, :]
        return _apply_rope(q, cos, sin), _apply_rope(k, cos, sin)


def _apply_rope(x: Tensor, cos: Tensor, sin: Tensor) -> Tensor:
    even, odd = x[..., ::2], x[..., 1::2]
    rotated_even = even * cos - odd * sin
    rotated_odd = even * sin + odd * cos
    return torch.stack((rotated_even, rotated_odd), dim=-1).flatten(-2)


class CausalSelfAttention(nn.Module):
    def __init__(self, cfg: MurmurationConfig, rope: RotaryEmbedding) -> None:
        super().__init__()
        if cfg.d_model % cfg.n_heads:
            raise ValueError("d_model must be divisible by n_heads")
        self.n_heads = cfg.n_heads
        self.head_dim = cfg.d_model // cfg.n_heads
        self.dropout = cfg.dropout
        self.qkv = nn.Linear(cfg.d_model, 3 * cfg.d_model, bias=False)
        self.out = nn.Linear(cfg.d_model, cfg.d_model, bias=False)
        self.rope = rope

    def forward(self, x: Tensor) -> Tensor:
        batch, seq_len, width = x.shape
        qkv = self.qkv(x).view(batch, seq_len, 3, self.n_heads, self.head_dim)
        q, k, v = qkv.unbind(dim=2)
        q = q.transpose(1, 2)
        k = k.transpose(1, 2)
        v = v.transpose(1, 2)
        q, k = self.rope(q, k, seq_len)
        y = F.scaled_dot_product_attention(
            q,
            k,
            v,
            dropout_p=self.dropout if self.training else 0.0,
            is_causal=True,
        )
        y = y.transpose(1, 2).contiguous().view(batch, seq_len, width)
        return self.out(y)


class SwiGLU(nn.Module):
    def __init__(self, cfg: MurmurationConfig) -> None:
        super().__init__()
        self.gate = nn.Linear(cfg.d_model, cfg.d_ff, bias=False)
        self.up = nn.Linear(cfg.d_model, cfg.d_ff, bias=False)
        self.down = nn.Linear(cfg.d_ff, cfg.d_model, bias=False)

    def forward(self, x: Tensor) -> Tensor:
        return self.down(F.silu(self.gate(x)) * self.up(x))


class Block(nn.Module):
    def __init__(self, cfg: MurmurationConfig, rope: RotaryEmbedding) -> None:
        super().__init__()
        self.attn_norm = RMSNorm(cfg.d_model, cfg.rms_eps)
        self.attn = CausalSelfAttention(cfg, rope)
        self.ffn_norm = RMSNorm(cfg.d_model, cfg.rms_eps)
        self.ffn = SwiGLU(cfg)

    def forward(self, x: Tensor) -> Tensor:
        x = x + self.attn(self.attn_norm(x))
        x = x + self.ffn(self.ffn_norm(x))
        return x


class ArgumentHead(nn.Module):
    """Structured argument grounding over the current context.

    Spans and parent references are pointers into context. BLAKE3 IDs are
    assigned only after the host materializes a canonical action frame.
    """

    def __init__(self, cfg: MurmurationConfig) -> None:
        super().__init__()
        width = cfg.d_model
        self.max_parents = cfg.max_parents
        self.kind = nn.Linear(width, len(ArgumentKind))
        self.confidence = nn.Linear(width, 1)
        self.parent_count = nn.Linear(width, cfg.max_parents + 1)
        self.start_gate = nn.Parameter(torch.ones(width))
        self.end_gate = nn.Parameter(torch.ones(width))
        self.parent_gates = nn.Parameter(torch.ones(cfg.max_parents, width))
        self.scale = width**-0.5

    def forward(
        self,
        hidden: Tensor,
        control: Tensor,
        control_positions: Tensor,
    ) -> dict[str, Tensor]:
        start_query = control * self.start_gate
        end_query = control * self.end_gate
        span_start = torch.einsum("bd,btd->bt", start_query, hidden) * self.scale
        span_end = torch.einsum("bd,btd->bt", end_query, hidden) * self.scale

        parent_query = control[:, None, :] * self.parent_gates[None, :, :]
        parent_pointer = torch.einsum("bpd,btd->bpt", parent_query, hidden) * self.scale

        positions = torch.arange(hidden.shape[1], device=hidden.device)[None, :]
        invalid = positions > control_positions[:, None]
        span_start = span_start.masked_fill(invalid, torch.finfo(span_start.dtype).min)
        span_end = span_end.masked_fill(invalid, torch.finfo(span_end.dtype).min)
        parent_pointer = parent_pointer.masked_fill(
            invalid[:, None, :], torch.finfo(parent_pointer.dtype).min
        )

        return {
            "argument_kind_logits": self.kind(control),
            "argument_start_logits": span_start,
            "argument_end_logits": span_end,
            "parent_pointer_logits": parent_pointer,
            "parent_count_logits": self.parent_count(control),
            "confidence": torch.sigmoid(self.confidence(control)).squeeze(-1),
        }


class MurmurationModel(nn.Module):
    def __init__(self, cfg: MurmurationConfig) -> None:
        super().__init__()
        self.config = cfg
        self.token_embedding = nn.Embedding(cfg.vocab_size, cfg.d_model)
        head_dim = cfg.d_model // cfg.n_heads
        self.rope = RotaryEmbedding(head_dim, cfg.max_seq_len, cfg.rope_base)
        self.blocks = nn.ModuleList([Block(cfg, self.rope) for _ in range(cfg.n_layers)])
        self.final_norm = RMSNorm(cfg.d_model, cfg.rms_eps)
        self.operation_head = nn.Linear(cfg.d_model, len(Operation))
        self.argument_head = ArgumentHead(cfg)
        self.apply(self._init_weights)

    @staticmethod
    def _init_weights(module: nn.Module) -> None:
        if isinstance(module, (nn.Linear, nn.Embedding)):
            nn.init.normal_(module.weight, mean=0.0, std=0.02)
            if isinstance(module, nn.Linear) and module.bias is not None:
                nn.init.zeros_(module.bias)

    def forward(self, input_ids: Tensor, control_positions: Tensor) -> dict[str, Tensor]:
        if input_ids.shape[1] > self.config.max_seq_len:
            raise ValueError("sequence exceeds configured max_seq_len")
        hidden = self.token_embedding(input_ids)
        for block in self.blocks:
            hidden = block(hidden)
        hidden = self.final_norm(hidden)

        batch_index = torch.arange(input_ids.shape[0], device=input_ids.device)
        control = hidden[batch_index, control_positions]

        # Tied language head: no second vocabulary-sized parameter matrix.
        language_logits = F.linear(hidden, self.token_embedding.weight)
        outputs = {
            "language_logits": language_logits,
            "operation_logits": self.operation_head(control),
        }
        outputs.update(self.argument_head(hidden, control, control_positions))
        return outputs

    def parameter_count(self) -> int:
        return sum(parameter.numel() for parameter in self.parameters())
