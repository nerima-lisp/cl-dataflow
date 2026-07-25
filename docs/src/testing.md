# Testing and Coverage

## Running the suite

The test ASDF system is `cl-dataflow/test`. `asdf:test-system :cl-dataflow`
dispatches to it:

```lisp
(asdf:test-system :cl-dataflow)
```

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
own test suite:

- `run-pipeline-with-test-context` seeds `state`, `metadata`, and effect
  handlers onto a fresh context and returns that live context after execution.
- `assert-emitted-events` / `assert-performed-effects` accept either a single
  expected type or a list of expected types.
- `assert-final-state`, `assert-state-machine-state`, and
  `assert-pipeline-result` check the shape of a run's outcome directly.

See the [Testing helpers APIs](api-reference.md#testing-helpers) for the full
signature list.
