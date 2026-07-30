# State Machines

A `state-machine` is a small guarded transition model: a current state, an
initial state, an ordered list of `state-transition`s, a bounded history of
past transitions, and free-form metadata. `step-state-machine` is the reducer
at its core — feed it an event, get back the machine and a transition record —
and everything else on this page (introspection, analysis, serialization,
pipeline embedding) is built on top of that one operation.

## Defining a machine

`make-transition` builds a single `from event-type to` edge, with optional
`:guard`, `:action`, and `:metadata`:

```lisp
(cl-dataflow:make-transition "idle" "start" "running"
  :action (lambda (machine event context)
            (declare (ignore machine event context))
            (values "running" '(:note "entered running"))))
```

An action receives `(machine event context)` and may return two values: an
overriding next-state (used instead of the transition's `:to` when non-nil)
and an arbitrary result value that ends up in the transition record's
`:action-result`. A guard has the same argument list and must return true for
the transition to be selected; when several transitions share a `(state,
event-type)` pair, the first one whose guard passes wins, in definition
order.

`make-state-machine` assembles transitions into a machine. You must supply
`:state`, `:initial-state`, or both — if you give only `:state` it is also
used as the initial state, and vice versa:

```lisp
(defparameter *machine*
  (cl-dataflow:make-state-machine
    :state "idle"
    :transitions
    (list
      (cl-dataflow:make-transition
        "idle" "start" "running"
        :action (lambda (machine event context)
                  (declare (ignore machine event context))
                  (values "running" '(:note "entered running"))))
      (cl-dataflow:make-transition "running" "complete" "completed"))))
```

(Adapted from `examples/state-machine.lisp`.)

For a more declarative flavor, `define-state-machine` expands each `(from
event to &key guard action metadata)` clause into a `make-transition` call
and wraps the whole thing in `make-state-machine`:

```lisp
(defparameter *review-machine*
  (cl-dataflow:define-state-machine (:state "draft")
    ("draft" "submit" "review")
    ("review" "approve" "shipped")
    ("review" "reject" "cancelled")))
```

The definition-level options are `:state`, `:initial-state`, `:history`,
`:history-limit`, and `:metadata`; each transition clause accepts `:guard`,
`:action`, and `:metadata`. Both forms produce a plain `state-machine` value
— there is no special macro-only representation to unwrap. Anything else in
either position is rejected at macroexpansion time with `invalid-input-error`.

### Readers and predicates

`state-machine-p` and `state-transition-p` are the type predicates for the two
classes `state-machine` and `state-transition`. A transition exposes
`transition-from`, `transition-event-type`, `transition-to`,
`transition-guard`, `transition-action`, and `transition-metadata`; a machine
exposes `state-machine-state`, `state-machine-initial-state`,
`state-machine-transitions`, `state-machine-history`,
`state-machine-history-limit`, and `state-machine-metadata`.

`state-machine-transitions` hands back *copies*, so mutating what it returns
does not change the machine — use `add-transition`/`remove-transition`, or
`(setf state-machine-transitions)`, which re-copies the list and rebuilds the
internal lookup index in lock-step.

State and event names are normalized the same way node names are: strings pass
through unchanged and symbols become their (upcased) symbol name. Transition
lookup then compares case-insensitively, so both `"submit"` and `'submit`
select a transition declared as `"submit"` — though a symbol event is recorded
in the transition record as `:event-type "SUBMIT"`.

## Stepping

`step-state-machine` is the reducer: given a machine, an event (a string,
symbol, or full `event` object), and an optional `:context`, it finds the
matching transition, runs its action, updates the machine's state in place,
and returns `(values machine transition-record)`:

```lisp
(cl-dataflow:step-state-machine
  (cl-dataflow:make-state-machine
    :state "idle"
    :transitions (list (cl-dataflow:make-transition "idle" "start" "running")))
  "start")
;; => #<STATE-MACHINE ...>, (:FROM "idle" :EVENT-TYPE "start" :TO "running"
;;                            :STATE-BEFORE "idle" :GUARD-PASSED T
;;                            :ACTION-RESULT NIL)
```

When you pass `:context`, stepping also updates `context-state` and appends a
copy of the transition record to `context-trace` — this is what "a state
machine behaves like a reducer inside pipeline and workflow code" (see
[Core Concepts](core-concepts.md)) means in practice. `run-state-machine`
drives a sequence of events through `step-state-machine`, returning
`(values machine transition-records)`. `run-state-machine-with-context` adds
context management: omit `:context` and it seeds a fresh one from the
machine's current state; either way it returns `(values machine
transition-records context)` with `context-state` synchronized to the final
state:

```lisp
(defparameter *context*
  (cl-dataflow:make-context :state (cl-dataflow:state-machine-state *machine*)))

(multiple-value-bind (updated-machine transition-records updated-context)
    (cl-dataflow:run-state-machine-with-context
      *machine* '("start" "complete") :context *context*)
  (declare (ignore updated-machine))
  (cl-dataflow:context-state updated-context))
;; => "completed"
```

(This is `examples/state-machine.lisp` end to end; `*machine*` itself is now
sitting in state `"completed"`, since `step-state-machine` mutates its
argument.) If a transition fails — no matching `(state, event-type)` pair, or
every candidate's guard rejects the event — `step-state-machine` signals
`invalid-transition-error` or `guard-failed-error` rather than silently
no-opping.

## Introspecting the control surface

`state-machine-available-transitions` lists every transition out of a state
— the current state by default, or any state via `:state`:

```lisp
(cl-dataflow:state-machine-available-transitions *review-machine*)
;; => (#<STATE-TRANSITION draft --submit--> review>)

(cl-dataflow:state-machine-available-transitions *review-machine* :state "review")
;; => (#<STATE-TRANSITION review --approve--> shipped>
;;     #<STATE-TRANSITION review --reject--> cancelled>)
```

`state-machine-can-step-p` preflights a single event without mutating
anything, and accepts `:context` so guards that inspect context data see the
same runtime state they would see during a real step:

```lisp
(cl-dataflow:state-machine-can-step-p *review-machine* "submit")
;; => T
(cl-dataflow:state-machine-can-step-p *review-machine* "bogus")
;; => NIL
```

## Lifecycle: copying, resetting, and history

`reset-state-machine` snaps a machine's current state back to its initial
state, in place — it only touches `state-machine-state`, so accumulated
`state-machine-history` survives a reset untouched:

```lisp
(cl-dataflow:reset-state-machine *machine*)
(cl-dataflow:state-machine-state *machine*)
;; => "idle"
(length (cl-dataflow:state-machine-history *machine*))
;; => 2  ; the "start" and "complete" records from run-state-machine-with-context
```

`copy-state-machine` clones everything a machine carries — current state,
initial state, transitions, history, history limit, and metadata — into an
independent value, so you can fork a machine and let each copy evolve on its
own without touching the original:

```lisp
(defparameter *scratch* (cl-dataflow:copy-state-machine *machine*))
(cl-dataflow:step-state-machine *scratch* "start")
(cl-dataflow:state-machine-state *scratch*)
;; => "running"
(cl-dataflow:state-machine-state *machine*)
;; => "idle"  ; unaffected
```

`state-machine-history` returns the ordered list of transition records (most
recent first), bounded by `state-machine-history-limit` (`nil` means
unbounded; `0` disables history entirely; any other value must be a
non-negative integer, or `make-state-machine` signals `invalid-input-error`).
`state-machine-last-transition` is a convenience reader for the most recent
record, or `nil` if the machine has never stepped:

```lisp
(cl-dataflow:state-machine-last-transition *machine*)
;; => (:FROM "running" :EVENT-TYPE "complete" :TO "completed"
;;     :STATE-BEFORE "running" :GUARD-PASSED T :ACTION-RESULT NIL)
```

## Embedding in pipelines

`make-state-machine-node` turns a state machine into an ordinary pipeline
stage (a `node`), so it can sit inside a `define-pipeline`/`define-workflow`
graph alongside any other stage. `:event-fn` computes the event to step with
from `(input context)` — it may return an event designator (string/symbol) or
a full `event` object; when omitted, the stage's input is used directly as
the event. `:result-fn` computes the stage's output from
`(updated-machine event input context)`; when omitted, the stage's output is
the machine's new state. The resulting node has a single `"value"` output port
and defaults to the name `"state-machine"`; `:metadata` is attached to the node
unchanged. The stage passes its runtime context down into `step-state-machine`
only when it really is a `context`, so guards and actions see the same context
the surrounding pipeline is threading:

```lisp
(cl-dataflow:make-state-machine-node
  *machine*
  :name "order-transition"
  :event-fn (lambda (input context)
              (declare (ignore context))
              (getf input :event))
  :result-fn (lambda (updated-machine event input context)
               (declare (ignore event input context))
               (cl-dataflow:state-machine-state updated-machine)))
```

`examples/event-workflow.lisp` shows the complementary hand-rolled pattern —
a plain node handler that calls `emit-event` and `step-state-machine`
directly — which is exactly what `make-state-machine-node` packages up as a
reusable stage. See [Pipelines and Workflows](pipelines.md) for
`define-workflow`, which unifies graph edges, transitions, and machine nodes
in one macro expansion.

## See also

- [State Machine Analysis](state-machine-analysis.md) — analyzing a
  machine's reachability and structure, replaying event sequences,
  serializing and mutating its transitions, and bridging it into the graph
  toolkit.
- [Pipelines and Workflows](pipelines.md) — `define-workflow`, which unifies
  graph edges, transitions, and machine nodes in one macro expansion.
- [Events and Effects](events-and-effects.md) — emitting events alongside a
  workflow's state transitions.
- [Public API Reference](api-reference.md) — the full reader/predicate list
  for `state-machine` and `state-transition`.
