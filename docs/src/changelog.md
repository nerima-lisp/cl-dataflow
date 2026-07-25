# Changelog

`cl-dataflow` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html). This page
summarizes each release; the full entry-by-entry history — every module added
and every internal change — lives in
[`CHANGELOG.md`](https://github.com/nerima-lisp/cl-dataflow/blob/main/CHANGELOG.md)
at the repository root.

## [0.3.0] — 2026-07-24

A structural and performance release. **The public API is unchanged.** The
internals were reorganized for readability and the hot paths were optimized,
growing the suite to 510 tests while holding the 100%-branch-coverage gate.

- Flattened the source layout: removed the `%load-fragment` macro and six
  aggregator files that double-loaded fragments outside ASDF, listing every
  real source file directly in the system definition.
- Split the oversized `graph-paths` module into `graph-closure`,
  `graph-shortest-path`, `graph-flow`, and `graph-eulerian`.
- Consolidated the twelve single-source reactive operators behind a
  `define-subject-operator` macro, routed stream consumers through a shared
  `do-stream` macro, and drove the pipeline/state-machine DSL expanders and
  the graph eccentricity family from schema tables.
- Made structural deep-copy stack-safe with an explicit CPS trampoline.
- **Performance:** indexed state-machine transitions by from-state and event
  type; cached a pipeline execution plan and reused it while topology is
  unchanged; appended reactive subscribers through a tail pointer and emitted
  against a snapshot; gave `stream-distinct`/`subject-distinct` a hash
  fast-path for standard designators.

## [0.2.0] — 2026-07-20

The large feature release: nearly every module beyond the 0.1.0 core shipped
here — graph algorithms, export, mutation, paths, metrics, connectivity,
algebra, and criticality; state-machine analysis, execution, and builders;
combinators and node contracts; pull streams (core, extras, ops, stats,
search); reactive subjects and operators; observability, effect ergonomics,
context serialization, introspection, and iterative (feedback) pipelines. See
the full [`CHANGELOG.md`](https://github.com/nerima-lisp/cl-dataflow/blob/main/CHANGELOG.md#020---2026-07-20)
entry for the complete module-by-module list — it documents every exported
symbol introduced in this release. New tests grew the suite from 189 to 418
while holding the coverage gate at 100% branch / ≥84% expression.

## [0.1.0] — 2026-07-20

First public release. `cl-dataflow` provides composable computation graphs,
sequential and branching pipelines, event-driven workflows, guarded state
machines, effect boundaries, and deterministic testing helpers behind a
single public package — plus `graph-descendants`/`graph-ancestors`/`graph-path`
reachability APIs, structured error conditions with detail readers, explicit
copy helpers, and advanced `cl-weave` property/model-based test coverage.

---

Releases are tag-driven: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`,
which verifies the tag matches `cl-dataflow.asd`'s `:version`, extracts the
matching `CHANGELOG.md` section, and publishes a GitHub release from it. See
[Contributing → Releasing](contributing.md#releasing) for the full process.
