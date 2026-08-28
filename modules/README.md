# Optional modules

Starlings Core remains dependency-light and lives under `src/`.

Optional integration/runtime modules live here. They may introduce their own language toolchains and dependencies without becoming dependencies of the core coordination substrate.

- `p2panda/` — Stage 7C native Rust P2Panda distributed-runtime transfer harness. It links the exact Zig Stage 7 policy through a small C ABI.
