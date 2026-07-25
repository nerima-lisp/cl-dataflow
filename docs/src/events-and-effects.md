# Events and Effects

Every pipeline run accumulates two parallel logs on its `context`: **events**,
which record that something happened, and **effects**, which record a
tracked side effect and its result. Both logs feed the same unified
`context-trace`, so a workflow's history can always be replayed in the exact
order events, effects, and state-machine transitions occurred. This page
covers the construction, emission, and handler APIs for both; see
[Core Concepts](core-concepts.md) for how they fit alongside contexts and
pipelines, and [Pipelines and Workflows](pipelines.md) and
[State Machines](state-machines.md) for how a stage handler typically emits
an event and steps a state machine in the same call.

## Events

An `event` is a plain record: a normalized type, a payload, metadata, and the
trace index it was recorded at.

- `make-event` — construct an `event` directly, without touching any
  context. Useful for tests and for building a batch of events to compare
  against later.
- `copy-event` — an explicit clone helper; independent of the source event.
- `emit-event` — the workhorse. Given a `context`, a type, and optional
  `:payload`/`:metadata`, it constructs the event, appends a copy to the
  context's event log, appends an entry to `context-trace`, and returns the
  event.
- Accessors: `event-type`, `event-payload`, `event-metadata`,
  `event-trace-index`.

```lisp
(let ((context (cl-dataflow:make-context)))
  (cl-dataflow:emit-event context "order-created" :payload '(:order-id "A-100"))
  (cl-dataflow:emit-event context :inventory-reserved :payload '(:sku "WIDGET-1"))
  (mapcar #'cl-dataflow:event-type
          (nreverse (cl-dataflow:context-events context))))
;; => ("order-created" "inventory-reserved")
```

Event types are normalized the same way node and port names are: strings
pass through as-is, symbols become their `symbol-name`, and other designators
are stringified under a fixed printer configuration. `:inventory-reserved`
above becomes `"INVENTORY-RESERVED"` — event types are *not* lowercased the
way effect handler keys are (see [Key normalization](#key-normalization)
below), so pick a consistent case convention for event type designators
across a workflow.

### Batch emission with `emit-events`

`emit-events` takes a `context` and a list of specs, emitting one event per
spec in order and returning the list of resulting events. Each spec is
either a bare type designator or a `(type &key payload metadata)` list:

```lisp
(cl-dataflow:emit-events
  context
  '("order-created"
    ("inventory-reserved" :payload (:sku "WIDGET-1"))
    ("payment-requested" :payload (:amount 42) :metadata (:currency "USD"))))
```

This is useful when a stage handler needs to declare a fixed sequence of
occurrences up front, rather than calling `emit-event` once per line.

### `event-of-type-p`

`event-of-type-p` compares an event's type against a designator after
normalization, so callers do not need to normalize the comparison type
themselves:

```lisp
(let ((event (cl-dataflow:make-event :order-created)))
  (cl-dataflow:event-of-type-p event "ORDER-CREATED"))
;; => T
```

## Effects

An `effect` looks like an event — normalized type, payload, metadata, trace
index — plus one more field: `effect-result`, filled in once a handler runs.

- `make-effect` — construct an `effect` directly, optionally supplying
  `:result` up front (mainly useful for building comparison snapshots in
  tests).
- `copy-effect` — an explicit clone helper.
- `perform-effect` — given a `context`, a type, and optional
  `:payload`/`:metadata`, looks up the handler registered for that type on
  the context, records a trace entry, calls the handler as `(handler effect
  context)`, stores its return value into `effect-result`, appends a copy of
  the effect to the context's effect log, and returns the effect.
- Accessors: `effect-type`, `effect-payload`, `effect-metadata`,
  `effect-trace-index`, `effect-result`.

```lisp
(let ((context (cl-dataflow:make-context)))
  (cl-dataflow:register-effect-handler
    context "charge-card"
    (lambda (effect context)
      (declare (ignore context))
      (list :charged (getf (cl-dataflow:effect-payload effect) :amount))))
  (let ((effect (cl-dataflow:perform-effect
                  context "charge-card" :payload '(:amount 42))))
    (cl-dataflow:effect-result effect)))
;; => (:charged 42)
```

If no handler is registered for the effect's (normalized) type,
`perform-effect` signals `effect-handler-missing-error` rather than silently
skipping the effect or returning `nil`. The condition carries
`missing-effect-type` (the normalized type that had no handler) and
`effect-handler-missing-effect` (a copied snapshot of the effect that
triggered the failure, so the caller can inspect its payload after the
fact). See [Public API Reference](api-reference.md) for the full condition
hierarchy and its readers.

### Batch execution with `perform-effects`

`perform-effects` mirrors `emit-events`: given a `context` and a list of
specs (bare type or `(type &key payload metadata)`), it performs one effect
per spec in order and returns the list of resulting effects. Every effect
type in the list must already have a registered handler, or the batch stops
at the first `effect-handler-missing-error`.

```lisp
(cl-dataflow:perform-effects
  context
  '(("charge-card" :payload (:amount 42))
    ("send-receipt" :payload (:to "buyer@example.com"))))
```

### Inspecting results: `effect-of-type-p`, `context-effect-results`

`effect-of-type-p` is the effect-side twin of `event-of-type-p`. Two more
helpers read results back off a context after a run:

- `context-effect-results` — the `effect-result` of every effect performed
  on the context, in chronological order.
- `context-effect-results-of-type` — the same, filtered to one effect type.

```lisp
(cl-dataflow:context-effect-results-of-type context "charge-card")
;; => ((:charged 42))
```

## Effect handler ergonomics

Effect handlers live in a hash table on the context, reachable through
`context-effect-handlers`. That reader is intentionally the one *mutable*
collection reader in the library — it returns the live table (not a
snapshot), so callers can register handlers directly through it, and
`copy-context` clones the table so a forked context can diverge without
cross-talk with the original.

Rebuilding the whole handler table just to add one handler is awkward, so
`src/effects-ext.lisp` adds direct register/lookup/scope helpers on top of
that table:

- `register-effect-handler` — register a single `(effect context)` handler
  for a type on a context, mutating the table in place, and return the
  handler. Registering a handler for a type that already has one replaces
  it.
- `context-effect-handler` — look up the handler registered for a type, or
  `nil` if none is.
- `effect-handled-p` — a predicate: does this context have a handler for
  this type at all? (Distinguishes "no handler" from "handler that returns
  `nil`", since it checks hash-table presence rather than the value.)
- `context-effect-handler-types` — the normalized types this context has
  handlers for, sorted lexicographically. Handy for asserting a context is
  fully wired before running a pipeline.

```lisp
(let ((context (cl-dataflow:make-context)))
  (cl-dataflow:register-effect-handler
    context :log (lambda (effect context)
                   (declare (ignore context))
                   (format nil "LOG: ~A" (cl-dataflow:effect-payload effect))))
  (cl-dataflow:effect-handled-p context "log")
  ;; => T
  (cl-dataflow:context-effect-handler-types context))
;; => ("log")
```

### Key normalization

Effect handler keys are normalized to lowercase strings via the same
mechanism `perform-effect` uses to resolve a handler, so `:log`, `'LOG`, and
`"log"` all collide on the identical key. Register with one spelling and
perform with another, and it still resolves:

```lisp
(let ((context (cl-dataflow:make-context)))
  (cl-dataflow:register-effect-handler
    context 'LOG (lambda (effect context)
                   (declare (ignore context))
                   (cl-dataflow:effect-payload effect)))
  (cl-dataflow:perform-effect context "log" :payload "booted"))
;; effect-result => "booted"
```

This is distinct from event types (see above), which are normalized for
identity/display but are *not* lowercased — only effect handler keys go
through the case-folding step, because they exist purely to dispatch to a
registered function rather than to be displayed or compared as workflow
data.

### Scoping handlers with `with-effect-handler-scope`

Registering a handler with `register-effect-handler` mutates the context for
the rest of its lifetime. `with-effect-handler-scope` is the scoped
alternative: it registers a set of `(type handler)` bindings, evaluates a
body, and restores the context's *entire* handler table to what it was
before the scope — even on a non-local exit (a thrown condition, a
`return-from`, etc.) — via `unwind-protect`.

```lisp
(let ((context (cl-dataflow:make-context)))
  (cl-dataflow:register-effect-handler
    context "log" (lambda (effect context)
                    (declare (ignore context))
                    (list :production-log (cl-dataflow:effect-payload effect))))
  (let ((result
          (cl-dataflow:with-effect-handler-scope
              (context
                ("log" (lambda (effect context)
                         (declare (ignore context))
                         (list :test-log (cl-dataflow:effect-payload effect))))
                ("notify" (lambda (effect context)
                            (declare (ignore context))
                            (list :notified (cl-dataflow:effect-payload effect)))))
            (list (cl-dataflow:effect-result
                    (cl-dataflow:perform-effect context "log" :payload "inside scope"))
                  (cl-dataflow:effect-result
                    (cl-dataflow:perform-effect context "notify" :payload "hello"))))))
    (list :inside-scope result
          ;; Outside the scope, "log" is back to the production handler and
          ;; "notify" has no handler at all again.
          :after-scope (cl-dataflow:effect-result
                         (cl-dataflow:perform-effect context "log" :payload "after scope")))))
;; :inside-scope  => ((:test-log "inside scope") (:notified "hello"))
;; :after-scope   => (:production-log "after scope")
```

`with-effect-handler-scope` is a good fit for tests that need a temporary
stub handler, or for a workflow branch that should route an effect type
differently only for its own duration.

## Events and effects inside a pipeline stage

A node handler receives `(input context)`, and since it holds the same
`context` the whole run shares, it can call `emit-event` and `perform-effect`
directly. This is the pattern `examples/event-workflow.lisp` uses to model
an order workflow: each stage emits an event for what just happened, then
steps a `state-machine` with that same event type, so the context's state
and event log stay in lockstep with the pipeline's progress:

```lisp
(defun make-workflow-stage (name event-type machine)
  (cl-dataflow:make-node
    name
    :handler (lambda (input context)
               (cl-dataflow:emit-event context event-type :payload input)
               (cl-dataflow:step-state-machine machine event-type :context context)
               input)))
```

A stage that also needs to talk to the outside world — charging a card,
sending a notification — reaches for `perform-effect` instead (or in
addition), routing through whatever handler the surrounding context has
registered via `register-effect-handler` or `with-effect-handler-scope`.
Because handler lookup happens through the context rather than being baked
into the pipeline graph, the same graph can run once against a production
context wired to real handlers, and again in a test against a context whose
handlers are stubs — see [Pipelines and Workflows](pipelines.md) for how a
full pipeline run threads a context through every stage, and
[State Machines](state-machines.md) for the transition side of this pattern.

## See also

- [Public API Reference](api-reference.md) lists every event, effect, batch,
  and ergonomics symbol, plus the full `effect-handler-missing-error`
  condition hierarchy.
- [Core Concepts](core-concepts.md) introduces `context` and its other
  collection readers.
- [Observability and Serialization](observability.md) covers
  `event-to-plist`/`plist-to-event`, `effect-to-plist`/`plist-to-effect`, and
  `format-trace` for rendering the combined event/effect/transition trace.
