# Examples

Each of the eleven examples under `examples/` is a plain script you run
directly with SBCL. Every one of them starts by `load`ing the twelfth file,
`examples/bootstrap.lisp`, which pushes the repository root onto
`asdf:*central-registry*` and calls `asdf:load-system "cl-dataflow"` — so ASDF
resolves the load order and the `cl-prolog` dependency, and no script has to
restate the source-file list.

`cl-prolog` itself must already be somewhere ASDF can find it; `nix develop`
puts it on `CL_SOURCE_REGISTRY` for you (see
[Getting Started](../getting-started.md)).

```bash
sbcl --script examples/simple-pipeline.lisp
sbcl --script examples/event-workflow.lisp
sbcl --script examples/state-machine.lisp
sbcl --script examples/graph-analysis.lisp
sbcl --script examples/graph-toolkit.lisp
sbcl --script examples/state-machine-visualization.lisp
sbcl --script examples/resilient-pipeline.lisp
sbcl --script examples/streams.lisp
sbcl --script examples/graph-analysis-advanced.lisp
sbcl --script examples/stream-analytics.lisp
sbcl --script examples/integration.lisp
```

| Script | Demonstrates | Expected output |
| --- | --- | --- |
| `simple-pipeline.lisp` | A four-stage `make-pipeline` — parse, validate, transform, render — built from explicit `make-node` handlers. | `Simple pipeline result: rendered: 70` |
| `event-workflow.lisp` | A pipeline stage emitting events and driving a state machine (see [Getting Started](../getting-started.md#adding-events-and-a-state-machine)). | The final workflow state and event trace. |
| `state-machine.lisp` | A standalone state-machine transition flow. | `Final state: completed`, the transition count, and the last transition record. |
| `graph-analysis.lisp` | Reachability analysis — descendants, ancestors, shortest path, boundaries — over a dataflow graph. | The downstream/upstream node sets, the shortest `ingest -> load` path, and the graph's source and sink nodes. |
| `graph-toolkit.lisp` | Strongly connected components, topological generations, transpose, distance, and DOT/Mermaid rendering. | Graph order/size, topological generations, `a -> d` distance, SCCs, and both diagrams. |
| `state-machine-visualization.lisp` | State/event enumeration, reachability, terminal and unreachable states, DOT/Mermaid rendering. | The state and event sets, reachable/unreachable/terminal states, the determinism verdict, and both diagrams. |
| `resilient-pipeline.lisp` | Retrying and fallback node wrappers (see [Combinators and Resilience](combinators.md)), plus result-threading pipeline sequencing. | `Retry result: 70 (after 3 attempts)`, the fallback results, and the sequenced pipeline result. |
| `streams.lisp` | Lazy stream pipelines (`map`/`filter`/`take`/`scan`/`flat-map`/`distinct`) over an unbounded range (see [Streams (Pull)](streams.md)). | `First 3 even squares: (4 16 36)`, running totals, the flat-mapped list, and the distinct sum. |
| `graph-analysis-advanced.lisp` | Critical path, topological rank, transitive reduction, weighted distance, density/bipartiteness, and a serialization round trip. | The critical path, topological rank, transitive-reduction edge count, weighted distance, density/bipartiteness, and a confirmed round trip. |
| `stream-analytics.lisp` | Frequencies, group-by, partition, sliding-window averages, and whole-stream mean. | Event frequencies, parity grouping, partition, sliding-window averages, and the mean of 1..100. |
| `integration.lisp` | An end-to-end scenario composing pipelines, graph analysis, pull streams, reactive subjects, a state machine, and context serialization. | The priced orders, high-value reactive alerts, the state-machine driving events, and a confirmed serialization round trip. |

## Reading `graph-analysis.lisp`

This example models a small ingestion pipeline as a dependency graph and asks
two structural questions with [`graph-descendants`/`graph-ancestors`](graph-algorithms.md):

```lisp
(defparameter *graph* (cl-dataflow:make-graph))

(dolist (name '("ingest" "parse" "validate" "metrics" "transform" "audit" "load"))
  (cl-dataflow:add-node *graph* (cl-dataflow:make-node name)))

(dolist (edge '(("ingest" "parse") ("parse" "validate") ("parse" "metrics")
                ("validate" "transform") ("validate" "audit") ("transform" "load")))
  (cl-dataflow:add-edge *graph* (first edge) (second edge)))

;; Impact analysis: everything downstream of "parse".
(cl-dataflow:graph-descendants *graph* "parse")

;; Dependency analysis: everything "load" depends on.
(cl-dataflow:graph-ancestors *graph* "load")
```

`graph-descendants`/`graph-ancestors` answer "what breaks if I change this
node?" and "what does this node depend on?" directly, without hand-rolling a
traversal — both are linear over the bulk-query adjacency snapshot and
terminate on cyclic graphs. See [Graph Algorithms](graph-algorithms.md) for
the rest of the reachability and analysis surface.

## Example scripts as regression tests

`scripts/run-examples.sh` (also wired as the `examples` flake check) runs
every example script as its own process under a hard timeout and asserts a
clean exit, which is what actually keeps this page honest.

`t/core-runtime-example-test.lisp` also defines one smoke test per example
script, asserting exact substrings of its output — but do **not** enable it
by setting `CL_DATAFLOW_RUN_EXAMPLE_SMOKE=1`: spawning the example processes
from inside the running test suite deadlocks it, confirmed by direct
reproduction. It stays opt-in, and unused, for exactly that reason. Use
`scripts/run-examples.sh` or run the scripts by hand instead — see
[Development](../project/development.md).
