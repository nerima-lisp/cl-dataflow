# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `run-pipeline`, `run-pipeline-with-context`, `run-pipeline-times`,
  `run-pipeline-until-fixpoint`, and `run-pipeline-while` accept a new
  `:parallel` keyword (default `nil`, fully backward compatible). With it,
  stages that share a topological level — no dependency path between them,
  computed once as part of the cached execution plan (`%pipeline-node-levels`,
  `pipeline-runtime.lisp`) — run their handlers concurrently via
  [cl-concurrent-kit](https://github.com/nerima-lisp/cl-concurrent-kit)'s
  structured concurrency (`pipeline-parallel.lisp`). Every write to the
  context still happens on one thread (a level's handlers are spawned,
  awaited in a fixed order, then folded in sequentially), so a `:parallel`
  run produces byte-identical results to a sequential run, except that two
  same-level handlers both calling `emit-event`/`perform-effect` serialize
  correctly against each other but without a guaranteed relative order (both
  now take the context's lock for their whole read-then-push sequence; see
  `events.lisp`/`effects.lisp`). A single-stage level always runs directly,
  with no thread-spawning cost, so a purely linear pipeline is unaffected
  either way. cl-concurrent-kit is a new runtime dependency of the main
  `cl-dataflow` system (previously only `cl-prolog`); see
  `cl-dataflow.asd`'s dependency comment.
- `map-pipeline` accepts the same `:parallel` keyword, running each
  independent (no-`:context`) run concurrently. Simpler than
  `run-pipeline`'s own `:parallel`: every run already gets its own fresh
  context, so there is no shared state to guard and no lock is needed.
  Combining `:parallel` with a shared `:context` signals
  `invalid-input-error` rather than silently racing on it.

### Changed (build)

- `flake.nix` now builds and checks through
  [cl-nix-forge](https://github.com/nerima-lisp/cl-nix-forge) (`lispDerivation`/
  `mkCommandCheck`/`mkDocsSite`/`mkDevShell`) instead of the hand-rolled
  `sourceFor`/`mkWeaveCheck` functions and three separately hand-concatenated
  `CL_SOURCE_REGISTRY` strings across `checks`/`apps`/`devShells`. Every raw,
  `flake = false` sibling (`cl-prolog`, `cl-boundary-kit`, `cl-log-kit`,
  `cl-process-kit`) and `cl-weave`'s own source output now get their own
  `lispDerivation` build rather than a bare dependency wrap, since none of
  them ship a complete set of their own compiled fasls and `lispDerivation`'s
  identity `ASDF_OUTPUT_TRANSLATIONS` needs a writable source tree to compile
  into. This surfaced one previously-invisible dependency edge the old flat,
  shared registry silently satisfied without anyone modeling it explicitly:
  `cl-boundary-kit`'s own base system also `:depends-on` `cl-log-kit`, not
  only `cl-process-kit` depending on both. `checks.default`/`checks.coverage`
  keep the exact same `cl-weave` CLI invocations (same `--reporter github`,
  same `--coverage-min-branch 100` gate); every check now also gets a real,
  `timeout --kill-after`-escalated time limit cl-nix-forge enforces natively.
  No public API or observable test/coverage behavior changed. See
  `flake.nix`'s own comments for the full reasoning.

### Changed (src)

- 19 call sites across 12 files hand-wrote the identical `(error
  'invalid-input-error :expected E :value V :detail D)` shape. 18 of them now
  call a single `%signal-invalid-input-error` helper in `core-conditions.lisp`
  (moved there from `pipeline-macros.lisp`'s narrower
  `%invalid-structured-clause-error`, which was already this same helper in
  everything but name and location). `core-normalization.lisp`'s one remaining
  site loads before `core-conditions.lisp` in `cl-dataflow.asd`'s component
  list and stays a raw `error` call rather than reordering the system for it.
  No public API or observable behavior changed.
- 22 call sites across 9 files repeated the same "resolve a node designator to
  its name, then validate it exists in the graph" preamble, each resolving the
  designator twice (`%ensure-graph-node` already resolves its own argument
  internally). Added `%ensure-graph-node-name` (`graph-runtime-validation.lisp`)
  to do both steps once and return the name every one of these callers
  actually needed. No public API or observable behavior changed.

Everything else in this section is repository-layout work: no other source
file under `src/` changed, so no public API, behavior, or contract changed
with it.

### Changed (tests)

- `t/pipeline-runtime-plan-cache-test.lisp`: 4 tests hand-built the same
  input-recording "sink" node, differing only in its declared inputs. Extracted
  `%recording-sink`, a file-local macro anaphoric on the enclosing test's
  `seen-input` binding, matching the file's existing `assert-plan-rebuilds`
  local-helper convention.

### Added

- `run-tests.lisp` at the repository root, so the suite can be started with
  `sbcl --script run-tests.lisp` without the `cl-weave` CLI on `PATH`.
- `checks.formatting` (treefmt/nixfmt) and `checks.docs` (the `mkdocs --strict`
  build) now run under `nix flake check`. The docs build previously only ran in
  `docs.yml`, i.e. after the merge to `main`, so a broken link or a page missing
  from the nav surfaced as a failed deploy rather than as a failed pull request.
- `apps.test`, so `nix run .#test` works alongside the existing `nix run .`.
- `.github/workflows/flake-update.yml`, which opens a weekly pull request
  bumping every flake input, and `.github/actions/nix-setup/`, the shared
  composite action that pins the nix-installer and Cachix SHAs in one place.
- `checks.default` and `checks.coverage` now pass `--reporter github` to
  `cl-weave`, so a test failure in CI surfaces as an inline PR annotation
  (`ci.yml`'s `nix flake check --print-build-logs` already streams the build
  log GitHub scans for `::error::` markers). Scoped to those two derivations
  only — `apps.default`/`apps.test` and the devShell keep the plain `:spec`
  reporter for local dev, so this adds no second test run.
- `scripts/run-examples.sh` and a `checks.examples` flake check, which
  actually run every `examples/*.lisp` script and verify it exits `0`. Each
  script runs as its own top-level process under a hard, `--kill-after`-
  enforced timeout — not the in-suite `t/core-runtime-example-test.lisp`
  path, which reproducibly deadlocks when enabled (`CL_DATAFLOW_RUN_EXAMPLE_SMOKE`
  stays opt-in and unused, as its docstring already warned). Until now
  nothing actually ran that opt-in path or any equivalent, so the examples
  had no automated verification at all.
- `checks.default` and `checks.coverage` now run every `it-property` test at
  5000 samples instead of `cl-weave`'s own 100-sample default. Verified this
  doesn't hide anything the lower default was missing (515/515 still passes)
  and costs nothing worth trading off (the whole suite still compiles and
  runs in well under a minute).
- `apps.watch`, so `nix run .#watch` drives `cl-weave watch cl-dataflow/test`
  — a continuous local development loop that re-runs the suite on every
  source change, alongside the existing one-shot `apps.test`.

### Changed

- `flake.nix` reads cl-weave's ASDF source from `cl-weave.packages.<system>.cl-weave`
  (the org's sanctioned way to consume it, per `cl-weave` v1.1.0's changelog —
  the same output `cl-prolog`/`cl-json-kit` already use) instead of reaching into
  `cl-weave.packages.<system>.default`'s `/share/common-lisp/source`, an internal
  layout `installSource` creates so the delivered CLI binary can find its own
  systems, not a published interface. `packages.default` is still used for the
  `cl-weave` executable itself. No observable behavior changed; verified via
  `nix build .#checks.<system>.default` and `.coverage` (515/515, 100% branch).
- Every sibling flake input is pinned to a release tag rather than following the
  upstream default branch: `cl-prolog/v1.0.1`, `cl-weave/v1.0.0`,
  `paredit-cli/v1.0.0`, `cl-process-kit/v1.0.0`, `cl-boundary-kit/v0.6.0`,
  `cl-log-kit/v1.0.0`. An unpinned reference means an upstream push to `main`
  can break this repository's CI with no change here.
- `cl-prolog` and `cl-process-kit` are pulled with `flake = false`, matching
  `cl-boundary-kit` and `cl-log-kit`. Only their source trees were ever used, and
  a `flake = true` sibling drags its whole transitive input graph in. Together
  with the tag pinning this takes `flake.lock` from 78 nodes to 10; the old lock
  held 16 copies of `cl-weave` and 13 each of `paredit-cli`, `rust-overlay` and
  `treefmt-nix`. `cl-weave` and `paredit-cli` stay `flake = true` because their
  `packages`/`lib` outputs are what `checks.default`, `checks.coverage` and
  `checks.paredit-lint` actually call.
- `flake.nix` reads the package version out of `cl-dataflow.asd` instead of
  hardcoding it in two places, so a release edits one line.
- `nix fmt` is now treefmt (Nix files only) rather than bare `nixfmt`, and shares
  its configuration with `checks.formatting`.
- The test directory is `t/` and both systems in `cl-dataflow.asd` are named with
  strings rather than `#:` designators, per the org package standard. The test
  system name, `cl-dataflow/test`, is unchanged.
- `ci.yml` is now a single `check` job running `nix flake check`, on
  `ubuntu-latest` only. Granularity moved into the flake's `checks.*`, which
  `nix flake check` already runs in parallel with a shared build cache. **The
  per-system coverage artifact upload is gone**; `checks.coverage` still enforces
  the same 84%-expression / 100%-branch gate, but the HTML report is no longer
  published from CI. Run `./scripts/coverage.sh` locally for it.
- Every `uses:` in every workflow is pinned to a 40-character commit SHA.
- `docs/src/README.md` is now `docs/src/index.md`, `testing.md` is now
  `development.md`, and the nav has the six standard sections. `changelog.md` is
  a `pymdownx.snippets` include of this file, so the site and the repository can
  no longer drift apart.
- `docs/src/graph-algorithms.md` (478 lines) and `docs/src/state-machines.md`
  (412 lines) exceeded the standard's 400-line page limit. Each is split at its
  own natural seam: `graph-algorithms.md` keeps basic queries, connected
  components, traversal order, and distance/centrality, with the rest (paths
  and order, weighted paths and flow, metrics, algebra, criticality) moved to
  the new `docs/src/graph-analysis.md`; `state-machines.md` keeps defining,
  stepping, introspecting, lifecycle, and pipeline embedding, with the rest
  (structural analysis, execution/interpretation, serialization/mutation
  builders, and the graph-toolkit bridge) moved to the new
  `docs/src/state-machine-analysis.md`. Both new pages are added to the nav
  immediately after the page they continue from.
- Every pinned sibling input bumped to its latest release tag:
  `cl-prolog` v1.0.1 → v1.1.0, `cl-weave` v1.0.0 → v1.1.0, `paredit-cli`
  v1.0.0 → v1.3.0, `cl-process-kit` v1.0.0 → v1.0.1, `cl-boundary-kit` v0.6.0
  → v1.0.0. Each upstream changelog was read before bumping: none change an
  API, CLI flag, or ASDF dependency graph that this repository actually
  touches (`cl-boundary-kit`'s 0.6.0→1.0.0 jump only bumped `:version` in its
  `.asd`; the system name and `:depends-on` list cl-dataflow needs through
  `cl-process-kit` are unchanged).

### Removed

- `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md` and `SECURITY.md`, plus their
  `docs/src/` copies. GitHub serves these from the org's `.github` repository for
  any repository that does not define its own, so a local copy is 21 files to
  update instead of one. Nothing in the removed files was specific to
  `cl-dataflow`; the verification commands they carried are now in
  [Development](https://nerima-lisp.github.io/cl-dataflow/development/).

## [1.0.0] - 2026-07-26

The first stable release. Every symbol exported from the `cl-dataflow` package
is now covered by Semantic Versioning: a breaking change to any of them requires
a major-version bump. **No public API changed in this release** -- 1.0.0 marks
the existing surface as stable rather than reshaping it. What did change is a
family of internal copying-accessor misuses, and three places where the
documentation described a contract the code does not implement. The suite is at
515 tests with the 100% branch-coverage gate held.

### Fixed

- A family of internal call sites read through the library's *copying* public accessors where the `%`-prefixed live readers belong, paying a full deep copy to compute a `length` or resolve a single key. The worst was `perform-effect` (`effects.lisp`), which called `context-effect-handlers` -- a reader that snapshots the whole handler table through `%copy-effect-handlers` -- just to do one `gethash`, putting an O(registered handlers) allocation on every performed effect. Also fixed: the `context` and `state-machine` `print-object` clauses (`core-models-classes.lisp`) deep-copied every event, effect, and transition purely to print their counts, so printing a context in the debugger cost O(recorded history); `context-summary` (`observability.lisp`) did the same thing four times over to report four sizes; `state-machine-last-transition` (`state-machine-runtime-core.lisp`) copied the entire history to read its head, where the existing `%last-raw-item` helper -- already backing `context-last-event`/`context-last-effect` for exactly this -- does it without copying the list; and `copy-context` (`core-models-copying.lisp`) / `copy-state-machine` read through copying readers to feed constructors whose setters copy again, making two copies of every collection, and three of the handler table and transition history, to produce one independent object. This was drift from a convention the codebase already had: `%flow-child-count` (`introspection.lisp`) and the `graph` `print-object` clause both count off `%graph-nodes-table`/`%pipeline-stages-list`/`%state-machine-transitions-list` correctly. Moved `%context-effect-handler-table` (from `effects-ext.lisp`) and `%state-machine-transitions-list` (from `state-machine-runtime-core.lisp`) into `core-slot-accessors.lisp` beside the other live readers, so the earlier-loading files that now need them can reach them without a forward reference. No public API or observable behavior changed, and the copy-isolation guarantees are untouched -- the setters that actually provide that isolation were doing the copying all along, which is precisely why the reader-side copies were redundant.
- `README.md` and the documentation site described `context-effect-handlers` as "intentionally mutable", returning the live handler table so callers could register a handler by mutating what it returns. It has in fact returned a snapshot since it was introduced (`%copy-effect-handlers`, `core-models-slot-accessors.lisp`), and `effects-test.lisp` has been asserting exactly that snapshot behavior the whole time -- so a caller following the documentation would have silently registered nothing. Corrected the docs to state the real contract and to point at `register-effect-handler` and `with-effect-handler-scope` as the registration surface, with `(setf context-effect-handlers)` for wholesale replacement.
- `context-merge`'s docstring (`introspection.lisp`) claimed effect-handler and metadata merging both follow its "OTHER overlays BASE" rule. Metadata is actually concatenated BASE-first, and since both plist (`getf`) and alist (`assoc`) lookups resolve to the first match, BASE wins on a colliding metadata key -- the reverse of the rule for stored values and handlers, which are hash tables where the later write really does replace the earlier one. Corrected the docstring to document the asymmetry and added `context-merge-collision-precedence-is-asymmetric` (`introspection-test.lisp`) to lock it in: the pre-existing merge test asserted that metadata *concatenates*, but never which side wins a lookup, which is the part a caller depends on.

- `%make-pipeline-execution-plan` (`pipeline-runtime.lisp`) rebuilt plan pieces on every iteration of two loops instead of once: `%pipeline-input-key-plan` linearly `find`-scanned the full edge-signature list per input binding (O(E) work per binding, O(E^2) overall), and `%pipeline-sink-result-plan` linearly rescanned the full stage-signature list per sink (O(sinks*V), worst case O(V^2)). Both now look up a hash table (`%pipeline-edge-signature-table`, `%pipeline-node-result-plan-table`) built once before their loops, matching the same "share precomputed structure across a whole-collection loop" fix already applied to the graph-metrics family in 0.4.0. This only affects pipeline construction/topology-change cost, since the execution plan is cached and reused across repeated `run-pipeline` calls.
- `flake.nix` declared `cl-tty-kit` as a flake input and wired its source onto `CL_SOURCE_REGISTRY` alongside `cl-boundary-kit`/`cl-log-kit`, but `cl-process-kit`'s base ASDF system (the only one `cl-dataflow.asd` ever loads) only depends on `:cl-boundary-kit`/`:cl-log-kit` -- `cl-tty-kit` is required solely by the optional `cl-process-kit/pty` subsystem, which nothing in this repo references. Removed the unused input (and its `flake.lock` entry) so the declared inputs match what ASDF actually resolves.
- `state-machine-complete-p` (`state-machine-builders.lisp`) called `state-machine-event-types` -- which rescans every transition and dedups/sorts the result -- once per state inside its outer loop, turning O(S + T + E log E) into O(S * (T + E log E)). Hoisted the call outside the loop so it runs once.
- `stream-distinct-by` (`stream-ops.lisp`) deduped keys with a linear `member` scan against a list that grows with every distinct key, O(n^2) in the number of distinct keys (a limitation its own docstring disclosed). Its sibling `stream-distinct` (`streams.lisp`) already solved the identical problem for raw values with a persistent hash-table fast path for standard `eq`/`eql`/`equal`/`equalp` tests, shared with `subject-distinct`; `stream-distinct-by` never got the same treatment despite the helpers (`%standard-distinct-test`, `%distinct-hashable-value-p`, `%distinct-hash-levels-member-p`, `%distinct-hash-levels-add`) already being reusable, value-shaped utilities. Rewired `stream-distinct-by` onto the same hash-levels structure, keyed by `(funcall function element)` instead of the raw element; the `member`-based path now only runs for keys a standard test can't safely hash (or a custom test predicate). No public API change.

### Changed

- Five functions each independently called `%graph-adjacency-snapshot` twice (once for `:successors`, once for `:predecessors`) to build both directions of adjacency: `graph-strongly-connected-components` and `%undirected-adjacency` (`graph-components.lisp`), `graph-degree-histogram` (`graph-metrics.lisp`), and `graph-dominators`/`graph-post-dominators` (`graph-criticality.lisp`). Each `%graph-adjacency-snapshot` call independently rebuilds the graph's Prolog rulebase from scratch (`%graph-rulebase` -> `cl-prolog:make-rulebase`, which compiles a fresh clause template per node/edge) -- so every one of these functions was paying for that compilation twice per call for no reason, since the rulebase doesn't change between the two calls. An `sb-sprof` profile of a mixed workload had already flagged `CL-PROLOG:MAKE-RULEBASE`/`%COMPILE-CLAUSE-TEMPLATE` as a real, non-trivial cost. Added `%graph-both-adjacencies` (`graph-structure.lisp`, next to `%graph-adjacency-snapshot`) returning `(VALUES successors predecessors)` from one shared rulebase, and switched all five call sites onto it. This is a purely local, single-call-scope change (the rulebase only needs to be valid for the duration of one function call) -- unlike caching a rulebase across separate top-level calls, which would need cache invalidation on every graph-mutating operation and was considered and deliberately not pursued given the correctness risk of a stale-cache bug silently returning outdated structural results. Measured with a same-process before/after comparison (all five functions over an 80-node cyclic graph, 600 iterations): ~2.10s -> ~1.50s (~29%).
- `%make-result-table` (`core-copying.lisp`) now takes an optional size hint instead of always starting hash tables at SBCL's default capacity. Wired it into the two hot spots an `sb-sprof` profile of a mixed graph/context/stream workload flagged as spending real time in `GROW-HASH-TABLE`/`%MAKE-HASH-TABLE`/`%ALLOC-HASH-TABLE`: `%betweenness-bfs`/`%betweenness-accumulate`/`graph-betweenness-centrality` (`graph-distance.lisp`), whose 3 per-source hash tables are populated with exactly `(length names)` entries every one of the V times Brandes' algorithm's outer loop calls them, and `%graph-adjacency` (`graph-runtime-prolog.lisp`), whose successor/indegree tables are always populated with exactly the graph's node count. Both final sizes are known before the table is created, so presizing avoids the rehash-and-grow churn of filling a table that starts too small. Measured with a same-process before/after wall-clock comparison (`graph-betweenness-centrality` over an 80-node cyclic graph, 600 calls): ~3.35s -> ~3.18s. The other ~40 `%make-result-table` call sites were left as-is -- most build up a table incrementally to an unknown final size (BFS visited-sets, Prolog per-node adjacency lists), where a size hint wouldn't help.
- Added a global `(optimize (speed 3) (safety 1) (compilation-speed 0))` policy (`package.lisp`) and dropped the `NOTINLINE` declaim on the hottest structural accessors and copiers (`graph-nodes`/`graph-edges`, `context-values`/`context-events`/..., `%copy-node-snapshot`/`%copy-event`/...; `core-conditions.lisp`) for every ordinary load. That `NOTINLINE` was added deliberately so `sb-cover` would see every call site during `--coverage` runs; it now applies only when `SB-COVER` is loaded (detected the same way `cl-weave --coverage` itself detects it: `(find-package "SB-COVER")`, checked before this system compiles), so the 100% branch-coverage gate is unaffected while every other load -- tests, the REPL, and applications depending on this library -- gets the compiler's fast CLOS slot-access path instead of forced generic-function dispatch. Verified with `scripts/verify.sh` (514/514), `scripts/coverage.sh` (100% branch, unchanged), and a same-process before/after `cl-weave`-style wall-clock comparison (`topological-sort` + `graph-strongly-connected-components` over a 60-node chain, 500 iterations: ~0.21s -> ~0.19s).
- Bumped `cl-weave`, `cl-process-kit`, and `paredit-cli` flake inputs to their latest upstream revisions (`cl-prolog` was already current). Verified `cl-process-kit`'s newer revision didn't change its own ASDF dependency graph (still just `cl-boundary-kit`/`cl-log-kit` for the base system) before accepting the bump, and re-ran the full test/coverage/paredit-lint checks against it.
- Collapsed the 6 hand-written `PRINT-OBJECT` methods (node, edge, graph, context, state-transition, state-machine -- `core-models-classes.lisp`) into a `DEFINE-PRINT-OBJECT` macro plus one declarative invocation, matching the codebase's existing schema-table-next-to-macro convention. All 6 shared the identical `PRINT-UNREADABLE-OBJECT` + `FORMAT` scaffold and differed only in the class, format string, and accessor calls. No output change.

## [0.4.0] - 2026-07-25

A quality and correctness release building on 0.3.0. The public API is
unchanged; documentation and test coverage grew, dozens of small internal
duplication/readability fixes landed, and two families of whole-graph metric
functions that had silently regressed from O(V+E) to O(V*(V+E)) were fixed.
The suite is at 514 tests with the 100% branch coverage gate held throughout.

### Added

- Published a MkDocs (Material) documentation site under `docs/`, built with `nix build .#docs` and deployed by `.github/workflows/docs.yml`.
- A property test (`graph-advanced-property-test.lisp`) cross-checks `graph-descendants` against `cl-weave:logic-query`, a small unification/backtracking Datalog-style engine the codebase hadn't used before. A recursive `REACHABLE/2` rule over `:edge` facts derived from the same random DAG is queried directly (the program is generated per test case, so it's built with the `logic-query` function rather than the `logic-program`/`logic-run` macros, which require literal syntax). This is a genuinely independent third implementation of graph transitive closure -- distinct from both the hand-rolled BFS reference already in this file and from `graph-descendants` itself, which materializes into a `cl-prolog` rulebase (`graph-runtime-prolog.lisp`) -- so it catches a class of bug neither existing oracle could (one specific to the traversal *shape* both share).
- A `cl-weave:it-fuzz` test (`core-model-internal-test.lisp`) throws 100 trials of arbitrary `gen-sexp`-generated values at `%normalize-name` and asserts it always returns a string. Unlike `it-property`, a fuzz trial passes just by completing without signaling an error, which fits `%normalize-name`'s own contract better than another property test would: its `typecase` catch-all is explicitly built (per its own comment on binding `*print-circle*`) to accept any Lisp value, not to satisfy one specific invariant. The existing example test already hand-picks a keyword, a number, and a circular list; the fuzz test complements those with broader, unanticipated shapes rather than re-checking the same three cases.

### Fixed

- `examples/bootstrap.lisp` hand-maintained a duplicate of `cl-dataflow.asd`'s source-file list instead of calling `(asdf:load-system "cl-dataflow")`. It had drifted out of sync with the `graph-algorithms.lisp`/`graph-connectivity.lisp` -> `graph-structure.lisp`/`graph-components.lisp`/`graph-distance.lisp` split earlier in this changelog, silently breaking every one of the 12 examples (all of them load `bootstrap.lisp` first). Replaced the hand-listed files with a plain `asdf:load-system` call, so this class of drift can't recur; verified all 12 examples run to completion again.
- `tests/test-support-assertions.lisp`'s `is` macro accepted an optional diagnostic `message` argument but `(declare (ignore message))`'d it unconditionally, silently discarding whatever was passed. A `paredit inspect calls` sweep across every one of the suite's 1411 `(is ...)` call sites found exactly one that actually supplied a message (`core-runtime-example-test.lisp`'s example-script timeout check, with a real, non-redundant diagnostic identifying which script and timeout), so this wasn't the widespread problem it first looked like -- but it was a real one at that site. `is` now forwards a supplied message to `cl-weave:fail` on failure instead of discarding it; the other 1410 call sites (which never pass one) are unaffected and keep going through `cl-weave:expect`'s own smart-assertion reporting exactly as before.

### Changed

- Fixed stray `github.com/takeokunn/cl-dataflow` URLs left over from the `nerima-lisp` org migration across `README.md`, `CHANGELOG.md`, `SECURITY.md`, `cl-dataflow.asd`, `.github/ISSUE_TEMPLATE/config.yml`, and the MkDocs documentation site.
- Consolidated three more repeated scaffolds into macros: `with-fifo-queue` (`graph-algorithms.lisp`) replaces the ad hoc tail-pointer FIFO queue duplicated across Brandes' betweenness BFS and both Edmonds-Karp searches in `graph-flow.lisp`; `define-plist-equal-p` (`equality-predicates.lisp`) generates `graph-equal-p`, `pipeline-equal-p`, `state-machine-equal-p`, and `context-equal-p` from one plist-comparison contract; `define-node-wrapper` (`combinators.lisp`) generates `node-with-retry`, `node-with-fallback`, `node-with-memoization`, `node-with-tap`, and `node-with-contract` from their shared `wrap-node`-plus-handler-wrapper shape.
- Rewrote `stream-map`, `stream-flat-map`, and `stream-tap`'s lambda lists from the obscure `#'stream` reader-shorthand spelling (which happens to read-equal the intended two-parameter list) to the explicit `(function stream)`.
- Unabbreviated leftover `(quote x)`/`(function x)` forms (from an earlier branch merge) back to `'x`/`#'x` in `core-models-classes.lisp`, `state-machine-builders.lisp`, and six test files.
- Split several `deftest` forms out of stray `progn` wrappers left over from the same merge, in `test-support-assertions.lisp`, `state-machine-guard-selection-test.lisp`, `pipeline-runtime-contract-test.lisp`, and `pipeline-runtime-structure-test.lisp`. One case had a `deftest` nested inside another `deftest`'s body rather than sitting beside it, which silently kept it out of the discovered test plan; splitting it out recovers that test (511 tests, up from 510, all passing; 100% branch coverage held).
- Bumped `cl-weave` and `cl-prolog` to their latest `nerima-lisp` revisions (2026-07-25).
- Bumped `cl-process-kit` to its latest revision, which now depends on `cl-boundary-kit`, `cl-log-kit`, and `cl-tty-kit`. Added the three as flake inputs (`flake = false`, since none of them ship a `flake.nix`) purely to extend `CL_SOURCE_REGISTRY` so ASDF can resolve `cl-process-kit`'s `:depends-on` -- cl-dataflow itself never loads or calls any of the three, so this is dependency wiring, not a new adapter.
- Extracted `%bfs-hop-distances`, the breadth-first hop-distance walk `graph-distance` and `graph-distances-from` each hand-wrote identically (differing only in whether the search stops early once one target is settled or runs to exhaustion).
- Split the two largest remaining graph-analysis files, `graph-algorithms.lisp` and `graph-connectivity.lisp` (which mixed structural primitives, component analysis, and distance/centrality metrics across both files with no consistent boundary) into three algorithm-family files: `graph-structure.lisp` (order/size/adjacency/degree/transpose/acyclicity, plus `with-fifo-queue`), `graph-components.lisp` (Kosaraju SCC, weak components, and the connectivity predicates built on them, previously split awkwardly across both source files), and `graph-distance.lisp` (BFS/DFS order, eccentricity, diameter/radius/center/periphery, closeness and Brandes' betweenness centrality, Wiener index). Mirrors the earlier `graph-paths.lisp` -> `graph-closure`/`graph-shortest-path`/`graph-flow`/`graph-eulerian` split. No public API changed.
- `%run-node` (`pipeline-runtime.lisp`)'s scalar-output fast path now calls the existing `%make-node-trace-record` constructor instead of hand-rebuilding the same trace-record shape inline.
- `graph-path` (`graph-runtime-prolog.lisp`) extracts its per-level BFS expansion into a named local `expand-one-level` function, so the body reads as seed -> early check -> loop-calling-a-named-step instead of two inline nested `dolist`s.
- Added `assert-plan-rebuilds` to `pipeline-runtime-structure-test.lisp` (mirroring `with-copy-isolation`'s capture/act/assert shape) and used it at its 8 clean call sites, replacing a locally re-derived `flet` helper and three repeated capture/mutate/assert blocks. Left the tests whose plan-rebuild check is interleaved with other assertions hand-written, since forcing them into the same macro shape would have obscured what each test actually checks.
- `graph-bipartite-p` (`graph-metrics.lisp`), the codebase's densest remaining function by structural nesting (found via an objective `paredit inspect form` complexity scan across every `src/*.lisp` definition, not a subjective read), extracts its per-level 2-colouring BFS into a named local `expand-frontier` function, matching the `graph-path`/`expand-one-level` shape from the previous entry.
- Added a `cl-weave:benchmark` test (`pipeline-run-cost-is-measurable-with-benchmark`), the one advanced cl-weave feature from this session's research that has a genuine, non-forced landing site: it measures actual pipeline-run wall-clock cost. Per `benchmark`'s own docstring the result is "observational only", so -- unlike the hard-gating `:to-run-under-ms` matcher already used in `graph-advanced-property-test.lisp` -- this asserts only that the mechanism produces real samples, not a specific millisecond threshold that would vary by machine.
- `tests/mutation-test.lisp`'s `%safe-eval-with-bindings` muffles compiler warnings during its `eval`. Binding a mutation-testing edge case like `count = 0` makes SBCL's compiler prove `(/ sum count)` divides by zero in that isolated `let`, even though the surrounding `if` guard makes it unreachable at runtime for that binding -- exactly the case the helper exists to exercise. This had been silently printing 3 "division by zero" compiler warnings into every test/coverage run's log for as long as `mutation-test.lisp` has existed; now the build log only carries warnings from actual problems.
- `%stream-distinct-by` (`stream-ops.lisp`) was the codebase's single densest function by the same objective complexity scan (maxDepth 17, ahead of `graph-bipartite-p`'s 16). Extracted its "confirmed-new key: signal a limit overflow, then continue lazily" tail into a named `%stream-distinct-by-emit`, and flattened the outer 2-clause `(cond ((eq step :end) ...) (t ...))` into `when`-then-fall-through. maxDepth drops from 17 to 11 (the more complex of the resulting two functions); behavior, including evaluation order between the limit signal and the recursive continuation, is unchanged.
- `state-machine-event-path` (`state-machine-execution.lisp`), the complexity scan's rank-4 candidate, extracts its per-level BFS expansion into a named local `expand-frontier`, the same shape already applied to `graph-path` and `graph-bipartite-p` -- the event-level analog of `GRAPH-PATH` now reads the same way its graph-level counterpart does.
- Ran a mechanical, codebase-wide audit via `paredit inspect calls` for two style patterns rather than another spot-check: every `if` form with no `else` branch (found zero across all of `src/*.lisp` -- the codebase already uses `when`/`unless` consistently, with no violations), and every `cond` whose last clause is a bare `t` catch-all with exactly one other test clause. Found one genuine hit, `subject-collect` (`reactive.lisp`), and converted it to `if`; the only other 2-clause `cond` in the codebase (`graph-bipartite-p`'s inner colour-conflict check) has two specific test clauses and no `t` catch-all, so it correctly stays a `cond`.
- Named two previously-unexplained numeric literals: `+first-printable-ascii-code+` (32) and `+ascii-delete-code+` (127), the C0/DEL boundary `%escaped-display-string` (`core-copying.lisp`) checks against, and `+default-max-pipeline-iterations+` (1000), the iteration cap `run-pipeline-until-fixpoint` and `run-pipeline-while` (`pipeline-iteration.lisp`) had each hard-coded independently. The pipeline-iteration case was genuine duplication -- both functions' `(or max-iterations 1000)` now reference the one named default, so retuning it can't miss a call site.
- Found the same stray-`progn` merge debris fixed in four test files earlier in this changelog also present in `src/`, via a fresh codebase-wide `paredit inspect outline` scan for top-level `progn` heads (the class of check the earlier fix never extended past `tests/`). Split it out of four files: `core-models-classes.lisp` (wrapping the `pipeline-stage-signature`/`pipeline-edge-signature`/`pipeline-execution-plan`/`pipeline` classes), `core-slot-accessors.lisp` (wrapping `%pipeline-stages-list`/`%pipeline-execution-plan`/`(setf %pipeline-execution-plan)`), `graph-runtime-bindings.lisp` (wrapping `%resolve-input-binding-plan`/`%incoming-edge-bindings`), and `pipeline-runtime.lisp` (two separate `progn`s, one wrapping the 16-function execution-plan machinery, the other wrapping `%ensure-pipeline-context`/`run-pipeline`/`run-pipeline-with-context`). Each splice was verified by diffing the before/after definition-name set, so nothing was silently dropped; behavior is unchanged, only the redundant wrapping form is gone.
- Split `pipeline-runtime-structure-test.lisp` (560 lines, this repo's largest file outside a single-form package definition) into itself (194 lines: pipeline construction, the graph/stage setters, and their copy-independence guarantees) and the new `pipeline-runtime-plan-cache-test.lisp` (367 lines: every test about when the cached execution plan is reused vs. rebuilt, plus the `assert-plan-rebuilds` helper macro all of them share). The two concerns were already cleanly separable -- no test in the construction half touches plan caching, and `assert-plan-rebuilds`'s 8 call sites are all in the rebuild half -- mirroring the `graph-paths.lisp`/`graph-algorithms.lisp` splits earlier in this changelog. Used `paredit refactor split-file --write`, the same safe move used for those splits, and verified with a before/after test-name-set diff (22 tests before, 22 after across the two files) plus the full suite.
- `%graph-adjacency` and `%graph-directional-adjacency` (`graph-runtime-prolog.lisp`) independently hand-wrote the identical "bulk-query the edge relation once, dedupe parallel `(from . to)` pairs, then do something per pair" scaffold -- one builds a successor+indegree table, the other a single-direction adjacency table. Extracted the shared shape into a new macro, `with-deduped-graph-edges`, matching the file's existing `with-fifo-queue`-style precedent (a macro over a HOF, since the codebase already favors that shape for scaffolding). Each of the two callers now reads as only the part that's actually different between them; the single-bulk-query performance property both functions' docstrings advertise is unchanged, since the macro still issues exactly one `cl-prolog:query-prolog` call per invocation.
- `state-machine-run-states` and `state-machine-accepts-p` (`state-machine-execution.lisp`) independently hand-wrote the same "step one event via `step-state-machine`, catching `invalid-transition-error`/`guard-failed-error` and bailing out" clause -- only what each does on success (accumulate visited states vs. nothing) and what a failure should return (the partial history vs. `nil`) actually differed. Extracted just that catch-and-bail step into `with-state-machine-step`, following `with-fifo-queue`'s established restraint of factoring out only the truly-shared bookkeeping and leaving the driving loop and success/failure return values to each caller.
- `graph-weighted-distance`, `graph-weighted-distances-from`, and `graph-weighted-path` (`graph-shortest-path.lisp`) each copy-pasted the same Dijkstra seed-then-settle-to-exhaustion driver loop, and carried two near-identical relaxation helpers (`%dijkstra-relax` and `%dijkstra-relax-with-previous`) differing only in whether a predecessor table was also updated. Unified the two relax variants into one (always tracking the predecessor -- one extra `setf` per relaxation is cheaper than a second driver loop) and extracted the shared driver into `%dijkstra-run`, returning `(values distance previous)`; each of the three callers now just extracts what it needs from those two tables afterward. Found by an Explore agent's codebase-wide sweep for the same similar-shaped-function duplication class as the two entries above, and correctly implemented as a plain function rather than a macro -- unlike `with-fifo-queue`/`with-deduped-graph-edges`/`with-state-machine-step`, no caller varies the loop's own control flow, so there's nothing for a macro's body forms to parametrize.
- Five `deftest`s across `combinators-test.lisp` and `contracts-test.lisp` (`node-with-fallback-recovers-in-a-pipeline`, `node-with-memoization-avoids-recomputation`, `node-with-retry-recovers-in-a-pipeline`, `node-with-tap-observes-pipeline-output`, `node-with-contract-enforces-in-a-pipeline`) each hand-built the same "wrap a node, put it in a fresh single-node graph, build a pipeline from that graph" scaffold to verify a `node-with-*` wrapper behaves correctly when actually driven by `run-pipeline`, not just called directly. Added `single-node-pipeline` to `test-support-fixtures.lisp` and switched all five over, so each test now reads as only its own wrapper, handler, and expected input/output.
- `%stream-distinct-step` (`streams.lisp`) was flagged rank-1 by a fresh run of the objective `paredit inspect form` complexity scan (last run several rounds ago, before this session's own edits reshuffled the rankings). Extracted its "confirmed-new value: signal a limit overflow, then continue lazily" tail into a named `%stream-distinct-emit`, the same pattern already applied to `stream-ops.lisp`'s `%stream-distinct-by`/`%stream-distinct-by-emit`. maxDepth drops from 14 to 11; behavior, including the overflow-signal-before-continuation evaluation order, is unchanged. The scan's next few candidates (`state-machine-event-path`, `graph-bipartite-p`, `graph-path`) turned out to already be fixed in earlier rounds -- the metric counts a `labels`-bound local function's AST depth even after extraction, so it doesn't fall once a function has already had this treatment; re-reading each candidate rather than trusting the ranking alone avoided redoing settled work.
- Five of `state-machine-guard-selection-test.lisp`'s tests each hand-built one of only two distinct guarded-transition-pair shapes ("first transition's guard rejects, second is unguarded" or "both reject"). Added `%guarded-pair-machine`, factoring out just the construction (which was the genuinely repeated part); each test's own action (`step-state-machine` vs. `state-machine-can-step-p`) and assertion, which differ meaningfully between tests, are untouched -- deliberately narrower than a full table-driven macro, since forcing those differing actions into one shape would have obscured what each test actually checks.
- `emit-events` and `perform-effects` (`events-ext.lisp`) were identical batch-driving loops differing only in calling `emit-event` vs. `perform-effect` -- both share the exact `(context type &key payload metadata)` signature, confirmed before extracting. Factored the loop into `%emit-specs`, taking the single-item function as a plain function-designator argument rather than a macro: unlike the constructions extracted elsewhere in this changelog, nothing about the control flow itself varies between the two callers, only which function to call, so a higher-order function is the minimal correct tool -- no `gensym`s or backquote machinery earn their keep here.
- `retrying-handler` and `fallback-handler` (`combinators.lisp`) each re-implemented the same "re-signal the caught condition unless it matches CONDITION-TYPE" check before their own, genuinely different, recovery action (loop-and-retry vs. return-a-fallback-once). Extracted just that filter into `%reject-unless-condition-type`; the retry loop and the fallback-value logic, correctly left un-merged in an earlier round's review of this pair, are untouched.
- `%stream-chunk` (`stream-extras.lisp`) hand-duplicated the exact "collect up to N leading elements, tracking the rest-stream and count" loop that `%stream-window-fill` already implemented for `stream-window`. Renamed the shared primitive `%stream-collect-batch` (since it's no longer window-specific) and had `%stream-chunk` call it instead of re-looping; `stream-window` switched to the same name. `STREAM-CHUNK`'s documented "the final list may be shorter" behavior is directly exercised by an existing test (`(stream-chunk 2 '(1 2 3 4 5))` -> `((1 2) (3 4) (5))`), which still passes unchanged.
- Removed a vestigial `progn` inside `perform-effect` (`effects.lisp`) wrapping two statements directly in a `let`'s body, which already sequences its forms without one. A codebase-wide grep for the same shape confirmed the other 7 remaining `progn`s in `src/*.lisp` are all legitimate -- each groups multiple forms into the single-form position `if`/`unwind-protect` requires -- so this was an isolated leftover, not a pattern needing a broader pass.
- `graph-max-flow` and `graph-min-cut` (`graph-flow.lisp`) each independently resolved and validated their SOURCE/SINK arguments and defaulted CAPACITY-KEY/DEFAULT-CAPACITY with an identical 5-line preamble before diverging into Edmonds-Karp's max-flow value versus the residual-graph cut extraction. Extracted the shared preamble into `%resolve-flow-endpoints`; each caller's own trivial-case return value (`0` vs `'()`) and post-search logic are untouched.
- `graph-topological-rank` (`graph-closure.lisp`) hand-wrote its own longest-path dynamic program, computing exactly the same per-node distance table `%longest-path-dp` (used by `graph-longest-path`) already produces -- RANK and longest-path distance are the same quantity by definition. Reordered `%longest-path-dp` before `graph-topological-rank` in the file and had the latter call it directly, discarding the path-reconstruction table it doesn't need. One dynamic-program implementation instead of two that could silently drift apart under a future edit.
- `subject-zip` (`reactive-ops.lisp`) hand-rolled two independent tail-pointer FIFO queues (one per source subject) with the exact enqueue logic `with-fifo-queue` (`graph-structure.lisp`, already used by every BFS in the graph layer) already implements. Switched to nesting `with-fifo-queue` once per source; the hand-written manual tail-pointer reset on dequeue was already redundant even in the original code (the macro's own enqueue closure decides whether to reset by checking the queue itself, not a possibly-stale tail pointer), so nothing needed to be preserved beyond it. `subject-combine-latest`, which tracks only a single latest value per source rather than a queue, correctly does not use this pattern.

### Performance

- `graph-average-clustering`, the diameter/radius/center/periphery family, and the Wiener-index/average-path-length family (`graph-metrics.lisp`, `graph-distance.lisp`) each looped a per-node public function that rebuilt the whole graph's adjacency (or Prolog rulebase and bulk query) from scratch per node, turning an O(V+E) traversal into O(V*(V+E)). Extracted the shared per-node computation (`%clustering-coefficient-for-sets`, `%hop-distances-alist-from-successors`, `%eccentricity-from-successors`) so each whole-graph caller builds adjacency once and reuses it across every node; `graph->mermaid` and `write-state-machine-mermaid`'s `id-for` lookup switched from an O(V) `assoc` scan over a growing alist to an O(1) hash table for the same reason. Measured on an 800-node/~3200-edge graph: `graph-average-clustering` ~850x faster (9.35s -> 0.011s), the diameter family ~44x (4.64s -> 0.105s), the Wiener-index family ~23x (4.63s -> 0.20s); behavior, including deterministic ordering, is unchanged (514/514 tests pass).

## [0.3.0] - 2026-07-24

A structural and performance release. The public API is unchanged; the internals
were reorganized for readability and the hot paths were optimized, with the
suite grown to 510 tests and the 100% branch coverage gate held throughout.

### Changed

- Flattened the source layout: removed the `%load-fragment` macro and the six aggregator files (`core`, `core-models`, `core-models-accessors`, `core-runtime`, `graph-runtime`, `pipeline`, `state-machine`) that loaded their fragments a second time outside ASDF, listing every real source file directly in the system definition. This removes the double-load that previously confused the fasl cache.
- Split the oversized `graph-paths` module into `graph-closure`, `graph-shortest-path`, `graph-flow`, and `graph-eulerian`, leaving `graph-paths` focused on path enumeration.
- Consolidated the twelve single-source reactive operators into a `define-subject-operator` macro so each carries only its own transformation logic, routed the stream consumers through a shared `do-stream` macro, and drove the pipeline/state-machine DSL expanders and the graph eccentricity family from schema tables instead of hand-rolled duplicates.
- Made structural deep-copy stack-safe with an explicit CPS trampoline, so copying a very long or deeply nested value runs in bounded control-stack depth, and skipped the memo table entirely for atomic values.
- Added file-purpose header comments across the source modules, switched `%normalize-name` from `etypecase` to `typecase` to drop a phantom coverage branch, and removed a provably-unreachable guard in the Prolog adjacency builder.
- Adopted the `nerima-lisp` org for the `cl-prolog`, `cl-weave`, and `paredit-cli` flake inputs, added `cl-process-kit` (replacing a hand-rolled fork/exec/kill timeout in the example test), and bounded the release CI job with a timeout.

### Performance

- Index state-machine transitions by from-state and event type (built once in `initialize-instance`, kept in lock-step with the transitions slot), replacing the linear per-step scan.
- Cache a pipeline execution plan (stage signatures, incoming-edge index, and per-node input/output value-key plans) and reuse it while the topology is unchanged, dropping per-run graph analysis and per-stage continuations.
- Append reactive subscribers through a tail pointer and emit against a snapshot, eliminating per-emission allocation; drop the redundant fourth copy of each transition record when recording history.
- Give `stream-distinct` and `subject-distinct` a hash fast-path for standard test designators, falling back to `member` semantics for custom predicates and structural values.

## [0.2.0] - 2026-07-20

### Added

- Graph analysis API (`graph-algorithms.lisp`): `graph-node-names`, `graph-order`, `graph-size`, `graph-empty-p`, `graph-successors`, `graph-predecessors`, `graph-out-degree`, `graph-in-degree`, `graph-transpose`, `graph-acyclic-p`, `graph-strongly-connected-components` (iterative Kosaraju), `graph-connected-components` (weakly connected), `graph-topological-generations` (parallelizable layers), and `graph-distance` (shortest hop count). Each builds the adjacency snapshot once and walks it with an explicit work list, so all stay linear and terminate on deep and cyclic graphs, matching the existing reachability API's guarantees.
- Graph export API (`graph-export.lisp`): deterministic `graph->dot` (Graphviz) and `graph->mermaid` renderers, plus a `graph-to-plist`/`plist-to-graph` structural round trip for persisting, diffing, and transmitting graph shape (node handlers, being runtime closures, are intentionally not serialized).
- State-machine analysis API (`state-machine-analysis.lisp`): `state-machine-states`, `state-machine-event-types`, `state-machine-reachable-states`, `state-machine-unreachable-states`, `state-machine-terminal-states`, `state-machine-deterministic-p` (structural determinism, guard-independent), and deterministic `state-machine->dot`/`state-machine->mermaid` rendering.
- Combinator API (`combinators.lisp`): handler adapters/wrappers (`mapping-handler`, `compose-handlers`, `retrying-handler`, `fallback-handler`, `memoizing-handler`, `tapping-handler`), node wrappers (`wrap-node`, `node-with-retry`, `node-with-fallback`, `node-with-memoization`, `node-with-tap`) that re-wrap an existing node's handler, and `run-pipeline-sequence` for threading one pipeline's result into the next through a shared, observable context.
- Stream/transducer API (`streams.lisp`): a lazy pull-based `flow-stream` with operators `stream-map`, `stream-filter`, `stream-scan`, `stream-take`, `stream-drop`, `stream-take-while`, `stream-drop-while`, `stream-distinct`, `stream-flat-map`, `stream-concat`, `stream-zip`, `stream-tap`; constructors `stream-of`, `list->stream`, `empty-stream`, `stream-range`; and consumers `stream-collect`, `stream-reduce`, `stream-for-each`, `stream-count`, `stream-first`, `stream-empty-p`. Operators are pure (streams re-consume identically) and their per-pull skip loops are iterative, so filtering long runs never grows the control stack.
- Graph mutation/composition API (`graph-builders.lisp`): `remove-node` and `remove-edge` (in-place), plus `graph-subgraph` (induced subgraph), `graph-merge` (disjoint union, signalling on name collisions), and `graph-relabel-node` (rename a node and rewrite its incident edges) as pure derivations that leave their inputs unchanged. Fills the gap left by the previously append-only graph API.
- Stream generator/window/aggregate API (`stream-extras.lisp`): lazy generators `stream-iterate`, `stream-repeat`, `stream-cycle`, `stream-enumerate`, `stream-unfold`; windowing/grouping `stream-chunk`, `stream-window`, `stream-partition-by`; and eager consumers `stream-sum`, `stream-min`, `stream-max`, `stream-find`, `stream-some`, `stream-every`, `stream-last`, `stream-nth`. Infinite generators stay safe under bounded consumers, and every consumer iterates rather than recurses.
- State-machine execution API (`state-machine-execution.lisp`): `state-machine-run-states` (the states visited while interpreting an event sequence, stopping at the first unavailable transition), `state-machine-accepts-p` (whether a sequence steps successfully into an accepting state), and `state-machine-event-path` (a shortest event sequence driving one state to another via BFS over the transition graph -- the event-level analog of `graph-path`). Interpretation reuses `step-state-machine`, so guard/transition semantics stay identical to the core runtime, and the machine passed in is never mutated.
- Observability API (`observability.lisp`): `pipeline->dot`/`pipeline->mermaid` (render a pipeline's graph), `pipeline-node-names`/`pipeline-stage-names`/`pipeline-source-names`/`pipeline-sink-names` (enumerate structural roles), and `format-trace`/`trace-summary`/`context-summary` which turn a run's recorded trace into readable text and roll-up counts across all four trace-entry kinds (node, event, effect, transition).
- Effect ergonomics API (`effects-ext.lisp`): `register-effect-handler` (register a single handler on a context without rebuilding its handler table), `context-effect-handler` (look one up), `effect-handled-p` (test for one), `context-effect-handler-types` (list the registered types), and the `with-effect-handler-scope` macro for registering handlers over a dynamic extent and restoring the prior table on exit. All keyed through the same normalization `perform-effect` uses, so `:Log`, `'LOG`, and `"log"` resolve identically.
- Graph path/order API (`graph-paths.lisp`): `graph-transitive-closure`, `graph-transitive-reduction`, `graph-topological-rank`, `graph-longest-path` (critical path), `graph-all-paths` (exponential simple-path enumeration), `graph-find-cycle` (an ordered cycle witness via SCC + subgraph + `graph-path`, safe on deep graphs), `graph-eulerian-path` (a trail using every edge exactly once via Hierholzer's algorithm over the directed multigraph, or NIL when the degree balance or edge connectivity rules one out), and `graph-weighted-distance` (Dijkstra over edge-metadata weights).
- Graph metrics API (`graph-metrics.lisp`): `graph-density`, `graph-degree-histogram`, `graph-clustering-coefficient` (local: how close a node's neighbourhood is to a clique) and `graph-average-clustering` (its global mean), `graph-reciprocity` (the fraction of directed edges that are mutual), `graph-bipartite-p`, `graph-equal-p` (order-independent structural equality via `graph-to-plist`), and `graph-undirected-reachable-p`.
- Stream operator/collector API (`stream-ops.lisp`): lazy `stream-zip-with`, `stream-interleave`, `stream-take-nth`, `stream-dedupe-consecutive`, `stream-interpose`; and terminal `stream-group-by`, `stream-frequencies`, `stream-index-by` (first-seen key order), `stream-partition`, `stream-split-at`, `stream-average`.
- Pipeline extension API (`pipeline-ext.lisp`): `pipeline-to-plist`/`plist-to-pipeline` (structural round trip through the graph plist), `pipeline-validate`, `pipeline-stage-count`, `map-pipeline` (run a pipeline across a collection, independently or through one shared context), and `pipeline->node` (embed a whole pipeline as a single node of a larger graph).
- State-machine builder API (`state-machine-builders.lisp`): `state-machine-to-plist`/`plist-to-state-machine` (guards/actions are runtime closures and are not serialised), `state-machine-complete-p` (transition relation total over states x events), `state-machine-transition-for`, in-place `add-transition`/`remove-transition`, and `state-machine-relabel-state` (a pure rename derivation).
- Batch event/effect API (`events-ext.lisp`): `emit-events` and `perform-effects` (emit/perform a declarative batch of type-or-(type &key payload metadata) specs), `context-effect-results` and `context-effect-results-of-type` (collected handler results), and the `event-of-type-p`/`effect-of-type-p` predicates.
- Context and introspection API (`introspection.lisp`): `context-merge` (combine two contexts' values, events, effects, traces, metadata, and handlers), `context-trace-of-kind` (filter a trace by :node/:event/:effect/:transition), and the `flow-describe`/`flow-children` protocol extension giving every flow object a uniform structural view.
- Graph connectivity API (`graph-connectivity.lisp`): `graph-connected-p` (weak) and `graph-strongly-connected-p`, `graph-self-loop-nodes`, `graph-condensation` (the strongly-connected-component DAG, with member lists in node metadata), `graph-distances-from` (single-source BFS hop distances), `graph-eccentricity`, `graph-diameter`, and the eccentricity-derived `graph-radius`, `graph-center`, and `graph-periphery` (min eccentricity, and the min-/max-eccentricity node sets), completing the eccentricity metric family under the library's directed reaches-nothing-is-0 convention. Adds the pairwise-distance summaries `graph-wiener-index` (sum of all reachable ordered-pair shortest-path distances) and `graph-average-path-length` (that sum over the number of such pairs, never dividing by zero).
- Stream statistics API (`stream-stats.lisp`): `stream-flatten`, `stream-scan1` (scan seeded from the first element), `stream-count-if`, and the population aggregates `stream-variance`, `stream-stddev`, and `stream-median` (each NIL on an empty stream).
- Graph algebra API (`graph-algebra.lisp`): `graph-union`, `graph-intersection`, and `graph-difference` (set operations by node name and edge identity), plus `graph-filter-nodes` (predicate-induced subgraph) and `graph-map-nodes` (injective node relabelling that rewrites incident edges). All produce fresh graphs.
- Node contract API (`contracts.lisp`): `contract-handler` and `node-with-contract` wrap a handler with input (`before`) and output (`after`) predicates, signalling `invalid-input-error` with the offending value on violation -- turning a bad value into an explicit failure at the node boundary.
- Context serialization API (`context-serialization.lisp`): `context-to-plist`/`plist-to-context` (round-trip a run's stored node values, events, effects, trace, metadata, state, and result -- effect handlers are runtime closures and are excluded), plus `event-to-plist`/`plist-to-event` and `effect-to-plist`/`plist-to-effect`. Completes the plist serialization story alongside graphs, pipelines, and state machines.
- Stream search API (`stream-search.lisp`): `stream-find-index` (0-based first match), `stream-none-p`, `stream-mode` (most frequent element, first-seen wins ties), and the lazy `stream-cartesian` product of two streams.
- `graph-weighted-path` (`graph-paths.lisp`): the node sequence of a minimum-weight path (Dijkstra with predecessor tracking), complementing `graph-weighted-distance`'s cost-only result.
- `graph-weighted-distances-from` (`graph-paths.lisp`): single-source weighted shortest-path costs to every reachable node (Dijkstra to all targets), the weighted, all-destinations companion to `graph-distances-from` and the all-targets form of `graph-weighted-distance`.
- `graph-max-flow` (`graph-paths.lisp`): the maximum source-to-sink flow over edge-metadata capacities, by Edmonds-Karp (breadth-first-augmenting Ford-Fulkerson); parallel edges' capacities add, a capacity-less edge takes a configurable default, and the search terminates in polynomial time on cyclic graphs.
- `graph-min-cut` (`graph-paths.lisp`): the minimum source-to-sink cut as the directed `(from to)` edges whose total capacity equals `graph-max-flow`, derived by the max-flow min-cut theorem from the residual graph the same Edmonds-Karp search leaves behind (reusing `graph-max-flow`'s network machinery).
- Equality/reachability predicate API (`equality-predicates.lisp`): `pipeline-equal-p`, `state-machine-equal-p`, and `context-equal-p` compare structure via the deterministic plist serialisations (runtime closures ignored, mirroring `graph-equal-p`), and `state-machine-reachable-p` answers whether one state can reach another.
- Graph criticality API (`graph-criticality.lisp`): `graph-articulation-points` (cut vertices -- stages whose removal disconnects the graph) and `graph-bridges` (critical connections -- links whose removal disconnects their endpoints). Both work over the undirected view and are computed recursion-free by removing each candidate and recounting weakly connected components, so they never grow the control stack and handle multigraphs correctly. Useful for finding single points of failure in a dataflow graph.
- `graph-dominators` (`graph-criticality.lisp`): the immediate-dominator tree rooted at a source, as an alist `(node . idom)` naming, for each reachable node, the closest mandatory waypoint every path from the source must cross -- the directed counterpart of articulation points and the classical substrate of dataflow analysis. Computed by the iterative Cooper-Harvey-Kennedy algorithm over reverse postorder with an explicit-stack DFS, so it stays polynomial and stack-safe on deep, cyclic graphs.
- `graph-post-dominators` (`graph-criticality.lisp`): the dual of `graph-dominators` toward a sink -- for each node that can reach the sink, the closest mandatory waypoint every path from that node to the sink must cross. It is exactly dominance on the reversed graph, sharing the same iterative Cooper-Harvey-Kennedy core; together the two bracket every node by what must run before it and what must run after it.
- Iterative (feedback) pipeline API (`pipeline-iteration.lisp`): `run-pipeline-times` (feed a result back as input N times), `run-pipeline-until-fixpoint` (iterate to a stable result under a comparison, with an iteration cap, returning result/iterations/fixpoint-p), and `run-pipeline-while` (iterate while a predicate holds). All share one context so events, effects, and trace accumulate across the whole run -- adding the recurrent/settling computation model on top of single-pass DAG execution.
- Reactive subject API (`reactive.lisp`): synchronous, push-based subjects -- the producer-driven dual of the pull-based `flow-stream`. `make-subject`, `subject-subscribe`/`subject-unsubscribe`, `subject-emit` (notifies every subscriber immediately, in subscription order, from a snapshot), `subject-subscriber-count`, the derived `subject-map`/`subject-filter`/`subject-merge`, and `subject-collect` (accumulate emissions for inspection). Fully deterministic and thread-free, for event-driven workflows.
- Reactive operator API (`reactive-ops.lisp`): stateful and combining subject operators bringing the push side to parity with pull streams -- `subject-scan` (running accumulation), `subject-distinct`, `subject-tap`, `subject-take`/`subject-drop`, `subject-take-while`/`subject-drop-while` (the push duals of the stream limit operators, the take variants latching permanently on the first failure), `subject-count` (running total), `subject-zip` (lockstep pairing with queues), `subject-combine-latest` (emit on either source with the latest of both), and `subject-buffer` (fixed-size batches).
- `graph-diff` (`graph-algebra.lisp`): a structured version diff of two graphs -- `(:added-nodes ... :removed-nodes ... :added-edges ... :removed-edges ...)` comparing GRAPH-B against GRAPH-A by node name and edge identity -- the report-style complement to the `graph-difference` set operation.
- `graph-layout` (`graph-export.lisp`): assigns each node a (LAYER . INDEX) coordinate from its topological generation (sources at layer 0, name-ordered within a layer), giving DAG layout coordinates for custom renderers. Signals on cyclic graphs.
- `graph-betweenness-centrality` (`graph-connectivity.lisp`): the canonical betweenness centrality (how many shortest paths pass through each node) via Brandes' algorithm -- iterative BFS plus reverse dependency accumulation, so deep graphs are safe. Identifies the "broker"/bottleneck nodes a dataflow graph routes through.
- `graph-closeness-centrality` (`graph-connectivity.lisp`): a node's closeness centrality -- the count of nodes it reaches divided by the total hop distance to them (0 when it reaches nothing) -- a classic centrality measure built on `graph-distances-from`, distinct from degree and eccentricity.
- `graph-greedy-coloring` (`graph-metrics.lisp`): a valid vertex colouring (adjacent nodes get different integer colours) via deterministic greedy first-fit -- generalising `graph-bipartite-p` (2-colourability) and useful for partitioning nodes into mutually-non-adjacent groups. Not guaranteed minimal (colouring is NP-hard).
- `graph-bfs-order`/`graph-dfs-order` (`graph-connectivity.lisp`): the breadth-first and depth-first (preorder) traversal orders from a source node, each starting with the source and visiting each reachable node once. Both are iterative (explicit queue/stack), so deep graphs stay stack-safe -- the explicit visitation order the distance/topological functions don't provide.
- `graph-contract-edge` (`graph-builders.lisp`): merge two adjacent nodes into one (edge contraction) -- redirects every edge incident to the absorbed node onto the surviving node (redirected endpoints attach to its first ports), drops the self-loops the merge creates, and collapses resulting duplicate edges. A pure derivation for graph simplification.
- `state-machine->graph` (`state-machine-builders.lisp`): convert a state machine to a graph (states -> nodes, transitions -> edges with the event type in edge metadata), bridging state machines to the entire graph-analysis toolkit -- cycles, strongly connected components, distances, condensation, criticality, and so on. Parallel transitions between a state pair collapse to one edge.
- Key-projected and higher-order operators: `stream-distinct-by` (`stream-ops.lisp`, dedup by a key function), plus `subject-flat-map` (the higher-order flatten operator, forwarding each spawned inner subject's emissions) and `subject-partition` (split a subject into matching/non-matching subjects) in `reactive-ops.lisp`.
- New runnable examples: `examples/graph-toolkit.lisp`, `examples/state-machine-visualization.lisp`, `examples/resilient-pipeline.lisp`, `examples/streams.lisp`, and `examples/integration.lisp` (an end-to-end scenario composing pipelines, graph analysis, pull streams, reactive subjects, a state machine, and context serialization), each registered in the example smoke-test suite.
- New tests covering all twenty-nine modules (graph algorithms, export/serialization, mutation/composition, path & order algorithms, whole-graph metrics, state-machine analysis & execution, combinators, the stream core, stream generators/windowing/aggregates, stream operators/collectors, pipeline/trace observability, and effect ergonomics), bringing the suite from 189 to 418 with the coverage gate held at 100% branch / >=84% expression.

## [0.1.0] - 2026-07-20

First public release. `cl-dataflow` provides composable computation graphs,
sequential and branching pipelines, event-driven workflows, guarded state
machines, effect boundaries, and deterministic testing helpers behind a single
public package.

### Added

- Public graph, node, edge, context, event, effect, state-machine, and pipeline primitives behind the single `cl-dataflow` package.
- `graph-descendants` and `graph-ancestors` public readers that return every node reachable from (respectively, able to reach) a given node, as name-ordered node snapshots. They reuse the bulk-query adjacency traversal, so they are linear and terminate on cyclic graphs, and are cross-checked against a reference transitive closure in the property suite.
- `graph-path`, which returns the node names of a shortest witnessing path between two nodes (or `NIL` when unreachable) via breadth-first search over the same adjacency, completing the reachability API family and property-checked for validity and agreement with `graph-reachable-p`.
- Explicit `copy-context`, `copy-event`, `copy-effect`, and `copy-pipeline` helpers alongside the existing snapshot-safe APIs.
- Structured error conditions with detail readers for graph lookups, cycles, effect-handler misses, invalid transitions, and guard failures (`node-not-found-designator`, `graph-cycle-nodes`, and the effect/state-machine detail readers).
- Advanced cl-weave coverage: custom matchers (`:to-be-acyclic`, `:to-reach`), differential property tests that cross-check `graph-reachable-p` against a reference transitive closure over random DAGs, model-based/stateful tests that replay `gen-state-machine` traces through `run-state-machine` and compare against a reference transition model, determinism checks, guarded-selection tests, and `:to-run-under-ms` performance/anti-DoS guards for deep chains, exponential-path lattices (WIDTH^(LAYERS-1) distinct paths), and large directed cycles -- locking in that reachability stays linear and terminating on the shapes a naive recursive Prolog rule would blow up on.
- A single `./scripts/verify.sh` entrypoint for tests and example smoke checks.
- Runnable bootstrap-based examples for pipeline, event workflow, state machine, and graph-analysis flows.

### Changed

- Made the flake reference the architecture-independent `cl-prolog` source tree directly, so the dev shell, checks, and `nix run` work on every system now that upstream ships Linux-only per-system packages.
- Rebuilt `topological-sort` to read the full edge relation with a single bulk `cl-prolog:query-prolog` call and drain a merge-ordered ready queue, cutting it from O(V*E) Prolog work plus a per-iteration re-sort down to linear adjacency construction with the same deterministic order.
- Rebuilt `graph-reachable-p` to materialize the successor relation once and walk it with an explicit work list, so deep graphs no longer overflow the control stack and reachability issues one Prolog query instead of two per visited node.
- Derived source/sink boundary nodes (`graph-source-nodes`, `graph-sink-nodes`) and pipeline sink-result collection from a single adjacency snapshot instead of a per-node Prolog query that rebuilt the whole rulebase each time, cutting pipeline result collection from O(V^2 + V*E) to linear.
- Stopped the `graph-nodes` and `graph-edges` readers from running a full topological sort on every call: they now perform only cheap O(V+E) structural validation, so reads are no longer superlinear and a legally constructed cyclic graph stays inspectable and copyable.
- Cut `run-pipeline` from O(V*E) to O(V+E) per run by building the incoming-edge index once per pipeline execution instead of rescanning the full edge list for every stage.
- Cut `context-last-event`/`context-last-effect` from O(n) to O(1) by reading the most recent entry directly off the raw newest-first storage list.
- Cut event/effect `trace-index` allocation from O(n) to O(1) per call by tracking a running trace-count slot instead of re-deriving it from `(length trace)` on every `emit-event`/`perform-effect`/state-machine transition; all trace-list mutation now goes through a single `%push-context-trace-entry` append point so the counter cannot drift from the list.
- Made `add-node` reject duplicate node names and `add-edge` reject duplicate edge definitions instead of silently replacing or double-counting them.
- Made `context-result`, `event-payload`, `event-metadata`, `effect-payload`, `effect-metadata`, `effect-result`, and `transition-metadata` return independent snapshots on read.
- Made topological ordering deterministic for independent nodes so graph-backed execution and sink collection stay stable.
- Made `%normalize-name` bind the printer control variables so non-symbol node/port designators normalize deterministically regardless of the caller's `*print-base*` and related bindings.

### Fixed

- Fixed pipeline input binding for nodes with more than one incoming edge on the same port: resolution now deterministically prefers the most recently added edge instead of an insertion-order accident that silently favoured the oldest one.
- Fixed `graph-source-nodes` and `graph-sink-nodes` to stay inspectable on a legally constructed cyclic graph instead of raising `graph-cycle-error`, matching the inspectability `graph-nodes`/`graph-edges` already guarantee.
- Fixed guarded state-machine transition selection: when several transitions share a `(state, event)` pair, a rejecting guard now falls through to the next candidate, and `guard-failed-error` is signalled only when every matching guard rejects. `state-machine-can-step-p` uses the same guard-aware selection.
- Fixed `define-pipeline` and `define-workflow` to evaluate a `:metadata`/`:pipeline-metadata` form once instead of twice, and to gensym their internal `graph`, `edge`, and `machine` bindings so user handler/guard/action forms can no longer capture them.

[Unreleased]: https://github.com/nerima-lisp/cl-dataflow/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/nerima-lisp/cl-dataflow/compare/v0.4.0...v1.0.0
[0.4.0]: https://github.com/nerima-lisp/cl-dataflow/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nerima-lisp/cl-dataflow/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nerima-lisp/cl-dataflow/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nerima-lisp/cl-dataflow/releases/tag/v0.1.0
