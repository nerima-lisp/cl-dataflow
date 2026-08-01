# Public API Reference

`cl-dataflow` exports a single package, `cl-dataflow`. This page groups every
exported symbol by area; the [Guide](../guide/pipelines.md) pages explain how the
groups fit together, with runnable examples.

## Errors

`cl-dataflow-error`, `graph-error`, `graph-error-graph`, `graph-error-detail`,
`node-not-found-error`, `node-not-found-designator`, `graph-cycle-error`,
`graph-cycle-nodes`, `effect-handler-missing-error`, `missing-effect-type`,
`effect-handler-missing-effect`, `effect-handler-missing-detail`,
`invalid-input-error`, `invalid-input-expected`, `invalid-input-value`,
`invalid-input-detail`, `invalid-transition-error`, `invalid-transition-state`,
`invalid-transition-event-type`, `invalid-transition-detail`,
`guard-failed-error`, `guard-failed-state`, `guard-failed-event-type`,
`guard-failed-transition`, `guard-failed-detail`

## Core data types and predicates

- Types: `node`, `edge`, `graph`, `context`, `event`, `effect`,
  `state-transition`, `state-machine`, `pipeline`
- Predicates: `node-p`, `edge-p`, `graph-p`, `context-p`, `event-p`,
  `effect-p`, `state-transition-p`, `state-machine-p`, `pipeline-p`

## Node and edge APIs

- Nodes: `node-name`, `node-inputs`, `node-outputs`, `node-handler`,
  `node-metadata`, `make-node`
- Edges: `edge-from`, `edge-from-port`, `edge-to`, `edge-to-port`,
  `edge-metadata`, `make-edge`

## Graph APIs — see [Graphs](../guide/graphs.md)

- Construction/validation: `graph-nodes`, `graph-edges`, `graph-metadata`,
  `make-graph`, `copy-graph`, `add-node`, `add-edge`, `find-node`,
  `graph-source-nodes`, `graph-sink-nodes`, `graph-reachable-p`,
  `graph-descendants`, `graph-ancestors`, `graph-path`, `validate-graph`,
  `topological-sort`
- Analysis: `graph-node-names`, `graph-order`, `graph-size`, `graph-empty-p`,
  `graph-successors`, `graph-predecessors`, `graph-out-degree`,
  `graph-in-degree`, `graph-transpose`, `graph-acyclic-p`,
  `graph-strongly-connected-components`, `graph-connected-components`,
  `graph-topological-generations`, `graph-distance`
- Export/serialization: `graph->dot`, `graph->mermaid`, `graph-layout`,
  `graph-to-plist`, `plist-to-graph`
- Mutation: `remove-node`, `remove-edge`, `graph-subgraph`, `graph-merge`,
  `graph-relabel-node`, `graph-contract-edge`
- Paths and order — see [Graph Analysis](../guide/graph-analysis.md#paths-and-order):
  `graph-transitive-closure`, `graph-transitive-reduction`,
  `graph-topological-rank`, `graph-longest-path`, `graph-all-paths`,
  `graph-find-cycle`, `graph-eulerian-path`, `graph-weighted-distance`,
  `graph-weighted-path`, `graph-weighted-distances-from`, `graph-max-flow`,
  `graph-min-cut`
- Metrics: `graph-density`, `graph-degree-histogram`,
  `graph-clustering-coefficient`, `graph-average-clustering`,
  `graph-reciprocity`, `graph-bipartite-p`, `graph-greedy-coloring`,
  `graph-equal-p`, `graph-undirected-reachable-p`
- Connectivity and centrality: `graph-connected-p`,
  `graph-strongly-connected-p`, `graph-self-loop-nodes`, `graph-condensation`,
  `graph-distances-from`, `graph-bfs-order`, `graph-dfs-order`,
  `graph-eccentricity`, `graph-diameter`, `graph-radius`, `graph-center`,
  `graph-periphery`, `graph-wiener-index`, `graph-average-path-length`,
  `graph-closeness-centrality`, `graph-betweenness-centrality`
- Algebra: `graph-union`, `graph-intersection`, `graph-difference`,
  `graph-diff`, `graph-filter-nodes`, `graph-map-nodes`
- Criticality: `graph-articulation-points`, `graph-bridges`,
  `graph-dominators`, `graph-post-dominators`

## Context APIs

`make-context`, `copy-context`, `context-values`, `context-value`,
`context-node-values`, `context-events`, `context-events-in-order`,
`context-event-types`, `context-events-of-type`, `context-effects`,
`context-effects-in-order`, `context-effect-types`, `context-effects-of-type`,
`context-trace`, `context-trace-in-order`, `context-last-event`,
`context-last-effect`, `context-metadata`, `context-effect-handlers`,
`context-result`, `context-state`, `context-merge`, `context-trace-of-kind`,
`context-equal-p`

## Event and effect APIs — see [Events and Effects](../guide/events-and-effects.md)

- Events: `make-event`, `copy-event`, `emit-event`, `event-type`,
  `event-payload`, `event-metadata`, `event-trace-index`
- Effects: `make-effect`, `copy-effect`, `perform-effect`, `effect-type`,
  `effect-payload`, `effect-metadata`, `effect-trace-index`, `effect-result`
- Batch: `emit-events`, `perform-effects`, `event-of-type-p`,
  `effect-of-type-p`, `context-effect-results`, `context-effect-results-of-type`
- Ergonomics: `register-effect-handler`, `context-effect-handler`,
  `effect-handled-p`, `context-effect-handler-types`,
  `with-effect-handler-scope`
- Serialization: `context-to-plist`, `plist-to-context`, `event-to-plist`,
  `plist-to-event`, `effect-to-plist`, `plist-to-effect`

## State machine APIs — see [State Machines](../guide/state-machines.md) and [State Machine Analysis](../guide/state-machine-analysis.md)

- Core (State Machines): `make-transition`, `define-state-machine`,
  `step-state-machine`, `run-state-machine`, `run-state-machine-with-context`,
  `make-state-machine-node`, `make-state-machine`, `copy-state-machine`,
  `state-machine-last-transition`, `state-machine-available-transitions`,
  `state-machine-can-step-p`, `reset-state-machine`, `transition-from`,
  `transition-event-type`, `transition-to`, `transition-guard`,
  `transition-action`, `transition-metadata`, `state-machine-state`,
  `state-machine-initial-state`, `state-machine-transitions`,
  `state-machine-history`, `state-machine-history-limit`,
  `state-machine-metadata`
- Analysis (State Machine Analysis): `state-machine-states`,
  `state-machine-event-types`, `state-machine-reachable-states`,
  `state-machine-unreachable-states`, `state-machine-terminal-states`,
  `state-machine-deterministic-p`, `write-state-machine-dot`,
  `write-state-machine-mermaid`, `state-machine->dot`, `state-machine->mermaid`
- Execution (State Machine Analysis): `state-machine-run-states`,
  `state-machine-accepts-p`, `state-machine-event-path`
- Builders (State Machine Analysis): `state-machine-to-plist`,
  `plist-to-state-machine`, `state-machine-complete-p`,
  `state-machine-transition-for`, `add-transition`, `remove-transition`,
  `state-machine-relabel-state`, `state-machine->graph`
- Equality/reachability (State Machine Analysis): `state-machine-equal-p`,
  `state-machine-reachable-p`

## Pipeline APIs — see [Pipelines and Workflows](../guide/pipelines.md)

- Core: `make-pipeline`, `define-pipeline`, `define-workflow`,
  `copy-pipeline`, `run-pipeline`, `run-pipeline-with-context`,
  `run-pipeline-sequence`, `pipeline-graph`, `pipeline-stages`,
  `pipeline-metadata`
- Extension: `pipeline-to-plist`, `plist-to-pipeline`, `pipeline-validate`,
  `pipeline-stage-count`, `map-pipeline`, `pipeline->node`
- Iterative (feedback): `run-pipeline-times`, `run-pipeline-until-fixpoint`,
  `run-pipeline-while`
- Equality: `pipeline-equal-p`

## Observability APIs — see [Observability and Serialization](../guide/observability.md)

`pipeline->dot`, `pipeline->mermaid`, `pipeline-node-names`,
`pipeline-stage-names`, `pipeline-source-names`, `pipeline-sink-names`,
`format-trace`, `trace-summary`, `context-summary`, `flow-describe`,
`flow-children`

## Combinator and contract APIs — see [Combinators and Resilience](../guide/combinators.md)

`mapping-handler`, `compose-handlers`, `retrying-handler`, `fallback-handler`,
`memoizing-handler`, `tapping-handler`, `wrap-node`, `node-with-retry`,
`node-with-fallback`, `node-with-memoization`, `node-with-tap`,
`contract-handler`, `node-with-contract`

## Stream APIs — see [Streams (Pull)](../guide/streams.md)

- Core: `flow-stream-p`, `empty-stream`, `list->stream`, `stream-of`,
  `stream-range`, `stream-map`, `stream-filter`, `stream-scan`,
  `stream-take`, `stream-drop`, `stream-take-while`, `stream-drop-while`,
  `stream-distinct`, `stream-flat-map`, `stream-concat`, `stream-zip`,
  `stream-tap`, `stream-collect`, `stream-reduce`, `stream-for-each`,
  `stream-count`, `stream-first`, `stream-empty-p`
- Generators/windows/aggregates: `stream-iterate`, `stream-repeat`,
  `stream-cycle`, `stream-enumerate`, `stream-unfold`, `stream-chunk`,
  `stream-window`, `stream-partition-by`, `stream-sum`, `stream-min`,
  `stream-max`, `stream-find`, `stream-some`, `stream-every`, `stream-last`,
  `stream-nth`
- Operators/collectors: `stream-zip-with`, `stream-interleave`,
  `stream-take-nth`, `stream-dedupe-consecutive`, `stream-interpose`,
  `stream-distinct-by`, `stream-group-by`, `stream-frequencies`,
  `stream-index-by`, `stream-partition`, `stream-split-at`, `stream-average`
- Statistics: `stream-flatten`, `stream-scan1`, `stream-count-if`,
  `stream-variance`, `stream-stddev`, `stream-median`
- Search: `stream-find-index`, `stream-none-p`, `stream-mode`,
  `stream-cartesian`

## Reactive subject APIs — see [Reactive Subjects (Push)](../guide/reactive.md)

- Core: `make-subject`, `subject-p`, `subject-subscribe`,
  `subject-unsubscribe`, `subject-emit`, `subject-subscriber-count`,
  `subject-map`, `subject-filter`, `subject-merge`, `subject-collect`
- Operators: `subject-scan`, `subject-distinct`, `subject-tap`,
  `subject-take`, `subject-drop`, `subject-take-while`, `subject-drop-while`,
  `subject-count`, `subject-flat-map`, `subject-partition`, `subject-zip`,
  `subject-combine-latest`, `subject-buffer`

## Protocols

`flow-name`, `flow-metadata`, `flow-kind` — implemented across nodes, edges,
graphs, contexts, events, effects, transitions, state machines, and
pipelines.

## Testing helpers

`run-pipeline-with-test-context`, `assert-emitted-events`,
`assert-performed-effects`, `assert-final-state`,
`assert-state-machine-state`, `assert-pipeline-result`

## Behavioral notes

- `node-not-found-error` exposes the missing designator so callers can
  inspect whether the failure came from a node name or an edge reference.
- `graph-cycle-error` exposes the remaining cyclic nodes so callers can
  inspect the exact cycle component that blocked ordering.
- `effect-handler-missing-error` includes the missing effect type and a
  copied effect snapshot so callers can inspect the payload that triggered
  the failure.
- `pipeline-graph` returns the *live*, validated graph owned by the
  pipeline — mutating it intentionally affects the pipeline. Use
  `copy-pipeline` for an isolated graph clone.
- `context-effect-handlers` is the exception to the note above: unlike
  `pipeline-graph`, it returns an *independent snapshot*, so mutating the
  returned hash table does not register anything. Use
  `register-effect-handler`, `with-effect-handler-scope`, or
  `(setf context-effect-handlers)` — which copies too. `copy-context` clones
  the table as well.
- Effect handlers are stored on the context with normalized lowercase string
  keys, so symbols and strings both resolve consistently through
  `make-context` and `perform-effect`.

See [Architecture](architecture.md) for how these groups map onto source
files, and [Core Concepts](../guide/core-concepts.md) for the vocabulary behind them.
