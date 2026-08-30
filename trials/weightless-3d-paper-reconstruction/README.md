# Weightless 3D paper reconstruction trial

This trial tests whether Starlings can replace **amortized learned priors** with
explicit per-instance algorithms, hypotheses, constraints, and validation.

It is inspired by three papers:

- TripoSR — single-image 3D reconstruction with an image encoder,
  image-to-triplane transformer, and triplane NeRF.
- TripoSG — image-conditioned 3D generation with a rectified-flow transformer
  and an SDF VAE trained with SDF, normal, and eikonal supervision.
- UniRig — skeleton-tree tokenization, autoregressive skeleton generation, and
  bone-point cross-attention for skinning.

The trial uses **no pretrained weights, no learned model, and no GPU**.

## What this does and does not claim

It does **not** reproduce the published quality of TripoSR, TripoSG, or UniRig.
Their learned parameters carry essential information about natural images,
3D shape distributions, camera ambiguity, skeleton priors, and skinning.

Instead, this trial asks a different question:

> Can the reusable algorithmic structure of those methods be externalized into
> Starlings operators so the solution is synthesized for one instance rather
> than recalled from learned weights?

That is the Starlings hypothesis.

## Paper idea -> weightless realization

| Paper element | Weightless trial realization |
| --- | --- |
| TripoSR single image -> 3D | multiple explicit shape hypotheses |
| learned image prior | observed silhouette / symmetry / depth cue |
| triplane / NeRF representation | analytic implicit SDF candidates |
| rendering supervision | explicit silhouette-consistency score |
| TripoSG SDF representation | analytic signed-distance functions |
| TripoSG eikonal loss | finite-difference eikonal validator |
| rectified-flow learned vector field | per-instance hypothesis selection rather than learned transport |
| UniRig skeleton prediction | deterministic medial skeleton synthesis |
| Skeleton Tree Tokenization | explicit hierarchy-preserving tree token stream |
| learned bone-point cross-attention | normalized inverse-distance bone-point weights |
| learned confidence | validator-derived confidence claims |

## Why this is a meaningful test

A single view does not uniquely determine hidden 3D geometry. The trial preserves
that ambiguity deliberately.

Two candidates are constructed with the same front silhouette:

- an extrusion-like implicit solid;
- a body-of-revolution implicit solid.

Both are valid under the silhouette observation. Independent validators then use:

- silhouette consistency;
- an explicit hidden-depth cue;
- SDF eikonal regularity.

Each selector publishes the same `shape.selected` variable with confidence
derived from its validation score. The standard `highest_confidence` merge
policy determines which hypothesis is currently materialized.

No selector calls the skeletonizer. No skeletonizer calls the skinner. State
changes make capabilities independently applicable.

After selection:

1. a medial-axis-style operator synthesizes a skeleton tree token stream;
2. a topology validator checks the tree structure;
3. a deterministic skinning operator computes normalized bone-point weights;
4. an asset validator checks the resulting rig.

The same population is tested twice:

- with symmetry evidence, the body-of-revolution hypothesis should win;
- without symmetry evidence, that hypothesis becomes blocked and the extrusion
  should become the realized solution.

That change is caused by state, not an authored `if/else` workflow.

## Run

From the repository root:

```sh
zig build trial-weightless-3d
```

Also run the normal gates:

```sh
zig test src/root.zig
zig build test
python3 -m unittest discover -s python -p 'test_*.py'
```

## CPU / GPU hypothesis

Nothing in the mathematics used by this trial requires a GPU. It consists of:

- analytic SDF evaluation;
- finite-difference gradients;
- scalar optimization/scoring;
- tree construction and validation;
- distance-based skin weights.

The published neural methods use GPUs because their useful behavior is encoded
in large trained networks and because training/inference performs large dense
tensor workloads. The mathematical primitives themselves are not CUDA-only.

A successful trial would justify progressively replacing the toy observations
and candidate generators with richer CPU algorithms:

- segmentation and contour extraction;
- symmetry-axis detection;
- camera-hypothesis search;
- shape-from-shading;
- generalized cylinders and primitive decomposition;
- voxel/SDF refinement;
- differentiable or finite-difference inverse rendering;
- medial-axis / graph skeletonization;
- heat/geodesic skinning;
- deformation-based rig validation.

The long-term question is whether a population of those explicit capabilities
can recover enough of the prior normally compressed into model weights to be
useful on bounded domains.
