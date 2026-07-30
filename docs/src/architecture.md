# Architecture

`cl-dataflow` keeps the implementation deliberately small and organized by
concern, one file per topic:

- `src/package.lisp` defines the public package and its exported API surface.
- Shared node, context, and model primitives live in focused
  `src/core-*.lisp` files — normalization, structural copying, slot
  accessors, conditions, and the model layer split across
  `core-models-classes` / `-copying` / `-slot-accessors` / `-constructors` —
  each listed directly in the system definition.
- The `cl-prolog`-backed graph runtime lives in `src/graph-runtime-*.lisp`:
  structural validation, the Prolog rulebase and bulk edge query, topology
  (topological sort, boundaries), port bindings, and pipeline-graph builders.
- The graph analysis layer above it is split one file per algorithm family:
  `src/graph-structure.lisp` (order/size, adjacency, degree, transpose,
  acyclicity, topological generations), `src/graph-components.lisp`
  (strongly/weakly connected components and the connectivity predicates and
  condensation built on them), `src/graph-distance.lisp` (BFS/DFS order,
  eccentricity, diameter/radius/center/periphery, closeness and betweenness
  centrality), and the sibling `graph-closure`, `graph-paths`,
  `graph-shortest-path`, `graph-flow`, `graph-eulerian`, `graph-metrics`,
  `graph-algebra`, `graph-criticality`, `graph-export`, and `graph-builders`
  files.
- `src/protocols.lisp` defines the shared introspection and printing
  protocols (`flow-name`, `flow-metadata`, `flow-kind`) implemented by every
  flow object.
- Runtime behavior is split by concern into focused files, each keeping its
  DSL expander next to a schema table and its execution logic beside it:
  `src/pipeline-macros.lisp` / `src/pipeline-runtime.lisp`,
  `src/state-machine-macros.lisp` / `src/state-machine-runtime-*.lisp`,
  `src/events.lisp`, and `src/effects.lisp`. The state-machine runtime is
  itself layered: `-core` holds construction and transition selection,
  `-cps` holds `step-state-machine`'s continuation-passing execution chain,
  and `-api` is the thin direct-style public surface over it.
  `src/pipeline-parallel.lisp`, loaded right after `pipeline-runtime.lisp`,
  holds `run-pipeline`'s `:parallel` mode in isolation, so it is the one file
  that needs `cl-concurrent-kit`'s package.
- `src/testing.lisp` contains deterministic test helpers, including
  state-machine assertions.
- `cl-dataflow.asd` loads the library system and routes
  `asdf:test-system :cl-dataflow` to `cl-dataflow/test`.
- `examples/` contains eleven runnable scripts plus the shared
  `bootstrap.lisp` that loads the ASDF system for them (see
  [Examples](examples.md)).

## The graph runtime

The graph runtime models edges as a [`cl-prolog`](https://github.com/nerima-lisp/cl-prolog)
fact base. `topological-sort` and `graph-reachable-p` read the edge relation
with a single bulk `cl-prolog:query-prolog`, then run linear, stack-safe
traversals — Kahn's algorithm and a work-list search — over the materialized
adjacency snapshot. This uses Prolog as the relational store while
deliberately keeping the bounded graph algorithms in Lisp, so cyclic or
adversarially deep graphs cannot trigger the non-termination or exponential
path blow-ups that a naive recursive `reachable/2` Prolog rule would produce.
Every algorithm in [Graph Algorithms](graph-algorithms.md) and
[Graph Analysis](graph-analysis.md) — connectivity, centrality, criticality,
flow — is built as an iterative, explicit queue/stack traversal over that
same snapshot for the same reason.

## Concurrent pipeline execution

`run-pipeline`'s `:parallel` mode (see [Pipelines and Workflows](pipelines.md#running-independent-stages-concurrently-with-parallel))
runs same-level node handlers concurrently via
[`cl-concurrent-kit`](https://github.com/nerima-lisp/cl-concurrent-kit)'s
structured concurrency (`with-task-scope`/`spawn`/`await`), while every write
to the context stays on a single thread: a level's handlers are all spawned,
then awaited back in a fixed order, then folded into the context
sequentially. The one exception is `emit-event`/`perform-effect`, which a
handler may call directly on the shared context; both now take a lock
installed on the context the first time a pipeline runs with `:parallel`
(`%ensure-context-lock`), so two same-level handlers calling either
concurrently serialize correctly instead of racing on the context's internal
lists. This mirrors the graph runtime's own philosophy of using an external
library for exactly the primitive it is designed for (Prolog for relational
queries, cl-concurrent-kit for structured concurrency) rather than
reimplementing it.

## Snapshot semantics

Collection-oriented readers return independent snapshots, and their setters
replace the entire live collection:

- `graph-nodes`, `graph-edges`, `graph-source-nodes`, `graph-sink-nodes`
- `context-values`, `context-events`, `context-effects`, `context-trace`
- `event-payload`, `event-metadata`, `effect-payload`, `effect-metadata`, `effect-result`
- `transition-metadata`, `state-machine-transitions`, `pipeline-stages`
- `context-effect-handlers`

`context-effect-handlers` returns a fresh table mapping each normalized effect
type to the registered handler *function itself* (a closure cannot be copied),
so mutating the returned table registers nothing. Register through
`register-effect-handler`, which writes to the live table, or replace the whole
table with `(setf context-effect-handlers)` — the save/restore pair that
`with-effect-handler-scope` is built on.

`pipeline-graph` is the one reader that returns live state: the validated graph
owned by the pipeline, so mutating it intentionally affects the pipeline — use
`copy-pipeline` when an isolated graph clone is needed instead. Handing back an
uncopied object is safe because `(setf pipeline-graph)` copies on the way *in*
via `copy-graph` and re-validates, so the pipeline owns a graph no caller
already holds a reference to. Object identity is what is shared here, not
mutable internals: `graph-nodes` and `graph-edges` on that live graph are still
copying readers.

## Error conditions

Structured conditions expose detail readers so callers can inspect exactly
what failed:

- `node-not-found-error` exposes the missing designator, so callers can tell
  whether the failure came from a node name or an edge reference.
- `graph-cycle-error` exposes the remaining cyclic nodes, so callers can
  inspect the exact cycle component that blocked topological ordering.
- `effect-handler-missing-error` includes the missing effect type and a
  copied effect snapshot, so callers can inspect the payload that triggered
  the failure.
- `invalid-transition-error` and `guard-failed-error` expose the current
  state, event type, and (for guard failures) the transition snapshot.

## Implementation Status

| Area | Status | Notes |
| --- | --- | --- |
| Graphs and nodes | Done | Node creation, edge construction, graph validation, and topological sort are implemented. |
| Pipelines | Done | Sequential pipelines and simple branching pipelines run against graph-ordered stages. |
| Concurrent pipeline execution | Done | `run-pipeline`'s `:parallel` mode runs same-level (no dependency path between them) node handlers concurrently via `cl-concurrent-kit`, with every context write kept single-threaded. |
| Iterative pipelines | Done | Feedback execution: `run-pipeline-times`, `run-pipeline-until-fixpoint`, and `run-pipeline-while` feed a result back as the next input for recurrent/settling computations. |
| Events | Done | Event creation, emission, and trace capture are implemented. |
| Effects | Done | Effect creation, handler lookup, and test-friendly execution are implemented. |
| State machines | Done | States, transitions, guards, history, reset/copy helpers, step-based execution, context propagation, and pipeline-stage embedding are implemented. |
| Event workflows | Done | Pipeline stages can emit events, run effects, and advance a state machine in one workflow. |
| Graph algorithms | Done | Strongly/weakly connected components, topological generations, transpose, acyclicity, shortest-hop distance, degrees, and immediate neighbors, all over the bulk-query adjacency snapshot. |
| Graph export | Done | Deterministic Graphviz DOT and Mermaid rendering, plus a `graph-to-plist`/`plist-to-graph` structural round trip. |
| Graph mutation | Done | `remove-node`, `remove-edge`, induced `graph-subgraph`, disjoint `graph-merge`, and `graph-relabel-node` for editing and composing graphs. |
| Graph paths | Done | Transitive closure/reduction, topological rank, longest (critical) path, all simple paths, an ordered cycle witness, and weighted (Dijkstra) shortest distance and path. |
| Equality predicates | Done | `pipeline-equal-p`, `state-machine-equal-p`, `context-equal-p` (structural equality via plist serialization), and `state-machine-reachable-p`. |
| Graph metrics | Done | Edge density, degree histogram, bipartiteness, structural `graph-equal-p`, and weak (undirected) reachability. |
| Graph connectivity | Done | Weak/strong connectivity predicates, self-loop nodes, the SCC condensation DAG, single-source distances, eccentricity, and diameter. |
| Graph algebra | Done | Set operations `graph-union`, `graph-intersection`, `graph-difference`, plus `graph-filter-nodes` (predicate-induced subgraph) and `graph-map-nodes` (injective relabel). |
| Graph criticality | Done | `graph-articulation-points` (cut vertices), `graph-bridges` (critical connections), `graph-dominators` (immediate-dominator tree), and `graph-post-dominators` (its dual toward a sink), all recursion-free. |
| Graph centrality | Done | `graph-closeness-centrality` and Brandes' `graph-betweenness-centrality`, plus `graph-radius`, `graph-center`, `graph-periphery`, `graph-wiener-index`, and `graph-average-path-length`. |
| Graph flow | Done | `graph-max-flow`/`graph-min-cut` over edge-metadata capacities via Edmonds-Karp, and `graph-eulerian-path` via Hierholzer's algorithm. |
| Node contracts | Done | `contract-handler` and `node-with-contract` enforce input/output predicates at the node boundary, signalling `invalid-input-error` on violation. |
| State-machine analysis | Done | State/event enumeration, reachability, unreachable/terminal-state detection, structural determinism check, and DOT/Mermaid rendering. |
| State-machine execution | Done | `state-machine-run-states` (visited-state trace), `state-machine-accepts-p` (acceptance), and `state-machine-event-path` (shortest driving event sequence). |
| State-machine builders | Done | Serialization (`to-plist`/`plist-to`), `state-machine-complete-p`, `state-machine-transition-for`, `add-transition`/`remove-transition`, and `state-machine-relabel-state`. |
| Combinators | Done | Handler wrappers (retry, fallback, memoize, tap, map, compose), node wrappers, and result-threading pipeline sequencing. |
| Streams (pull) | Done | A lazy transducer layer (`map`/`filter`/`scan`/`take`/`drop`/`distinct`/`flat-map`/`concat`/`zip`/`tap`) with `collect`/`reduce`/`for-each`/`count`/`first` consumers. |
| Reactive subjects (push) | Done | Synchronous push-based subjects with `subscribe`/`emit`/`unsubscribe` and derived `subject-map`/`subject-filter`/`subject-merge` — the producer-driven dual of pull streams. |
| Reactive operators | Done | Stateful/combining subject operators `scan`, `distinct`, `tap`, `take`, `drop`, `take-while`, `drop-while`, `count`, `zip`, `combine-latest`, `buffer`. |
| Stream extras | Done | Generators (`iterate`/`repeat`/`cycle`/`enumerate`/`unfold`), windowing (`chunk`/`window`/`partition-by`), and aggregate consumers (`sum`/`min`/`max`/`find`/`some`/`every`/`last`/`nth`). |
| Stream ops | Done | `zip-with`, `interleave`, `take-nth`, `dedupe-consecutive`, `interpose`, plus collectors `group-by`, `frequencies`, `index-by`, `partition`, `split-at`, `average`. |
| Stream statistics | Done | `flatten`, `scan1`, `count-if`, and statistical aggregates `variance`, `stddev`, `median`. |
| Stream search | Done | `find-index`, `none-p`, `mode`, and the lazy Cartesian product `stream-cartesian`. |
| Context serialization | Done | `context-to-plist`/`plist-to-context` plus event/effect plist round trips (handlers excluded). |
| Observability | Done | Pipeline rendering (`pipeline->dot`/`->mermaid`) and role enumeration, plus `format-trace`, `trace-summary`, and `context-summary` over a run's recorded trace. |
| Effect ergonomics | Done | `register-effect-handler`, `context-effect-handler`, `effect-handled-p`, `context-effect-handler-types`, and `with-effect-handler-scope`. |
| Protocols | Done | `flow-name`, `flow-metadata`, and `flow-kind` provide consistent introspection across flow objects. |
| Testing helpers | Done | Dedicated helpers assert emitted events, effects, final state, state-machine state, and pipeline results. |
| Runnable examples | Done | Eleven scripts cover a simple pipeline, event workflow, state machine, basic and advanced graph analysis, the graph toolkit, state-machine visualization, resilient pipelines, streams, stream analytics, and an end-to-end integration scenario. |
| Public API | Stable | `cl-dataflow` is the single exported package. |

## Repository layout

```text
cl-dataflow/
  README.md
  CHANGELOG.md
  LICENSE
  cl-dataflow.asd
  run-tests.lisp
  src/
  t/
  examples/
  docs/
```
