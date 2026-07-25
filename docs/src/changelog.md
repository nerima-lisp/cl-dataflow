# Changelog

`cl-dataflow` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html). This page
summarizes each release; the full entry-by-entry history — every module added
and every internal change — lives in
[`CHANGELOG.md`](https://github.com/nerima-lisp/cl-dataflow/blob/main/CHANGELOG.md)
at the repository root.

## [1.0.0] — 2026-07-26

The first stable release. Every symbol exported from the `cl-dataflow` package
is now covered by Semantic Versioning: a breaking change to any of them requires
a major-version bump. **No public API changed** — 1.0.0 marks the existing
surface as stable rather than reshaping it. The suite is at 515 tests, holding
the 100%-branch-coverage gate.

- Fixed a family of internal call sites that read through the library's
  *copying* public accessors where the internal live readers belong. The most
  costly was `perform-effect`, which snapshotted the entire effect-handler table
  just to resolve one key, putting an allocation proportional to the number of
  registered handlers on every performed effect. `print-object` for contexts and
  state machines, `context-summary`, `state-machine-last-transition`,
  `copy-context`, and `copy-state-machine` had the same shape. No public API or
  observable behavior changed — the copy-isolation guarantees come from the
  setters, which is why the reader-side copies were redundant.
- Corrected the documentation for `context-effect-handlers`, which was described
  as returning the live, mutable handler table. It returns a snapshot, so
  registering a handler by mutating what it returns silently did nothing; use
  `register-effect-handler` or `with-effect-handler-scope`.
- Corrected `context-merge`'s documented merge precedence. Stored values and
  effect handlers let `other` overlay `base`, but metadata is concatenated
  `base`-first, so `base` wins a lookup on a colliding metadata key. A new test
  locks the asymmetry in.

See the full [`CHANGELOG.md`](https://github.com/nerima-lisp/cl-dataflow/blob/main/CHANGELOG.md#100---2026-07-26)
entry for the per-call-site detail.

## [0.4.0] — 2026-07-25

A quality and correctness release building on 0.3.0. **The public API is
unchanged.** Documentation and test coverage grew, dozens of small internal
duplication/readability fixes landed, and two families of whole-graph metric
functions that had silently regressed from O(V+E) to O(V\*(V+E)) were fixed.
The suite reached 514 tests, holding the 100%-branch-coverage gate throughout.

- Published this MkDocs (Material) documentation site, built with
  `nix build .#docs` and deployed by `.github/workflows/docs.yml`.
- Added a `cl-weave:logic-query` property test that cross-checks
  `graph-descendants` against an independent Datalog-style reachability
  program, plus a `cl-weave:it-fuzz` test hardening `%normalize-name` against
  100 trials of arbitrary generated values.
- Fixed `examples/bootstrap.lisp`, which hand-maintained a drifted duplicate
  of `cl-dataflow.asd`'s source-file list instead of calling
  `(asdf:load-system "cl-dataflow")` — this had silently broken all 12
  examples.
- Fixed the `is` assertion macro discarding a supplied diagnostic message
  instead of forwarding it to `cl-weave:fail`.
- Split `graph-algorithms.lisp`/`graph-connectivity.lisp` into
  `graph-structure.lisp`, `graph-components.lisp`, and `graph-distance.lisp`
  along algorithm-family lines, mirroring the earlier `graph-paths.lisp`
  split. No public API changed.
- Consolidated more repeated scaffolds into macros: `with-fifo-queue`,
  `define-plist-equal-p` (backing `graph-equal-p`/`pipeline-equal-p`/
  `state-machine-equal-p`/`context-equal-p`), and `define-node-wrapper`
  (backing the `node-with-*` combinator family).

See the full [`CHANGELOG.md`](https://github.com/nerima-lisp/cl-dataflow/blob/main/CHANGELOG.md#040---2026-07-25)
entry for every internal change, including the performance fixes to
`graph-betweenness-centrality`, `graph-degree-histogram`, and the SCC/dominator
family.

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
