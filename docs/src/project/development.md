# Development

## The Nix entry points

Everything CI runs is reachable from the flake, so a local run and a CI run
gate on exactly the same derivations:

```bash
nix develop      # SBCL with CL_SOURCE_REGISTRY already set
nix run .#test   # run the test suite
nix run .#watch  # re-run the suite on every source change (cl-weave watch)
nix flake check  # every check below, in parallel, with build caching
nix fmt          # format Nix sources (treefmt/nixfmt)
nix build .#docs # render this site, offline, with mkdocs --strict
```

`nix flake check` evaluates five checks:

| Check | What it gates |
| --- | --- |
| `checks.default` | the `cl-dataflow/test` suite under `cl-weave` |
| `checks.coverage` | the coverage thresholds below, plus the report artifact |
| `checks.examples` | every `examples/*.lisp` script runs to a clean exit, each under a hard timeout (see [Examples](../guide/examples.md#example-scripts-as-regression-tests)) |
| `checks.paredit-lint` | every Lisp file parses under `paredit` |
| `checks.formatting` | every Nix file is nixfmt-formatted |
| `checks.docs` | this site builds under `mkdocs --strict` |

Granularity lives in these attributes rather than in extra GitHub Actions
jobs, because `nix flake check` already runs them in parallel and shares a
build cache between them.

## Running the suite

The test ASDF system is `cl-dataflow/test`. `asdf:test-system :cl-dataflow`
dispatches to it:

```lisp
(asdf:test-system :cl-dataflow)
```

Without Nix, the repository-root entry point runs the same suite:

```bash
sbcl --script run-tests.lisp
```

Either way, `cl-weave` and `cl-process-kit` must be on the ASDF source
registry — and because `cl-process-kit`'s own system depends on them, so must
[`cl-boundary-kit`](https://github.com/nerima-lisp/cl-boundary-kit) and
[`cl-log-kit`](https://github.com/nerima-lisp/cl-log-kit). See
[Getting Started](../getting-started.md#verifying-the-install).

`./scripts/verify.sh` wraps the suite, and `./scripts/run-examples.sh` runs
every `examples/*.lisp` script as its own process (the same check
`checks.examples` runs in CI), doubling as a smoke test for the core
execution paths:

```bash
./scripts/verify.sh
./scripts/run-examples.sh
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
- **Soft assertions** — `with-soft-assertions` lets every `expect` in a block
  run to completion and reports all failures together, instead of aborting at
  the first. `t/helpers-assertions.lisp`'s multi-field assertion macros
  (`assert-plist-entry`, `assert-graph-condition`,
  `assert-state-machine-condition`, etc.) and the acyclic/topological-order
  property test use it, so a failing run shows every mismatched field (or
  every violated invariant on the same shrunk sample) in one report.

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

`ci.yml` runs a single `check` job on `ubuntu-latest` that does nothing but
`nix flake check --print-build-logs`, so the CI gate and the local gate are
the same set of derivations.

`docs.yml` publishes this site to GitHub Pages on every push to `main` that
touches `docs/**`, `flake.nix`, or `flake.lock`.

`flake-update.yml` opens a weekly pull request bumping every flake input.

Pushing a `vX.Y.Z` tag triggers `release.yml`, which verifies the tag matches
`cl-dataflow.asd`'s `:version`, runs `nix flake check`, and opens a **draft**
GitHub release with an empty body. The tag must equal the `.asd` version or the
release job fails by design. The release description is written by hand and is
this project's only changelog:

```sh
gh release edit vX.Y.Z --notes-file notes.md --draft=false
```

## Editing this site

The site is built with [MkDocs](https://www.mkdocs.org/) and the
[Material](https://squidfunk.github.io/mkdocs-material/) theme from
`docs/src/`. Preview changes locally:

```bash
nix build .#docs                 # matches the Pages build exactly, offline
mkdocs serve -f docs/mkdocs.yml  # with mkdocs-material on PATH
```

Every page must appear in `nav`: `--strict` turns an unlisted page or a broken
link into a build failure, which is what makes `checks.docs` useful.

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

The [Public API Reference](../reference/api.md#testing-helpers) lists these
alongside the rest of the exported surface.
