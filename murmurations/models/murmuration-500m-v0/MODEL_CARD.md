# Murmuration 500M v0

**Status:** architecture defined; no checkpoint published.

This is the fixed-transformer baseline for the Murmurations hypothesis. It is
trained from initialization to treat Starlings protocol actions and retrieved
operator use as native outputs rather than prose conventions.

## Architecture

- 503,413,791 trainable parameters at a 32,768-token vocabulary
- decoder-only causal transformer
- width 1,024
- 28 blocks
- 16 attention heads
- 4,096-wide SwiGLU
- RoPE + RMSNorm
- tied token embedding / language projection
- separate operation head
- separate structured argument head

## Protocol surface

The operation head predicts:

`NOOP OBSERVE QUERY CLAIM EVIDENCE PROPOSE ACCEPT REJECT CHALLENGE RETRACT DELEGATE EXECUTE`.

The argument head predicts typed argument spans, a pointer to an OR-retrieved
operator when applicable, up to four direct parent pointers, parent count, and
confidence. Operator names and BLAKE3 identities are not free-form generated
when a grounded reference exists.

## Training order

Train and benchmark the conventional 500M backbone first with dynamic repository
episodes and Operator Retrieval. Local-k=7 parameter dynamics remain a later
ablation so their effect can be measured against the same data and tools.
