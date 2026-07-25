# Contributing

`cl-dataflow` is intentionally small and test-driven. Contributions are easiest to review when they preserve that shape.

## Before you change code

- Read `README.md` to understand the public API and current verification surface.
- Prefer the smallest change that improves the real behavior or documentation.
- Keep collection readers returning snapshots unless a mutation surface is explicitly intended.

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

If you add or change public behavior, update or add the narrowest test that proves it.

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

1. Bump `:version` in both systems in `cl-dataflow.asd` and both `version` fields in `flake.nix`.
2. Move the `## [Unreleased]` entries in `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD` heading, reset `## [Unreleased]`, and update the compare/link references at the bottom.
3. Update the version badge in `README.md`.
4. Merge the change, then tag the merge commit: `git tag vX.Y.Z && git push origin vX.Y.Z`.

Pushing the tag runs `.github/workflows/release.yml`, which verifies the tag
matches `cl-dataflow.asd`, extracts the matching `CHANGELOG.md` section, and
publishes a GitHub release. The tag must equal the `.asd` version or the release
job fails by design.
