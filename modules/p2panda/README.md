# P2Panda candidate module

Optional native Rust P2Panda adapter for Starlings transport experiments.

This module is isolated from `src/`: the Starlings protocol core does not
depend on Rust, P2Panda, Iroh, or this crate.

## Provenance

```text
starlings snapshot: c5e54d9149db6110ecd2ee63a349be4fa941ec34
P2Panda fork:      https://github.com/beaglabs/p2panda
P2Panda rev:       80051611b7b41250815a40c945ae7bece84aa249
upstream basis:    v0.7.0
```

The exact Stage 7 policy pieces needed by the FFI are frozen under `zig/`.
They are experiment-substrate snapshots, not part of the current protocol-core
API.

## Validate

```sh
cargo test
```

See `run_suite.sh` for the historical transfer suite.
