# Observability and Serialization

Once a pipeline or workflow has run, `cl-dataflow` gives you three
complementary ways to look back at it: **render** its structure as a
diagram, **read** its recorded trace as text or roll-up counts, and
**serialize** its context to a plain plist for storage, comparison, or
transmission. All of it is built on one shared introspection protocol —
`flow-name`, `flow-metadata`, and `flow-kind` — so the same handful of
functions work uniformly across nodes, edges, graphs, contexts, events,
effects, transitions, state machines, and pipelines.

This page covers the pipeline- and context-level observability layer
(`src/observability.lisp`, `src/introspection.lisp`), the cross-type
protocol (`src/protocols.lisp`), context/event/effect serialization
(`src/context-serialization.lisp`), and the structural equality predicates
(`src/equality-predicates.lisp`). The lower-level graph renderers
(`graph->dot`/`graph->mermaid`) and graph serialization
(`graph-to-plist`/`plist-to-graph`) are documented on [Graphs](graphs.md);
pipeline (`pipeline-to-plist`/`plist-to-pipeline`) and state-machine
(`state-machine-to-plist`/`plist-to-state-machine`) plist round trips are
documented on [Pipelines and Workflows](pipelines.md) and
[State Machines](state-machines.md) respectively — this page completes that
story for contexts, events, and effects.

## Rendering a pipeline

`pipeline->dot` and `pipeline->mermaid` render a pipeline's underlying graph
for visualization. They are thin wrappers over `graph->dot`/`graph->mermaid`
(see [Graphs](graphs.md#export-and-serialization) for the deterministic
sort order and rendering details) applied to `pipeline-graph`:

```lisp
(cl-dataflow:pipeline->dot *pipeline* :name "ingest-pipeline")
;; => "digraph ingest-pipeline {
;;      \"finish\";
;;      \"start\";
;;      \"start\" -> \"finish\" [label=\"value -> value\"];
;;    }
;;    "

(cl-dataflow:pipeline->mermaid *pipeline* :direction "LR")
;; => "flowchart LR
;;      n0[\"finish\"]
;;      n1[\"start\"]
;;      n1 -->|value -> value| n0
;;    "
```

Note that nodes are emitted in **name** order (`finish` before `start`), not
execution order, and every edge carries a `from-port -> to-port` label — the
default `value` ports here — so parallel edges across different ports stay
distinguishable.

`:name` and `:direction` default to `"pipeline"` and `"TD"`, matching the
graph-level defaults.

## Structural role enumeration

Four functions answer "what is in this pipeline, and what role does each
node play" without walking the graph by hand:

| Function | Returns |
| --- | --- |
| `pipeline-node-names` | Every node name in the graph, lexicographically ordered (delegates to `graph-node-names`). |
| `pipeline-stage-names` | Stage names in **execution order** (the order `run-pipeline` runs them in). |
| `pipeline-source-names` | Names of source nodes — indegree 0 — name-ordered. |
| `pipeline-sink-names` | Names of sink nodes — no successors — name-ordered. |

```lisp
(cl-dataflow:pipeline-node-names *pipeline*)
;; => ("finish" "start")

(cl-dataflow:pipeline-stage-names *pipeline*)
;; => ("start" "finish")

(cl-dataflow:pipeline-source-names *pipeline*)
;; => ("start")

(cl-dataflow:pipeline-sink-names *pipeline*)
;; => ("finish")
```

Note the difference between `pipeline-node-names` (alphabetical, useful for
set-like comparisons) and `pipeline-stage-names` (execution order, useful for
understanding data flow) — they can diverge whenever a node's name doesn't
happen to sort the same way it runs.

## Trace formatting and summarizing

Every pipeline run and state-machine step appends to `context-trace`: node
runs, emitted events, performed effects, and state transitions all land in
one unified, chronologically ordered log. `format-trace`, `trace-summary`,
and `context-summary` turn that raw plist trace into something you can read
or report on.

`format-trace` renders the whole trace as numbered, human-readable lines:

```lisp
(princ (cl-dataflow:format-trace *context*))
;; 0. event order-created
;; 1. transition idle --order-created--> order-created
;; 2. node start
;; 3. node finish
```

A node's trace record is appended *after* its handler returns, so anything the
handler emits along the way — events, effects, state transitions — lands
before its own `node` entry. Above, `start`'s handler emitted the event and
stepped the state machine, so both precede `node start`.

`trace-summary` counts trace entries by kind:

```lisp
(cl-dataflow:trace-summary *context*)
;; => (:total 4 :nodes 2 :events 1 :effects 0 :transitions 1)
```

`context-summary` gives a broader roll-up of the context itself — event,
effect, and stored-value counts, the trace length, and the current state —
rather than just the trace:

```lisp
(cl-dataflow:context-summary *context*)
;; => (:events 1 :effects 0 :values 2 :trace 4 :state "order-created")
```

Here is a runnable example, adapted from the workflow in
[Quick Start](quick-start.md#adding-events-and-a-state-machine), that drives
a small workflow and then inspects it with both functions:

```lisp
(defparameter *machine*
  (cl-dataflow:make-state-machine
    :state "idle"
    :transitions
    (list (cl-dataflow:make-transition "idle" "order-created" "order-created"))))

(defparameter *workflow*
  (cl-dataflow:make-pipeline
    :stages
    (list (cl-dataflow:make-node
            "create-order"
            :handler (lambda (input context)
                       (cl-dataflow:emit-event context "order-created" :payload input)
                       (cl-dataflow:step-state-machine
                         *machine* "order-created" :context context)
                       input)))))

(defparameter *context*
  (cl-dataflow:run-pipeline-with-test-context
    *workflow* :input "A-100" :state "idle"))

(princ (cl-dataflow:format-trace *context*))
;; 0. event order-created
;; 1. transition idle --order-created--> order-created
;; 2. node create-order

(cl-dataflow:trace-summary *context*)
;; => (:total 3 :nodes 1 :events 1 :effects 0 :transitions 1)

(cl-dataflow:context-summary *context*)
;; => (:events 1 :effects 0 :values 1 :trace 3 :state "order-created")
```

## Introspection: merging, filtering, and describing

Beyond formatting a single context's trace, `src/introspection.lisp`
provides three cross-cutting tools for working with contexts and flow
objects generically.

### Combining two contexts

`context-merge` returns a **new** context that combines two runs — useful
when a workflow forks into parallel branches and you need to reassemble a
single observable record:

```lisp
(cl-dataflow:context-merge *context-a* *context-b*)
```

The merge rules:

- Stored node values: `*context-b*`'s values overlay `*context-a*`'s
  (`*context-b*` wins on key collisions).
- Events, effects, and trace: concatenated, `*context-a*`'s entries first.
- Effect handlers: merged into one table, with `*context-b*`'s handlers
  overlaying `*context-a*`'s on key collisions.
- Metadata: the two plists are concatenated with `*context-a*`'s first. Since
  `getf` returns the *first* match, `*context-a*` wins on duplicate keys — the
  opposite of the effect-handler rule, and the opposite direction from stored
  node values. Merging `(:m 1)` with `(:m 2 :n 3)` yields `(:m 1 :m 2 :n 3)`.
- Current state and result: taken from `*context-a*` (the base).

Neither input context is modified — every context reader hands back a copy,
so the merge builds its tables without touching either input.

### Filtering a trace by kind

`context-trace-of-kind` narrows a context's trace to one entry kind —
`:node`, `:event`, `:effect`, or `:transition` — in chronological order,
which is handy when `format-trace`'s combined view is too broad:

```lisp
(cl-dataflow:context-trace-of-kind *context* :transition)
;; => ((:from "idle" :event-type "order-created" :to "order-created"
;;      :state-before "idle" :guard-passed t :action-result nil))
```

### A uniform structural view: flow-describe / flow-children

`flow-children` returns the immediate sub-components of a flow object:

- a graph's nodes, name-ordered;
- a pipeline's stages, in execution order;
- a state machine's transitions.

Leaf objects — nodes, edges, events, effects, transitions, and contexts —
have no children and return `'()`.

`flow-describe` combines `flow-kind`, `flow-name`, `flow-metadata`, and a
child *count* (not the children themselves) into one structural plist,
giving generic tooling a single call that works the same way regardless of
what kind of object it's handed:

```lisp
(cl-dataflow:flow-describe *pipeline*)
;; => (:kind :pipeline :name :pipeline :metadata () :children 2)

(cl-dataflow:flow-describe (cl-dataflow:find-node (cl-dataflow:pipeline-graph *pipeline*) "start"))
;; => (:kind :node :name "start" :metadata () :children 0)
```

## The flow-name / flow-metadata / flow-kind protocol

`src/protocols.lisp` defines one introspection protocol implemented across
every public flow object — `node`, `edge`, `graph`, `context`, `event`,
`effect`, `state-transition`, `state-machine`, and `pipeline` — via a shared
`define-flow-dispatch` macro:

| Function | Purpose |
| --- | --- |
| `flow-name` | The object's identifying name or key: a node's name, an edge's `(from to)` pair, an event's type, a transition's event type, a state machine's current state, or a fixed keyword (`:graph`, `:context`, `:pipeline`) for objects without an intrinsic name. |
| `flow-metadata` | The object's metadata plist (empty list if none was set). |
| `flow-kind` | A keyword tag identifying the object's type: `:node`, `:edge`, `:graph`, `:context`, `:event`, `:effect`, `:state-transition`, `:state-machine`, or `:pipeline`. |

The protocol exists so **generic tooling can treat every flow object the
same way** without a large `typecase` at every call site — `flow-describe`
and `flow-children` above are exactly that: they are built entirely on top
of `flow-name`/`flow-metadata`/`flow-kind` plus a per-type children rule,
rather than re-deriving type dispatch themselves. Any object outside that
closed set signals a `type-error` naming the expected types, so a caller
passing something unsupported gets a clear failure rather than silent
`nil`.

```lisp
(cl-dataflow:flow-kind *pipeline*)
;; => :pipeline

(cl-dataflow:flow-name (cl-dataflow:make-edge "start" "finish"))
;; => ("start" "finish")
```

## Serialization: contexts, events, and effects

`src/context-serialization.lisp` completes the plist round-trip story that
graphs (`graph-to-plist`/`plist-to-graph`, see [Graphs](graphs.md)),
pipelines, and state machines (see [Pipelines and Workflows](pipelines.md)
and [State Machines](state-machines.md)) already have.

`event-to-plist`/`plist-to-event` and `effect-to-plist`/`plist-to-effect`
round-trip a single event or effect:

```lisp
(cl-dataflow:event-to-plist (cl-dataflow:make-event "order-created" :payload '(:order-id "A-100")))
;; => (:type "order-created" :payload (:order-id "A-100") :metadata nil :trace-index nil)

(cl-dataflow:effect-to-plist (cl-dataflow:make-effect "charge-card" :payload 4200 :result :ok))
;; => (:type "charge-card" :payload 4200 :metadata nil :trace-index nil :result :ok)
```

`context-to-plist` serializes a context's entire **observable** state —
stored node values, events, effects, trace, metadata, state, and result —
with events/effects/trace normalized into chronological order.
`plist-to-context` rebuilds a context from that plist. Here is a full round
trip over the `*context*` from the workflow example above, showing what
survives:

```lisp
(defparameter *plist* (cl-dataflow:context-to-plist *context*))

(getf *plist* :state)
;; => "order-created"
(getf *plist* :events)
;; => ((:type "order-created" :payload "A-100" :metadata nil :trace-index 0))

(defparameter *restored* (cl-dataflow:plist-to-context *plist*))

(cl-dataflow:context-state *restored*)
;; => "order-created"
(mapcar #'cl-dataflow:event-type (cl-dataflow:context-events-in-order *restored*))
;; => ("order-created")

(cl-dataflow:context-equal-p *context* *restored*)
;; => T
```

Effect handlers are runtime closures, not data, so `context-to-plist`
deliberately **excludes** `context-effect-handlers` — a context rebuilt by
`plist-to-context` has an empty handler table, just as `plist-to-graph`
rebuilds nodes with the default identity handler rather than preserving
the original closures:

```lisp
(cl-dataflow:context-effect-handlers *restored*)
;; => #<HASH-TABLE :TEST EQUAL :COUNT 0> (empty — handlers are not serialized)
```

Register handlers again on the restored context (`register-effect-handler`)
before running it further.

## Structural equality and reachability

`src/equality-predicates.lisp` generates four structural-equality predicates
from one `define-plist-equal-p` macro, all built on the same idea: two values
are structurally equal when their **deterministic plist serializations** are
`equal`, so runtime closures (node handlers, effect handlers, state-machine
guards and actions) never affect the comparison.

| Predicate | Compares |
| --- | --- |
| `graph-equal-p` | Nodes (names, ports, metadata) and edges (endpoints, ports, metadata), independent of insertion order (via `graph-to-plist`; see [Graphs](graphs.md)). Node handlers are ignored. |
| `pipeline-equal-p` | Graphs, stage order, and metadata (via `pipeline-to-plist`). Node handlers are ignored. |
| `state-machine-equal-p` | Current state, initial state, metadata, and transitions by from/event/to/metadata (via `state-machine-to-plist`). Guards and actions are ignored. |
| `context-equal-p` | Stored values, events, effects, trace, metadata, state, and result (via `context-to-plist`). Effect handlers are ignored. |

```lisp
(cl-dataflow:pipeline-equal-p *pipeline* (cl-dataflow:copy-pipeline *pipeline*))
;; => T

(cl-dataflow:context-equal-p *context* *restored*)
;; => T
```

`state-machine-reachable-p` is a reachability predicate rather than an
equality one: it asks whether state `to` can be reached from state `from`
by following zero or more transitions (so `from` = `to` is trivially
reachable), comparing state names case-insensitively:

```lisp
(cl-dataflow:state-machine-reachable-p *machine* "idle" "order-created")
;; => T
```

## Where to go next

- [Graphs](graphs.md) covers `graph->dot`/`graph->mermaid` and
  `graph-to-plist`/`plist-to-graph`, the lower-level renderers and
  serializer this page's pipeline functions build on.
- [Pipelines and Workflows](pipelines.md) covers `pipeline-to-plist`/
  `plist-to-pipeline` and the rest of the pipeline construction API.
- [State Machines](state-machines.md) covers `state-machine-to-plist`/
  `plist-to-state-machine` and the analysis functions
  (`state-machine-reachable-states`, `state-machine-unreachable-states`, ...)
  that `state-machine-reachable-p` builds on.
- [Public API Reference](api-reference.md) lists every function on this page
  in one place, across its Observability, Context, Protocols, and
  serialization/equality groups.
