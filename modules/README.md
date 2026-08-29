# Optional modules

Optional integrations and candidate substrates live here so they can carry
their own toolchains and dependencies without becoming dependencies of the
Starlings protocol core.

- `p2panda/` — native Rust P2Panda candidate transport harness with a
  frozen Stage 7 Zig policy/experiment snapshot.

Core code under `src/` must not import from `modules/`.
