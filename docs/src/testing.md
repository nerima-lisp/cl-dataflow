# Testing and Coverage

## Running the suite

The test ASDF system is `cl-dataflow/test`. `asdf:test-system :cl-dataflow`
dispatches to it:

```lisp
(asdf:test-system :cl-dataflow)
```

Outside Nix, `cl-weave` and `cl-process-kit` must be on the ASDF source
registry — and because `cl-process-kit`'s own system depends on them, so must
[`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit) and
[`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit). See
[Installation](installation.md#verifying-the-install).

Or with the Nix flake, without touching your global Lisp environment:

```bash
nix run          # cl-weave run cl-dataflow/test
nix flake check  # tests + coverage + paredit lint, on every supported system
```

The current local verification commands, also run in CI:

```bash
./scripts/verify.sh
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).coverage
sbcl --script examples/simple-pipeline.lisp
sbcl --script examples/event-workflow.lisp
sbcl --script examples/state-machine.lisp
```

## What the suite dogfoods

The suite is built on [`cl-weave`](https://github.com/nerima-lisp/cl-weave)
and dogfoods its advanced features:

- **Property-based generators** — `gen-tuple`, `gen-list`, `gen-integer` drive
  randomized structural tests.
- **Custom matchers** — `:to-have-valid-topological-order`, `:to-be-acyclic`,
  `:to-reach` express graph invariants directly in assertions.
- **Differential property tests** — cross-check `graph-reachable-p` against
  an independent reference transitive closure over random DAGs.
- **Performance guards** — `:to-run-under-ms` keeps deep-graph topological
  sort and reachability from regressing into superlinear behavior.

It covers branching pipeline behavior, event emission, state-machine
transitions, effect handling, the pipeline/state-machine workflow
integration used by the examples, and the exported testing helpers
themselves (including singleton expectations for event/effect assertions and
runtime-context seeding via `run-pipeline-with-test-context`).

## Coverage gate

Coverage is measured only for source files owned by the `cl-dataflow` ASDF
system (not `cl-weave`, `cl-prolog`, or the test system itself). The gate
requires:

- **≥ 84%** expression coverage
- **100%** branch coverage

Falling below either threshold fails the command. Run the gate locally:

```bash
./scripts/coverage.sh
```

Override output paths and thresholds with environment variables:

| Variable | Purpose |
| --- | --- |
| `COVERAGE_OUTPUT` | Path to the `.coverage` artifact |
| `COVERAGE_REPORT_DIR` | Directory for the generated HTML report |
| `COVERAGE_MIN_EXPRESSION` | Minimum expression-coverage percentage |
| `COVERAGE_MIN_BRANCH` | Minimum branch-coverage percentage |

## Continuous integration

GitHub Actions runs the CI workflow on a matrix of `ubuntu-latest`
(`x86_64-linux`) and `macos-latest` (`aarch64-darwin`), so cross-platform
support is verified on every push and pull request. Each job runs the same
`nix flake check` and coverage build as local verification, and uploads the
generated per-system coverage report as a build artifact.

Pushing a `vX.Y.Z` tag additionally triggers the release workflow, which
verifies the tag matches `cl-dataflow.asd`'s `:version`, extracts the
matching [`CHANGELOG.md`](changelog.md) section, and publishes a GitHub
release from it — see [Contributing](contributing.md#releasing).

## Testing helpers for downstream projects

`src/testing.lisp` exports deterministic assertion helpers usable from your
own test suite, independent of `cl-weave`:

```lisp
(run-pipeline-with-test-context pipeline &key input effect-handlers state metadata)
(assert-emitted-events    context expected)
(assert-performed-effects context expected)
(assert-final-state       context expected)
(assert-state-machine-state machine expected)
(assert-pipeline-result   context expected)
```

- `run-pipeline-with-test-context` seeds `state`, `metadata`, and effect
  handlers onto a fresh context, runs `pipeline` over `input`, and returns
  that live context — the run's return value is discarded, so assert on
  `assert-pipeline-result` rather than a returned value.
- `assert-emitted-events` / `assert-performed-effects` compare the context's
  full chronological type list (`context-event-types` /
  `context-effect-types`) against `expected`. A non-list `expected` is
  wrapped into a one-element list, so a singleton expectation can be written
  either way; `nil` asserts that nothing was emitted or performed.
- `assert-final-state`, `assert-state-machine-state`, and
  `assert-pipeline-result` compare `context-state`, `state-machine-state`,
  and `context-result` against `expected`.

Every assertion compares with `equal`, returns `t` on success, and signals a
`simple-error` naming the expected and actual values on failure — so they
compose with whatever test framework you already use.

The [Public API Reference](api-reference.md#testing-helpers) lists these
alongside the rest of the exported surface.
