# 3D emergent asset trial

This trial asks a narrow question:

> Can a Starlings population select and validate different 3D reconstruction
> and rigging realizations from local state without encoding a workflow?

The trial is inspired by:

- TripoSR: https://github.com/VAST-AI-Research/TripoSR
- TripoSG: https://github.com/VAST-AI-Research/TripoSG
- UniRig: https://github.com/VAST-AI-Research/UniRig

It does **not** claim to reproduce their learned quality. The committed reference
lane uses deterministic model-provider stand-ins so the Starlings semantics can
be falsified independently of CUDA, model downloads, or third-party Python
environments.

## Run

From the repository root:

```sh
zig build trial-3d
```

The build step runs two scenarios:

1. **CPU-only / 8 GB** — the TripoSG-like capability observes that no GPU is
   available and publishes blocked outputs. The fast reconstruction branch
   remains viable, is rigged and validated, and becomes `asset.selected`.
2. **GPU-capable** — both reconstruction branches are viable. The
   higher-confidence fidelity branch is independently rigged and validated and
   supersedes the fast candidate through the normal `highest_confidence`
   merge policy.

No operator names another operator. The population only declares
`requires`/`provides`.

## Population

```text
source.image      resource.memory_mb      resource.gpu
      |                  |                    |
      +----------+-------+--------------------+
                 |                            |
        fast-reconstruction          fidelity-reconstruction
           (TripoSR-like)               (TripoSG-like)
                 |                            |
              mesh.fast                  mesh.fidelity
                 |                            |
              rig-fast                   rig-fidelity
          (UniRig-like)                 (UniRig-like)
                 |                            |
           validate-fast              validate-fidelity
                 |                            |
            select-fast               select-fidelity
                 \__________________________/
                              |
                       asset.selected
```

The diagram describes possible state dependencies, not authored execution order.

## Why the reference lane comes first

Emergence cannot remove the arithmetic cost of a neural model. It can:

- keep expensive capabilities dormant when local resources make them unsuitable;
- let a cheaper reconstruction remain useful instead of treating it as a hard
  fallback branch;
- run model-backed capabilities one at a time to reduce resident memory;
- allow alternate CPU-native implementations to satisfy the same semantic
  capability;
- use validators to decide whether a cheaper realization is already sufficient.

The reference lane proves those semantics before model-porting work begins.

## Real M2 lane

### TripoSR

This is the best first real backend.

The upstream runner already falls back to `cpu` when CUDA is unavailable. A
small M2 experiment should start with:

- one image;
- background removal disabled if possible;
- reduced marching-cubes resolution (for example 64-128 instead of 256);
- a small renderer chunk size;
- no texture baking or video rendering;
- one resident model at a time.

The pretrained checkpoint is much smaller than TripoSG, but inference will be
far slower than the reported A100 runtime.

### TripoSG

The released implementation is CUDA/fp16 oriented and the public image model is
a 1.5B-parameter rectified-flow transformer with a 3D VAE and image encoders.
The algorithm itself is not mathematically GPU-specific, but exact inference is
a poor CPU-only 8 GB target.

A later experiment can try one of:

- the 512-token CFG-distilled scribble variant;
- Apple MPS with CPU fallback for unsupported 3D ops;
- sequential component loading/offload;
- a smaller reimplementation of the rectified-flow/VAE idea.

That would test the algorithmic idea, not reproduce the released model's quality.

### UniRig

The paper's skeleton stage uses an OPT-125M autoregressive model conditioned on
a geometric encoder, while skinning uses point features plus bone-point cross
attention. Those operations are not inherently GPU-only.

The upstream implementation is CUDA-oriented (including FlashAttention and
other point/sparse dependencies), so an M2 realization should replace those
implementation choices rather than attempt to preserve CUDA kernels.

A CPU-oriented experimental realization can reduce point counts, use ordinary
attention, chunk skinning evaluation, and preserve Skeleton Tree Tokenization
and the same semantic outputs.

## What would count as success

Reference success:

- CPU-only state reaches `asset.selected` without the fidelity branch.
- GPU-capable state allows both branches and selects the higher-confidence one.
- no operator directly invokes another operator;
- the same YAML population handles both scenarios.

Real-backend success, later:

- at least one actual single-image reconstruction runs on the M2 and enters the
  same population as a real artifact;
- a CPU-oriented rigging realization consumes that mesh;
- validators can accept or reject the resulting candidate;
- changing resource observations changes the realized population without
  changing the authored population.

Generated meshes, traces, and timing data should go under:

```text
trials/3d-emergent-asset/out/
```

and remain untracked.
