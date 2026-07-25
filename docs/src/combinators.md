# Combinators and Resilience

A node handler is an ordinary `(input context)` function, so behaviours like
retry, fallback, and memoisation are expressed the same way any Lisp function
transformation is expressed: as **handler → handler** wrappers. `cl-dataflow`
builds two layers on this idea:

- **Handler combinators** operate on a bare handler function. Use them when
  assembling a handler by hand, before it is ever attached to a node.
- **Node wrappers** operate on a whole `node`, re-wrapping whatever handler it
  already has (via `wrap-node`). Use them once you already have a `node` —
  from `make-node` or a `define-pipeline` `:node` form — and just want to
  layer resilience onto it without rewriting its logic.

On top of both, **node contracts** turn a bad input or output value into an
explicit, inspectable failure at the node boundary instead of letting it
propagate silently. All of the symbols on this page live in
`src/combinators.lisp` and `src/contracts.lisp`.

## Handler combinators

These functions take one or more handlers (or a plain function) and return a
new handler — a closure of `(input context)`.

### `mapping-handler`

Adapts a unary function into a handler that ignores the context:

```lisp
(cl-dataflow:mapping-handler (lambda (x) (* x 2)))
;; => a handler equivalent to (lambda (input context) (declare (ignore context)) (* input 2))
```

Use this whenever the transformation you want to run doesn't need the
context at all — it's the bridge between "plain function" and "node handler".

### `compose-handlers`

Threads a single input through a sequence of handlers, left to right, passing
the same context to each step:

```lisp
(defparameter *double* (cl-dataflow:mapping-handler (lambda (x) (* x 2))))
(defparameter *increment* (cl-dataflow:mapping-handler (lambda (x) (+ x 1))))

(funcall (cl-dataflow:compose-handlers *double* *increment*) 20 nil)
;; => 41
```

With no handlers, `compose-handlers` is the identity. This is the handler-level
analogue of chaining pipelines with `run-pipeline-sequence` (see
[Pipelines and Workflows](pipelines.md)) — reach for `compose-handlers` when
you're building one handler in code, and for `run-pipeline-sequence` when you
have several already-built pipelines to run in order.

### `retrying-handler`

Retries a handler when it signals a condition of a given type, up to a fixed
number of total invocations:

```lisp
(defparameter *attempts* 0)
(defparameter *flaky*
  (lambda (input context)
    (declare (ignore context))
    (incf *attempts*)
    (if (< *attempts* 3)
        (error "transient failure")
        (* input 10))))

(funcall (cl-dataflow:retrying-handler *flaky* :attempts 5) 7 nil)
;; => 70, after 3 attempts
```

`:attempts` (default `3`) is the total number of invocations, not the number
of *re*-tries. `:condition-type` (default `error`) restricts which conditions
are retried; anything outside that type re-signals immediately. Once
`:attempts` is exhausted the last failure is re-signalled rather than
swallowed.
`retrying-handler` requires at least one attempt — passing `:attempts 0` or
lower signals `invalid-input-error`.

### `fallback-handler`

Turns a signalled condition into a safe result instead of propagating it:

```lisp
(defparameter *risky*
  (lambda (input context)
    (declare (ignore context))
    (if (evenp input) (* input 100) (error "odd input"))))

(funcall (cl-dataflow:fallback-handler *risky* -1) 4 nil)  ;; => 400
(funcall (cl-dataflow:fallback-handler *risky* -1) 3 nil)  ;; => -1
```

`fallback` can be a plain value (returned verbatim) or a function called with
`(input context condition)` so the fallback can inspect what went wrong.
`:condition-type` scopes which conditions are caught; anything else still
propagates.

### `memoizing-handler`

Wraps a handler with a cache keyed by `(funcall key input)` under a given
equality `test` (defaults to `equal` and `#'identity`). A repeated key returns
the cached result without re-invoking the handler:

```lisp
(defparameter *calls* 0)
(defparameter *memoized*
  (cl-dataflow:memoizing-handler
   (lambda (input context)
     (declare (ignore context))
     (incf *calls*)
     (* input input))))

(funcall *memoized* 6 nil)
(funcall *memoized* 6 nil)
*calls*
;; => 1
```

The cache lives inside the returned closure, so two separate calls to
`memoizing-handler` never share state.

### `tapping-handler`

Runs a side effect after the wrapped handler, without altering the data flow:

```lisp
(defparameter *log* nil)
(defparameter *logging-double*
  (cl-dataflow:tapping-handler
   (cl-dataflow:mapping-handler (lambda (x) (* x 2)))
   (lambda (input output context)
     (declare (ignore context))
     (push (list input output) *log*))))

(funcall *logging-double* 21 nil)
;; => 42, and *log* now holds ((21 42))
```

`side-effect` is called with `(input output context)`; its return value is
discarded, and the handler's own output is returned unchanged. This is the
natural place to hang logging or metrics onto a handler without touching its
logic.

## Node wrappers

Node wrappers take a whole `node` and return a fresh `node` with the same
name, inputs, outputs, and metadata, but a re-wrapped handler. They are what
you reach for once you already have a node — built with `make-node` or
declared inside a `define-pipeline` `:node` form — and just want to layer
resilience onto its existing behaviour.

### `wrap-node`

The general building block underneath every other node wrapper:

```lisp
(cl-dataflow:wrap-node node
                       (lambda (handler)
                         (cl-dataflow:retrying-handler handler :attempts 3)))
```

`wrap-node` calls `wrapper` with `(node-handler node)` and installs the result
as the new handler. The returned node is not attached to any graph, so you
still call `add-node` (or reference it from a `define-pipeline` form) to use
it. Use `wrap-node` directly whenever you need a combination the built-in
wrappers below don't cover — for example, composing `retrying-handler` and
`fallback-handler` together in one wrapper function.

### `node-with-retry`, `node-with-fallback`, `node-with-memoization`, `node-with-tap`

Each of these is a thin, named convenience over `wrap-node` plus the matching
handler combinator:

| Node wrapper | Delegates to |
| --- | --- |
| `node-with-retry` | `retrying-handler` |
| `node-with-fallback` | `fallback-handler` |
| `node-with-memoization` | `memoizing-handler` |
| `node-with-tap` | `tapping-handler` |

```lisp
(cl-dataflow:node-with-retry node :attempts 5 :condition-type 'error)
(cl-dataflow:node-with-fallback node -1 :condition-type 'error)
(cl-dataflow:node-with-memoization node :test 'equal :key #'identity)
(cl-dataflow:node-with-tap node (lambda (input output context)
                                  (declare (ignore context))
                                  (format t "~D -> ~D~%" input output)))
```

Each returns a fresh node — the original is left untouched — so you can add
either the wrapped node or the original to different graphs.

## Node contracts

A **contract** is a pair of predicates attached to a handler: `before` checks
the input, `after` checks the output. A violation signals
`invalid-input-error` with the offending value attached, instead of letting a
bad value flow silently into the rest of the pipeline.

### `contract-handler`

```lisp
(defparameter *guarded*
  (cl-dataflow:contract-handler
   (cl-dataflow:mapping-handler #'sqrt)
   :before (lambda (input) (and (numberp input) (>= input 0)))
   :after (lambda (output) (realp output))))

(funcall *guarded* 16 nil)   ;; => 4.0
(funcall *guarded* -4 nil)   ;; signals INVALID-INPUT-ERROR
```

A `nil` predicate is skipped, so you can supply only `:before`, only `:after`,
or both. When `before` fails, `invalid-input-error` carries
`invalid-input-expected` bound to `valid-node-input`; when `after` fails, it
carries `valid-node-output`. In both cases `invalid-input-value` holds the
offending value (the raw input or the raw output) and `invalid-input-detail`
holds a human-readable string — the standard triple documented in the
[README's error reference](https://github.com/nerima-lisp/cl-dataflow#public-api-reference):
`invalid-input-error`, `invalid-input-expected`, `invalid-input-value`,
`invalid-input-detail`.

### `node-with-contract`

The node-level counterpart, following the same `wrap-node` pattern as the
resilience wrappers above:

```lisp
(defparameter *contracted-node*
  (cl-dataflow:node-with-contract node
                                  :before #'plusp
                                  :after #'realp))
```

Because contracts are enforced by wrapping the handler, they compose cleanly
with retry, fallback, memoization, and tap — apply `node-with-contract`
outermost to validate the values crossing the node boundary regardless of
what resilience machinery runs inside.

## Worked example: retry and fallback in a pipeline

This example is adapted from `examples/resilient-pipeline.lisp`, which is
runnable directly with `sbcl --script examples/resilient-pipeline.lisp`.

A flaky handler fails on its first two invocations, then succeeds.
`node-with-retry` keeps calling it until it does:

```lisp
(defparameter *attempts* 0)
(defparameter *flaky*
  (cl-dataflow:make-node "fetch"
    :handler (lambda (input context)
               (declare (ignore context))
               (incf *attempts*)
               (if (< *attempts* 3)
                   (error "transient failure")
                   (* input 10)))))

(defparameter *retry-graph* (cl-dataflow:make-graph))
(cl-dataflow:add-node *retry-graph*
                      (cl-dataflow:node-with-retry *flaky* :attempts 5))

(cl-dataflow:run-pipeline (cl-dataflow:make-pipeline :graph *retry-graph*)
                          :input 7)
;; => 70, after 3 attempts
```

A separate, risky handler fails on odd input. `node-with-fallback` turns that
failure into a safe default instead of propagating it:

```lisp
(defparameter *risky*
  (cl-dataflow:make-node "risky"
    :handler (lambda (input context)
               (declare (ignore context))
               (if (evenp input) (* input 100) (error "odd input")))))

(defparameter *fallback-graph* (cl-dataflow:make-graph))
(cl-dataflow:add-node *fallback-graph*
                      (cl-dataflow:node-with-fallback *risky* -1))

(let ((pipeline (cl-dataflow:make-pipeline :graph *fallback-graph*)))
  (cl-dataflow:run-pipeline pipeline :input 4)   ;; => 400
  (cl-dataflow:run-pipeline pipeline :input 3))  ;; => -1
```

Finally, two single-node pipelines are threaded together with
`run-pipeline-sequence`, which feeds one pipeline's result into the next as
its input and accumulates events, effects, and trace onto one shared context:

```lisp
(defun single-node-pipeline (name function)
  (let ((graph (cl-dataflow:make-graph)))
    (cl-dataflow:add-node graph
                          (cl-dataflow:make-node name
                            :handler (cl-dataflow:mapping-handler function)))
    (cl-dataflow:make-pipeline :graph graph)))

(let ((double (single-node-pipeline "double" (lambda (x) (* x 2))))
      (increment (single-node-pipeline "increment" (lambda (x) (+ x 1)))))
  (cl-dataflow:run-pipeline-sequence (list double increment) :input 20))
;; => (VALUES 41 #<CONTEXT ...>)
```

`run-pipeline-sequence` is a pipeline-level combinator rather than a
handler/node one — see [Pipelines and Workflows](pipelines.md) for its full
`(values final-result context)` contract, including how it creates a shared
context when none is supplied and how an empty pipeline list is handled.

## Choosing a combinator vs. a node wrapper

- **Building a handler by hand?** Reach for a handler combinator
  (`retrying-handler`, `fallback-handler`, `memoizing-handler`,
  `tapping-handler`, `compose-handlers`, `mapping-handler`) — they compose
  directly around a `(input context)` function before it is ever attached to
  a node.
- **Already have a node?** Reach for the matching node wrapper
  (`node-with-retry`, `node-with-fallback`, `node-with-memoization`,
  `node-with-tap`, `node-with-contract`, or `wrap-node` for anything custom).
  These are exactly what you attach in a `define-pipeline` `:node` form, or
  apply to a node returned by `make-node`, since they already know how to
  read and replace that node's existing handler.
- **Need to validate values at the node boundary?** Reach for
  `node-with-contract` (or `contract-handler` for a bare handler) so a bad
  input or output fails loudly, with the offending value attached to
  `invalid-input-error`, instead of drifting silently downstream.

See the [Public API Reference](api-reference.md) for the full symbol list, and
[Pipelines and Workflows](pipelines.md) for how `run-pipeline-sequence` fits
into pipeline-level composition.
