# Contributing

`cl-dataflow` is intentionally small and test-driven. Contributions are
easiest to review when they preserve that shape.

## Before you change code

- Read [Core Concepts](core-concepts.md) and the
  [Public API Reference](api-reference.md) to understand the current
  surface and verification expectations.
- Prefer the smallest change that improves the real behavior or
  documentation.
- Keep collection readers returning snapshots (see
  [Architecture → Snapshot semantics](architecture.md#snapshot-semantics))
  unless a mutation surface is explicitly intended.

## Local verification

Use the bundled scripts. Each one runs the suite through `cl-weave` when it is
on `PATH`, and falls back to `nix run .` otherwise:

```bash
./scripts/verify.sh
./scripts/coverage.sh
sbcl --script examples/simple-pipeline.lisp
sbcl --script examples/event-workflow.lisp
sbcl --script examples/state-machine.lisp
```

If you add or change public behavior, update or add the narrowest test that
proves it. See [Testing and Coverage](testing.md) for the coverage gate and
CI matrix.

## Style

- Keep the API surface explicit and documented.
- Prefer snapshot semantics for readers of mutable collections.
- Keep example scripts runnable as smoke tests.
- Use ASCII unless the existing file clearly needs something else.

## Pull requests

- Summarize the user-visible change first.
- Call out any compatibility impact.
- Include the verification commands you ran.

## Releasing

Releases are tag-driven. To cut version `X.Y.Z`:

1. Bump `:version` in both systems in `cl-dataflow.asd` and both `version`
   fields in `flake.nix`.
2. Move the `## [Unreleased]` entries in `CHANGELOG.md` under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading, reset `## [Unreleased]`, and update the
   compare/link references at the bottom.
3. Update the version badge in `README.md`.
4. Merge the change, then tag the merge commit:

   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

Pushing the tag runs `.github/workflows/release.yml`, which verifies the tag
matches `cl-dataflow.asd`, extracts the matching `CHANGELOG.md` section, and
publishes a GitHub release. The tag must equal the `.asd` version or the
release job fails by design.

## Documentation

This site is built with [MkDocs](https://www.mkdocs.org/) and the
[Material](https://squidfunk.github.io/mkdocs-material/) theme from
`docs/src/`. Preview changes locally:

```bash
nix build .#docs   # matches the GitHub Pages build exactly, offline
```

or, with `mkdocs-material` on your `PATH`:

```bash
mkdocs serve -f docs/mkdocs.yml
```

`docs.yml` publishes the built site to GitHub Pages on every push to `main`
that touches `docs/**`, `flake.nix`, or `flake.lock`.
