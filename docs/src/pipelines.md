# Pipelines and Workflows

A `pipeline` is an executable graph: a set of nodes wired together with
edges, run in topological order against a shared [`context`](core-concepts.md#context).
This page covers how to build pipelines, how they run (including branching
and feedback runs), how to inspect and copy them, and how `define-workflow`
unifies a pipeline with a state machine in one declarative form.

## Building pipelines with `make-pipeline`

`make-pipeline` accepts either an explicit `:graph`, a bare `:stages` list,
or both:

```lisp
;; From an explicit graph.
(defparameter *graph* (cl-dataflow:make-graph))
(cl-dataflow:add-node *graph* (cl-dataflow:make-node "start"))
(cl-dataflow:add-node *graph* (cl-dataflow:make-node "finish"))
(cl-dataflow:add-edge *graph* "start" "finish")
(defparameter *from-graph* (cl-dataflow:make-pipeline :graph *graph*))

;; From a bare stage list: make-pipeline chains the stages into a linear
;; graph for you, connecting each stage's first output port to the next
;; stage's first input port.
(defparameter *from-stages*
  (cl-dataflow:make-pipeline
    :stages (list (cl-dataflow:make-node "parse")
                  (cl-dataflow:make-node "validate"))))
```

What `:stages` may contain depends on whether `:graph` is also given:

- **Without `:graph`**, each stage is either a `node` or a plist of
  `make-node`'s own arguments (`:name`, `:inputs`, `:outputs`, `:handler`,
  `:metadata`), which `make-pipeline` turns into a node for you before
  chaining.
- **With `:graph`**, `:stages` is an explicit stage *order* over that graph,
  so each element must be a `node` — typically one returned by `find-node` —
  and is resolved against the graph's own node of that name. (Bare name
  strings are only accepted by `define-pipeline`'s `:stages`, below.)

`make-pipeline` also accepts `:metadata`, stored on the pipeline (see
[`pipeline-metadata`](#inspecting-a-pipeline) below).

## The `define-pipeline` DSL

`define-pipeline` builds the graph declaratively from `:node` and `:edge`
clauses and returns a `pipeline`:

```lisp
(defparameter *pipeline*
  (cl-dataflow:define-pipeline ()
    (:node "start"
     :handler (lambda (input context)
                (declare (ignore context))
                (1+ input)))
    (:node "finish"
     :handler (lambda (input context)
                (declare (ignore context))
                (* input 2)))
    (:edge "start" "finish")))

(cl-dataflow:run-pipeline *pipeline* :input 10)
;; => 22
```

Each `:node` clause accepts `:inputs`, `:outputs`, `:handler`, and
`:metadata` — the same keyword arguments `make-node` takes. Each `:edge`
clause accepts `:from-port`, `:to-port`, and `:metadata` — the same
arguments `add-edge` takes. `define-pipeline`'s own top-level options are
`:metadata` (stored on both the graph and the pipeline) and `:stages` (an
explicit stage order; node names or node values are both accepted, and
each is resolved against the graph being built).

## Branching pipelines

A pipeline's graph is a DAG, not necessarily a linear chain: one node can
fan out to several downstream nodes, and `run-pipeline` drives every stage
in the graph's topological order, not just a single straight-line path.

```lisp
(defparameter *branching*
  (cl-dataflow:define-pipeline ()
    (:node "ingest" :handler (lambda (input context)
                                (declare (ignore context))
                                input))
    (:node "double" :handler (lambda (input context)
                                (declare (ignore context))
                                (* input 2)))
    (:node "increment" :handler (lambda (input context)
                                   (declare (ignore context))
                                   (1+ input)))
    (:edge "ingest" "double")
    (:edge "ingest" "increment")))

(cl-dataflow:run-pipeline *branching* :input 10)
;; => (("double" ("value" . 20)) ("increment" ("value" . 11)))
```

`"ingest"`'s output feeds both `"double"` and `"increment"` independently.
When a pipeline has exactly one sink node (a node with no outgoing edge),
`run-pipeline` returns that sink's collapsed output directly, as in the
linear example above. When there is more than one sink, it returns a list
of `(node-name . outputs)` entries, one per sink, in the pipeline's stage
order — as shown here, where `"double"` and `"increment"` are both sinks.
(That is the execution order, which is not necessarily the name order
[`pipeline-sink-names`](#inspecting-a-pipeline) reports.)

## Running pipelines

- `run-pipeline` (`pipeline &key input context`) drives every stage in
  topological order and returns the sink result(s). If `:context` is
  omitted, a fresh context is created for the run.
- `run-pipeline-with-context` runs the same way but always returns
  `(values result context)`, so callers who need to inspect the run's
  events, effects, or trace afterward do not have to build the context
  themselves first.
- `run-pipeline-sequence` (`pipelines &key input context`) runs a list of
  *pipelines* in order, threading each pipeline's result into the next as
  its `:input`, and returns `(values final-result context)`. A single
  shared context (created when `:context` is `nil`) accumulates the
  events, effects, and trace of every pipeline in the sequence, so the
  whole composite run is observable as one unit. An empty list returns
  `(values input context)`.

```lisp
(defparameter *double* (cl-dataflow:define-pipeline ()
                          (:node "double" :handler (cl-dataflow:mapping-handler
                                                      (lambda (x) (* x 2))))))
(defparameter *increment* (cl-dataflow:define-pipeline ()
                             (:node "increment" :handler (cl-dataflow:mapping-handler
                                                            (lambda (x) (1+ x))))))

(cl-dataflow:run-pipeline-sequence (list *double* *increment*) :input 20)
;; => (VALUES 41 #<CONTEXT ...>)
```

See [Combinators and Resilience](combinators.md) for `mapping-handler` and
the other handler-wrapping helpers used above.

## Inspecting a pipeline

| Function | Returns |
| --- | --- |
| `pipeline-p` | True when the value is a `pipeline`. |
| `pipeline-graph` | The **live** graph backing the pipeline. |
| `pipeline-stages` | An independent snapshot of the resolved stage order, as `node` objects. |
| `pipeline-metadata` | An independent snapshot of the pipeline's metadata. |
| `pipeline-stage-count` | The number of stages (from `pipeline-ext.lisp`). |
| `pipeline-stage-names` | The stage *names*, in execution order. |
| `pipeline-node-names` | Every node name in the graph, ordered lexicographically. |
| `pipeline-source-names` | The names of the source nodes (indegree 0), ordered by name. |
| `pipeline-sink-names` | The names of the sink nodes (no successors), ordered by name. |
| `pipeline->dot` / `pipeline->mermaid` | The graph rendered as a Graphviz DOT or Mermaid flowchart string. |

`pipeline-node-names`, `pipeline-source-names`, `pipeline-sink-names`,
`pipeline->dot`, and `pipeline->mermaid` are thin forwards to `graph-node-names`,
`graph-source-nodes`, `graph-sink-nodes`, `graph->dot`, and `graph->mermaid`
on `pipeline-graph`; see
[Observability and Serialization](observability.md) for their full behaviour.
Note the ordering difference: `pipeline-stage-names` follows execution order,
while `pipeline-node-names`, `pipeline-source-names`, and `pipeline-sink-names`
are ordered by name.

`pipeline-graph` is the one exception to "readers return snapshots": it
returns the actual graph object the pipeline runs against, so mutating it
(`add-node`, `add-edge`, ...) intentionally affects the pipeline's next
run. Use `copy-pipeline` when you need an isolated clone instead:

```lisp
(defparameter *copy* (cl-dataflow:copy-pipeline *pipeline*))

;; Mutating *pipeline*'s live graph does not affect *copy*.
(cl-dataflow:add-node (cl-dataflow:pipeline-graph *pipeline*)
                      (cl-dataflow:make-node "extra"))
(cl-dataflow:graph-order (cl-dataflow:pipeline-graph *pipeline*)) ;; => 3
(cl-dataflow:graph-order (cl-dataflow:pipeline-graph *copy*))     ;; => 2
```

`copy-pipeline` preserves the pipeline's graph, stage order, and metadata,
remapping the stage list onto the copied graph's own node instances. Pipeline
stage lists and graphs are also copied on construction and plain assignment
(`(setf pipeline-stages ...)`, `(setf pipeline-graph ...)`), so a caller-owned
list or graph passed into `make-pipeline` or a setter never leaks further
mutations into the pipeline object afterward.

## Node handler input and output normalization

A node handler is a function of `(input context)`. Its `input` is
normalized from whatever structure the incoming value has — a hash table,
an alist, a plist, or a plain scalar — into the shape the node's declared
input ports expect, and the value the handler returns is normalized back
into per-output-port bindings folded into the context and (for sink nodes)
the pipeline's final result. A single-input/single-output node just sees
and returns a scalar, as in every example above; nodes with multiple named
ports see and return the corresponding keyed structure. See
[Core Concepts](core-concepts.md#pipelines-and-workflows) for how this
fits into the wider context model.

## `define-workflow`: pipelines and state machines together

`define-workflow` unifies a pipeline's graph edges, a state machine's
transitions, and machine-driven pipeline nodes in one macro expansion, and
returns `(values pipeline machine)`:

```lisp
(multiple-value-bind (pipeline machine)
    (cl-dataflow:define-workflow (:state "idle")
      (:transition "idle" "create" "created")
      (:transition "created" "ship" "shipped")
      (:node "receive" :handler (lambda (input context)
                                   (declare (ignore context))
                                   input))
      (:machine-node :name "create-step"
                     :event-fn (lambda (input context)
                                 (declare (ignore input context))
                                 "create"))
      (:machine-node :name "ship-step"
                     :event-fn (lambda (input context)
                                 (declare (ignore input context))
                                 "ship"))
      (:edge "receive" "create-step")
      (:edge "create-step" "ship-step"))
  (let ((context (cl-dataflow:make-context)))
    (values (cl-dataflow:run-pipeline pipeline :input "A-1" :context context)
            (cl-dataflow:context-state context))))
;; => (VALUES "shipped" "shipped")
```

`define-workflow` accepts four clause kinds:

- `:transition` — same shape as `make-transition` (`from event to &rest
  options`, options `:guard`/`:action`/`:metadata`); collected into the
  state machine's `:transitions`.
- `:node` and `:edge` — the same pipeline clauses `define-pipeline` accepts.
- `:machine-node` — turns the workflow's own state machine into a pipeline
  stage via `make-state-machine-node`, accepting `:name`, `:event-fn`,
  `:result-fn`, and `:metadata`. `:event-fn` computes the event to step the
  machine with from the node's `(input context)`; without it, the node's
  input is used as the event directly. `:result-fn` is called with
  `(machine event input context)` to compute the node's output; without it,
  the node emits the machine's new state — which is why the run above yields
  `"shipped"`.

Top-level options include `:state`/`:initial-state`, `:history`,
`:history-limit`, and `:machine-metadata` (all forwarded to
`make-state-machine`), plus `:pipeline-metadata` and `:stages` (forwarded
to the pipeline half). See [State Machines](state-machines.md) for
`make-state-machine`, transitions, and guards in depth, and
[Events and Effects](events-and-effects.md) for emitting events alongside
a workflow's state transitions.

## Iterative and feedback pipelines

Every pipeline above runs once, straight through its DAG. `run-pipeline-times`,
`run-pipeline-until-fixpoint`, and `run-pipeline-while` add a *recurrent,
settling* execution model on top of that single-pass run: each feeds a
pipeline's result back in as the next run's input, repeatedly, so the same
DAG can model an iterative or converging computation instead of a one-shot
transformation. All three share one context across every iteration, so
events, effects, and trace accumulate across the whole run.

```lisp
(defparameter *halve*
  (cl-dataflow:define-pipeline ()
    (:node "halve" :handler (lambda (input context)
                               (declare (ignore context))
                               (floor input 2)))))

;; Run exactly N times.
(cl-dataflow:run-pipeline-times *halve* 3 :input 40)
;; => (VALUES 5 #<CONTEXT ...>)

;; Run until a result equals the value fed into it (a fixpoint), or an
;; iteration cap (MAX-ITERATIONS, default 1000) is reached.
(cl-dataflow:run-pipeline-until-fixpoint *halve* :input 40)
;; => (VALUES 0 7 T)   ; result, iterations, fixpoint-p

;; Run while a predicate holds on the current value, checked before each run.
(cl-dataflow:run-pipeline-while *halve* (lambda (value) (> value 1)) :input 40)
;; => (VALUES 1 5)     ; final-value, iterations
```

`run-pipeline-times n` with `n = 0` returns `(values input context)`
unchanged — `n` is the iteration count, so it takes no `:max-iterations`.
`run-pipeline-until-fixpoint` compares with `:test` (default `#'equal`) and
returns `(values result iterations fixpoint-p)`, where `fixpoint-p` is only
true when equality was reached before the cap; on hitting the cap it returns
`(values last-value max-iterations nil)`. `run-pipeline-while` returns
`(values final-value iterations)`. Both of the unbounded forms take
`:max-iterations` (default 1000) so a non-converging pipeline or an
always-true predicate still terminates.

## Extension APIs

`pipeline-ext.lisp` adds serialization, validation, and composition helpers
on top of the core pipeline runtime:

- `pipeline-to-plist`/`plist-to-pipeline` round-trip a pipeline's
  *structure* — metadata, graph (nodes, ports, edges, metadata), and stage
  order — through a plist. Node handlers are runtime closures, so they are
  not serialized; `plist-to-pipeline` reconstructs nodes with the default
  identity handler. This is also what `pipeline-equal-p` compares (see
  below), and what [Observability and Serialization](observability.md)
  builds on for exporting pipelines outside the running image.
- `pipeline-validate` runs `validate-graph` on the pipeline's graph
  (structural integrity plus acyclicity) and returns `t`, or signals the
  same conditions `validate-graph` would on a malformed or cyclic graph.
- `pipeline-stage-count` returns the number of stages.
- `map-pipeline` (`pipeline inputs &key context`) runs `pipeline` once per
  element of `inputs` and returns the list of results in order. With no
  `:context`, each run gets its own fresh context — independent runs; with
  a shared `:context`, every run's events, effects, and trace accumulate
  into that one context.
- `pipeline->node` (`pipeline name &key metadata`) returns a node whose
  handler runs `pipeline` on the node's input, in its own isolated
  context, and yields `pipeline`'s result — embedding a whole pipeline as
  a single stage of a larger graph.

```lisp
(defparameter *plist* (cl-dataflow:pipeline-to-plist *pipeline*))
(defparameter *rebuilt* (cl-dataflow:plist-to-pipeline *plist*))
(cl-dataflow:pipeline-validate *rebuilt*)     ;; => T
(cl-dataflow:pipeline-stage-count *rebuilt*)  ;; => 2

(cl-dataflow:map-pipeline *pipeline* '(1 2 3))
;; => (result-for-1 result-for-2 result-for-3), independent contexts

(defparameter *outer-graph* (cl-dataflow:make-graph))
(cl-dataflow:add-node *outer-graph* (cl-dataflow:pipeline->node *pipeline* "embedded"))
(defparameter *outer* (cl-dataflow:make-pipeline :graph *outer-graph*))
```

## Structural equality

`pipeline-equal-p` compares two pipelines structurally, through
`pipeline-to-plist`: identical graph (nodes, ports, edges, metadata), stage
order, and pipeline metadata count as equal, regardless of whether the two
pipelines' node handlers are the same closures. This is why
`plist-to-pipeline`'s reconstructed pipeline — with identity handlers in
place of the originals — still compares equal to the pipeline it was
serialized from.

## Where to go next

- [Graphs](graphs.md) covers the node/edge/graph construction API that
  `define-pipeline`'s `:node`/`:edge` clauses build on.
- [Graph Algorithms](graph-algorithms.md) covers topological sort and the
  rest of the analysis layer `run-pipeline` relies on for execution order.
- [State Machines](state-machines.md) covers `make-state-machine`,
  `step-state-machine`, and guarded transitions in depth.
- [Combinators and Resilience](combinators.md) covers `mapping-handler`,
  retry/fallback/memoization wrappers, and the node-wrapping helpers used
  in `run-pipeline-sequence`'s example above.
- [Observability and Serialization](observability.md) covers
  `pipeline->dot`/`pipeline->mermaid` and the rest of the export surface
  built on `pipeline-to-plist`.
