# trials/

This directory is reserved for **local generated experiment output**.

Generated TSV/JSON/trace/metadata files are intentionally not committed. The
scientific record belongs in `docs/`:

- freeze the canonical dataset SHA-256;
- record the frozen world/seed/budget shape;
- record the result summary and conclusion;
- keep git history as the regeneration source.

Everything under this directory except this README is ignored by Git.

## Local cleanup

To clear generated outputs while preserving this README:

```sh
find trials -mindepth 1 ! -name README.md -delete
```

Do not delete a canonical local dataset until its hash and result have been
recorded in the relevant stage documentation.
