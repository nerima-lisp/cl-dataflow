# Quick Start

## A two-stage pipeline

`define-pipeline` builds a graph from `:node` and `:edge` forms and returns a
`pipeline` value that `run-pipeline` executes in topological order:

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

Each node's handler receives the current value and the run's `context`, and
returns the value passed to its successors. `run-pipeline` threads `:input`
through the graph in topological order and returns the sink's result.

## Adding events and a state machine

A pipeline stage can emit events and step a state machine in the same
handler, which is how `cl-dataflow` models an end-to-end workflow. This is
adapted from `examples/event-workflow.lisp`:

```lisp
(defparameter *machine*
  (cl-dataflow:make-state-machine
    :state "idle"
    :transitions
    (list
      (cl-dataflow:make-transition "idle" "order-created" "order-created")
      (cl-dataflow:make-transition "order-created" "reserve-inventory" "inventory-reserved")
      (cl-dataflow:make-transition "inventory-reserved" "payment-requested" "payment-requested")
      (cl-dataflow:make-transition "payment-requested" "order-confirmed" "order-confirmed"))))

(defun make-workflow-stage (name event)
  (cl-dataflow:make-node
    name
    :handler (lambda (input context)
               (cl-dataflow:emit-event context event :payload input)
               (cl-dataflow:step-state-machine *machine* event :context context)
               input)))

(defparameter *workflow*
  (cl-dataflow:make-pipeline
    :stages (list (make-workflow-stage "create-order" "order-created")
                  (make-workflow-stage "reserve-inventory" "reserve-inventory")
                  (make-workflow-stage "request-payment" "payment-requested")
                  (make-workflow-stage "confirm-order" "order-confirmed"))))

(defparameter *context*
  (cl-dataflow:run-pipeline-with-test-context
    *workflow*
    :input '(:order-id "A-100")
    :state (cl-dataflow:state-machine-state *machine*)))

(cl-dataflow:context-state *context*)
;; => "order-confirmed"

(mapcar #'cl-dataflow:event-type
        (nreverse (cl-dataflow:context-events *context*)))
;; => ("order-created" "reserve-inventory" "payment-requested" "order-confirmed")
```

Run it directly:

```bash
sbcl --script examples/event-workflow.lisp
```

## Where to go next

- [Core Concepts](core-concepts.md) names every object in the snippets above.
- [Pipelines and Workflows](pipelines.md) covers branching, feedback iteration
  (`run-pipeline-times`/`-until-fixpoint`/`-while`), and `define-workflow`.
- [Graphs](graphs.md) and [Graph Algorithms](graph-algorithms.md) cover the
  dependency-graph half of the library used above via `define-pipeline`'s
  `:edge` forms.
- [Examples](examples.md) lists every runnable script under `examples/`,
  including a full pipeline + streams + reactive + state-machine integration
  scenario.
