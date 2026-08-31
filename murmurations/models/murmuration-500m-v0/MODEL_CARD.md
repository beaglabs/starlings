# Murmuration 500M v0

**Status:** architecture defined; no checkpoint published.

This is the first fixed-transformer baseline for the Murmurations hypothesis.
It is trained from initialization to treat Starlings protocol actions as native
outputs rather than text conventions layered onto a generic LM.

## Architecture

- 503,410,717 trainable parameters at a 32,768-token vocabulary
- decoder-only causal transformer
- width 1,024
- 28 blocks
- 16 attention heads
- 4,096-wide SwiGLU
- RoPE
- RMSNorm
- tied token embedding / language projection
- separate operation head
- separate structured argument head

## Protocol surface

The operation head predicts one of:

`NOOP OBSERVE QUERY CLAIM EVIDENCE PROPOSE ACCEPT REJECT CHALLENGE RETRACT DELEGATE`.

The argument head grounds the operation into existing context through typed
argument kind, start/end pointers, up to four direct parent pointers, parent
count, and calibrated confidence.

The host then creates a canonical action frame, verifies that all parents exist,
and computes the BLAKE3 identity. This separation is intentional: cryptographic
identity is deterministic infrastructure, not a learned token-generation task.

## k=7 micro-dynamics

The first checkpoint should remain a conventional transformer baseline. The
500-million-parameter-agent / local-k=7 dynamics should be introduced as an
ablation only after this baseline is benchmarked. Otherwise gains or failures
cannot be attributed to the micro-dynamics.
