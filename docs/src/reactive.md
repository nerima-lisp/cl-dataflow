# Reactive Subjects (Push)

A `subject` is a producer-driven, push-based event source: values arrive when
something calls `subject-emit`, and every subscriber is notified synchronously,
in subscription order, before `subject-emit` returns. There is no thread pool,
no scheduler, and no laziness — a subject is fully deterministic and
thread-free, which makes it a good fit for event-driven workflows where you
want to react to values as they happen rather than pull them on demand.

This is the push-side counterpart to the pull-based `flow-stream` covered in
[Streams (Pull)](streams.md). A stream is consumer-driven — nothing happens
until something asks for the next element — while a subject is
producer-driven: emission is the only thing that moves values through the
graph. Most subject operators have a stream operator with matching semantics,
just flipped from "pull the next value" to "react to the next emission"; this
page frames each one as the push-side dual of its stream counterpart where one
exists. See [Core Concepts](core-concepts.md) for the library's other
primitives, and the [Public API Reference](api-reference.md) for the full
exported symbol list (`Reactive subject APIs` and `Reactive operator APIs`).

## What a subject is

`make-subject` creates a fresh subject with no subscribers. `subject-p` tests
whether a value is one:

```lisp
(defparameter *orders* (cl-dataflow:make-subject))

(cl-dataflow:subject-p *orders*)
;; => T
```

A subject is opaque — there is no reader for its internal subscriber list.
Everything else in this page (`subject-subscribe`, `subject-emit`, and the
derived/stateful operators) is the public surface for building and driving
one.

## Subscription lifecycle

`subject-subscribe` registers a function of one argument (the emitted value)
as a subscriber, after any existing subscribers, and returns that function —
which doubles as an unsubscribe token:

```lisp
(defparameter *seen* '())

(defparameter *handler*
  (cl-dataflow:subject-subscribe
    *orders*
    (lambda (value) (push value *seen*))))

(cl-dataflow:subject-subscriber-count *orders*)
;; => 1
```

`subject-unsubscribe` removes a function from a subject's subscribers (every
occurrence of it, if it was registered more than once) and returns the
subject:

```lisp
(cl-dataflow:subject-unsubscribe *orders* *handler*)
(cl-dataflow:subject-subscriber-count *orders*)
;; => 0
```

`subject-subscriber-count` is a plain count of currently registered
subscribers — handy for asserting that setup/teardown wiring behaved as
expected.

## Emission

`subject-emit` pushes a value to every subscriber present when the call
starts, synchronously and in the order they subscribed, then returns the
subject:

```lisp
(cl-dataflow:subject-subscribe *orders* (lambda (value) (push value *seen*)))
(cl-dataflow:subject-emit *orders* 42)
*seen*
;; => (42)
```

The set of subscribers notified by a given `subject-emit` call is a
**snapshot** taken at the start of that call. If a subscriber function itself
subscribes or unsubscribes another handler (or the same one) while it runs,
that change is visible to reentrant and later emissions, but never disturbs
the emission currently in progress — the pass that already started keeps
notifying exactly the subscribers it started with.

There is no consumer-driven equivalent of `subject-emit` on the stream side:
a stream only produces a value when something pulls it. A subject inverts
that — nothing is pulled, everything is pushed the moment `subject-emit`
runs.

## Derived subjects

`subject-map` and `subject-filter` build a new subject that subscribes to a
source subject and re-emits a transformed view of it — the push duals of
`stream-map` and `stream-filter`:

```lisp
(defparameter *priced* (cl-dataflow:make-subject))

(defparameter *doubled* (cl-dataflow:subject-map *priced* (lambda (v) (* v 2))))
(defparameter *big* (cl-dataflow:subject-filter *priced* (lambda (v) (> v 50))))

(cl-dataflow:subject-subscribe *doubled* (lambda (v) (format t "~&doubled: ~D~%" v)))
(cl-dataflow:subject-subscribe *big* (lambda (v) (format t "~&big: ~D~%" v)))

(cl-dataflow:subject-emit *priced* 30)
;; prints: doubled: 60
(cl-dataflow:subject-emit *priced* 70)
;; prints: doubled: 140
;;         big: 70
```

`subject-merge` takes any number of source subjects and returns one derived
subject that emits whenever *any* of them emits — the push dual of
`stream-concat`, though unlike concatenation there is no ordering by source:
whichever source subject emits first drives the next value through:

```lisp
(defparameter *web-orders* (cl-dataflow:make-subject))
(defparameter *phone-orders* (cl-dataflow:make-subject))
(defparameter *all-orders* (cl-dataflow:subject-merge *web-orders* *phone-orders*))
```

Because derived subjects are themselves ordinary subjects, they compose:
`(subject-filter (subject-map source #'f) #'p)` is a small reactive pipeline
built out of two subscriptions.

## Inspecting emissions

`subject-collect` subscribes a collector to a subject and returns a function
of no arguments that yields every value the subject has emitted since, in
emission order:

```lisp
(defparameter *alerts* (cl-dataflow:subject-collect *big*))

(cl-dataflow:subject-emit *priced* 10)
(cl-dataflow:subject-emit *priced* 99)
(funcall *alerts*)
;; => (70 99)
```

`:limit` bounds how many values are retained, and `:on-limit` controls what
happens once the limit is reached — `:error` (the default) signals from the
`subject-emit` call that would exceed it, `:drop-newest` silently ignores
values past the limit instead. This mirrors the `limit`/`on-limit` keywords
that bound `stream-collect` and friends on the pull side.

## Stateful and combining operators

`src/reactive-ops.lisp` layers stateful, single-source operators and
multi-source combinators on top of the core subject API, bringing the push
side to parity with the pull-stream vocabulary. Each one returns a fresh
derived subject; the operator's own state (an accumulator, a remaining count,
a queue, ...) lives in a closure private to that derived subject.

| Subject operator | Push semantics | Stream analog |
| --- | --- | --- |
| `subject-scan` | Emits a running accumulation: from `seed`, each value produces `(funcall function accumulator value)`. | `stream-scan` |
| `subject-distinct` | Re-emits only the first occurrence of each value (per `:test`). | `stream-distinct` |
| `subject-tap` | Calls a function on each value for its side effect, then re-emits it unchanged. | `stream-tap` |
| `subject-take` | Re-emits only the first `n` values, then emits nothing further. | `stream-take` |
| `subject-drop` | Ignores the first `n` values, then re-emits the rest. | `stream-drop` |
| `subject-take-while` | Re-emits the leading run satisfying a predicate; permanently stops at the first failure. | `stream-take-while` |
| `subject-drop-while` | Drops the leading run satisfying a predicate, then re-emits every value from the first failure onward. | `stream-drop-while` |
| `subject-count` | Emits the running emission count (1, 2, 3, ...) as a *live* derived subject. | `stream-count` (an eager, one-shot total — not a running series) |
| `subject-flat-map` | For each value, calls a function to get an inner subject and forwards all of its later emissions (the flatten operator). | `stream-flat-map` |
| `subject-partition` | Returns two derived subjects, splitting emissions live by a predicate. | `stream-partition` (an eager, one-shot list split) |
| `subject-zip` | Pairs two sources in lockstep, queuing values until their counterpart arrives. | `stream-zip` |
| `subject-combine-latest` | Emits `(latest-a . latest-b)` whenever either source emits, once both have emitted at least once. | no direct stream analog |
| `subject-buffer` | Collects every `n` values into a list and emits that list; a trailing partial buffer is never emitted. | `stream-chunk`/`stream-window`-style batching |

A few operators are worth calling out in more detail:

- **`subject-take`/`subject-drop`, `subject-take-while`/`subject-drop-while`.**
  The take variants **latch permanently**: once `subject-take`'s count is
  exhausted or `subject-take-while`'s predicate first fails, that derived
  subject never emits again, even if the source keeps emitting.
  `subject-drop`/`subject-drop-while` are the complementary halves — they
  swallow a leading run and then pass everything through indefinitely.

- **`subject-count`.** Unlike `stream-count`, which eagerly drains a whole
  stream once and returns a single number, `subject-count` is a live
  derived subject: it emits a new running total after every single source
  emission, so subscribers see 1, then 2, then 3, and so on.

- **`subject-flat-map`.** The higher-order (flatten) operator: the supplied
  function is called with each source value and must return an inner
  subject; every later emission of *that* inner subject is forwarded to the
  derived subject. It only forwards values emitted by the inner subject
  *after* it is created — anything the inner subject already emitted before
  being returned is missed, the same "subscribe first" caveat that applies
  to any subject.

- **`subject-partition`.** Returns two values, `(values matching
  non-matching)`, each a subject in its own right: every source value is
  emitted on `matching` when the predicate holds, and on `non-matching`
  otherwise. This is a live, ongoing split — contrast with `stream-partition`,
  which drains its whole input once and returns two plain lists.

- **`subject-zip`.** Values that arrive on one source before their
  counterpart arrives on the other are queued rather than dropped, so a burst
  on one side and a trickle on the other still pair up correctly once both
  have caught up.

- **`subject-combine-latest`.** Has no direct stream-side analog, since a
  pull stream has no notion of "whichever source is pulled next" — it always
  emits the most recent value from *each* source, combined, triggered by
  *either* source's next emission (once both have emitted at least once).

## Examples

### Filtering and collecting high-value alerts

This is the reactive half of the order-processing scenario in
`examples/integration.lisp`: a subject of priced orders, filtered down to
high-value ones, and collected for later inspection.

```lisp
(let* ((orders (cl-dataflow:make-subject))
       (alerts (cl-dataflow:subject-collect
                 (cl-dataflow:subject-filter orders (lambda (v) (> v 50))))))
  (dolist (value '(30 70 12 120))
    (cl-dataflow:subject-emit orders value))
  (funcall alerts))
;; => (70 120)
```

### A running total with `subject-scan`

```lisp
(let* ((deposits (cl-dataflow:make-subject))
       (running-total (cl-dataflow:subject-scan deposits #'+ 0))
       (balances (cl-dataflow:subject-collect running-total)))
  (dolist (amount '(10 5 20))
    (cl-dataflow:subject-emit deposits amount))
  (funcall balances))
;; => (10 15 35)
```

### Combining two sources with `subject-combine-latest`

```lisp
(let* ((price (cl-dataflow:make-subject))
       (quantity (cl-dataflow:make-subject))
       (totals (cl-dataflow:subject-combine-latest price quantity))
       (seen (cl-dataflow:subject-collect totals)))
  (cl-dataflow:subject-emit price 10)      ; quantity has no value yet: no emission
  (cl-dataflow:subject-emit quantity 3)    ; both have a value now: emits (10 . 3)
  (cl-dataflow:subject-emit price 12)      ; re-emits with the latest quantity: (12 . 3)
  (funcall seen))
;; => ((10 . 3) (12 . 3))
```

## Choosing push versus pull

Reach for a subject when values originate from an external event you don't
control the timing of — user input, a queue callback, a sensor reading — and
you want every interested party notified the moment it happens. Reach for a
[stream](streams.md) when you are transforming a known or generatable
sequence and want to control exactly when (and how much of) it gets
consumed, including infinite generators that a subject has no equivalent
for. The two are not mutually exclusive: `examples/integration.lisp` uses a
`flow-stream` for offline analytics over a finished batch of results in the
same run that uses a `subject` for live, event-driven alerts.
