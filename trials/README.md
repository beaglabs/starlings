# trials/

This directory is reserved for **bounded experiments and their local generated output**.

A named trial may commit its small specification, population, and test harness.
Generated TSV/JSON/trace/mesh/model output is intentionally not committed. The
scientific record belongs in `docs/` or the trial README:

- freeze the canonical dataset SHA-256;
- record the frozen world/seed/budget shape;
- record the result summary and conclusion;
- keep git history as the regeneration source.

Generated trial output remains ignored by Git. Individual trial definitions may
be explicitly allow-listed in `.gitignore`.

## Local cleanup

To clear generated outputs while preserving this README:

```sh
find trials -mindepth 1 ! -name README.md -delete
```

Do not delete a canonical local dataset until its hash and result have been
recorded in the relevant stage documentation.
