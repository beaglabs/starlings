# ADR-0001: Content-Addressed Causal Provenance

## Status

Accepted.

## Decision

Starlings requires content-addressed causal DAG provenance as part of its core architecture.

`ContentId` is a 256-bit BLAKE3 digest (`[32]u8`). Provenance event identity is derived from a versioned canonical byte representation rather than in-memory struct layout.

Canonical encoding v1 is:

```text
version:u8
|| event_kind:u8
|| payload:u64 little-endian
|| parent_count:u8
|| parent_content_ids[0..parent_count]
```

Parent order is significant. Any incompatible canonical encoding change must increment the canonical version.

Runtime causal references use `ContentId` rather than ad-hoc integer IDs.

## Why this is required

The Stage 2 validation and stress suites established that the causal DAG model:

- deduplicates repeated provenance records while preserving replay semantics;
- reconstructs causal closure across chains and fork/merge graphs;
- identifies exact missing content between divergent replicas;
- makes content mutation observable through identity changes.

The duplicate-heavy stress case represented 65 append-log records as 2 unique DAG nodes while preserving replay state.

These results satisfy the architectural admission criteria for content-addressed provenance.

## Cryptographic primitive

BLAKE3-256 is used for content identity through Zig's `std.crypto.hash.Blake3` API.

The digest API is isolated behind `provenance.contentId`. Callers depend on `ContentId` semantics, not Zig's crypto API.

## Consequences

- Provenance-aware components must use content IDs for causal identity.
- Canonical serialization is protocol surface and must be versioned deliberately.
- Content IDs are 32 bytes rather than experimental 64-bit integers.
- DAG storage/index implementations may change without changing content identity semantics.
- Performance and storage indexing remain implementation concerns subject to later benchmarks.

## Superseded experimental behavior

The earlier 64-bit experimental hash is removed. It was used only to validate the DAG model and is not a supported persistent identity format.
