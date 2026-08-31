# Models

This directory versions Murmurations **model definitions and manifests**.

A 503,410,717-parameter checkpoint does not fit normal GitHub blob storage:

- fp32 weights: ~2.01 GB
- bf16/fp16 weights: ~1.01 GB
- int8 weights: ~503 MB before metadata
- 4-bit weights: ~252 MB before metadata

Therefore normal Git history stores configuration, tokenizer metadata, model
cards, and cryptographic manifests. Trained weights belong in one of:

1. local `weights/` directories (ignored by Git);
2. Git LFS, if the repository explicitly adopts it;
3. a GitHub Release;
4. a versioned object store / model registry.

A published manifest should record both a conventional SHA-256 and a BLAKE3
content identity for each weight shard.
