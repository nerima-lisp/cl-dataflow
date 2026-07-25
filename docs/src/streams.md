# Streams (Pull)

A `flow-stream` is a lazy, **pull**-based sequence: a delayed thunk that,
when forced, yields either `:end` or `(element . next-stream)`. Nothing
happens until a consumer asks for a value — so a stream can represent an
unbounded or even infinite source, and only the elements a consumer actually
pulls are ever computed.

This is the dual of the **push**-based reactive layer: see
[Reactive Subjects (Push)](reactive.md) for `subject`s, which broadcast
values to subscribers as they arrive instead of waiting to be pulled. Use
streams when you are the one driving consumption (batch/analytical
pipelines, generators, search); use subjects when producers drive the pace
(events, live feeds).

Two properties fall out of the pull design and are worth keeping in mind
throughout this page:

- **Purity.** Pulling never mutates the source stream, so the same stream
  value can be consumed more than once, and operators compose freely without
  aliasing surprises.
- **Bounded stack.** Every per-pull "skip" loop (`stream-filter`,
  `stream-drop`, `stream-distinct`, `stream-flat-map`, `stream-concat`, ...)
  is iterative internally, so discarding a long run of elements does not
  grow the control stack. Consumers iterate rather than recurse as well.

## Laziness and construction

`flow-stream-p` recognizes a stream value. The basic constructors turn
ordinary data into a stream:

| Function | Produces |
| --- | --- |
| `empty-stream` | A stream with no elements. |
| `list->stream` | The elements of a list, in order. |
| `stream-of` | The elements of `&rest elements`, in order. |
| `stream-range` | Numbers from `start` (inclusive) toward `end` (exclusive) by `:step` (default 1; must be non-zero, may be negative). |

```lisp
(cl-dataflow:stream-collect (cl-dataflow:stream-of 1 2 3))
;; => (1 2 3)

(cl-dataflow:stream-collect (cl-dataflow:stream-range 0 10 :step 2))
;; => (0 2 4 6 8)
```

Because construction is lazy, `stream-range` with a very large (or absent)
bound is cheap to build — `stream-range 1 1000000` allocates nothing beyond
the thunk until something pulls from it.

## Core transducer operators

These are stream-to-stream operators — the transducer core. None of them
force their input; they build a new stream that pulls from the source lazily
as it is itself pulled.

| Function | Behavior |
| --- | --- |
| `stream-map` | `(funcall function element)` for each element. |
| `stream-filter` | Elements for which `predicate` is true. |
| `stream-scan` | Running accumulation: `seed` first, then `(function accumulator element)` after each element — one more element than the input. |
| `stream-take` | At most the first `n` elements. |
| `stream-drop` | Skips the first `n` elements. |
| `stream-take-while` | The longest leading run satisfying `predicate`. |
| `stream-drop-while` | Removes the longest leading run satisfying `predicate`; the remainder passes through unchanged. |
| `stream-distinct` | Only the first occurrence of each value (`:test`, default `equal`; optional `:max-distinct` bound). |
| `stream-flat-map` | Concatenates the streams produced by applying `function` to each element. |
| `stream-concat` | Concatenates `&rest streams` in order. |
| `stream-zip` | Pairs `stream-a`/`stream-b` element by element as `(a . b)` conses, stopping at the shorter stream. |
| `stream-tap` | Identical to its input, calling `function` on each element as it passes through (for side effects such as logging). |

`stream-distinct`'s `:test` may be any function designator accepted by
`member`; the standard `eq`/`eql`/`equal`/`equalp` tests get a hash-table
fast path (persistent for `eq`/`eql`, and for mutation-stable scalars under
`equal`/`equalp`), falling back to list membership for structural values.

### Building a pipeline

Streams are lazy, so a source of a million elements costs nothing until a
bounded consumer forces it:

```lisp
;; Only the first 3 even squares are ever computed, out of a million-element range.
(cl-dataflow:stream-collect
  (cl-dataflow:stream-take 3
    (cl-dataflow:stream-filter #'evenp
      (cl-dataflow:stream-map (lambda (x) (* x x))
        (cl-dataflow:stream-range 1 1000000)))))
;; => (4 16 36)
```

`stream-scan` keeps a running total, with the seed emitted first:

```lisp
(cl-dataflow:stream-collect
  (cl-dataflow:stream-scan #'+ 0 (cl-dataflow:stream-of 1 2 3 4)))
;; => (0 1 3 6 10)
```

`stream-flat-map` expands each element into a sub-stream and concatenates
the results, and composes naturally with `stream-distinct`/`stream-reduce`:

```lisp
(cl-dataflow:stream-collect
  (cl-dataflow:stream-flat-map
    (lambda (x) (cl-dataflow:stream-of x (* x 10)))
    (cl-dataflow:stream-of 1 2 3)))
;; => (1 10 2 20 3 30)

(cl-dataflow:stream-reduce #'+ 0
  (cl-dataflow:stream-distinct (cl-dataflow:stream-of 1 2 2 3 3 3 4)))
;; => 10
```

## Consumers

Consumers force a stream and produce an ordinary value. Most accept a
`:limit` keyword bounding how many input elements they will pull; exceeding
it signals `invalid-input-error` rather than running away on an unexpectedly
long (or infinite) source.

| Function | Returns |
| --- | --- |
| `stream-collect` | The elements as a fresh list. `:limit`/`:on-limit` (`:error` or `:truncate`) bound how much is forced. |
| `stream-reduce` | Left fold of `function` over the stream starting from `seed`. |
| `stream-for-each` | Calls `function` on each element for side effect; no useful return value. |
| `stream-count` | The number of elements. |
| `stream-first` | The first element, or `default` if empty. Does not force beyond one element. |
| `stream-empty-p` | True when the stream has no elements. Forces exactly one step. |

```lisp
(cl-dataflow:stream-collect (cl-dataflow:stream-of 1 2 3) :limit 2 :on-limit :truncate)
;; => (1 2)
```

## Generators

Generators build streams from a rule rather than existing data, and several
of them are **infinite** — they never signal `:end` on their own. That is
safe as long as a bounded consumer (`stream-take`, `stream-nth`,
`stream-find`, a `:limit`-bearing consumer, ...) is what ultimately drives
them; nothing forces an infinite generator eagerly.

| Function | Produces |
| --- | --- |
| `stream-iterate` | Infinite: `seed`, `(function seed)`, `(function (function seed))`, ... |
| `stream-repeat` | Infinite: `value` forever. |
| `stream-cycle` | Infinite: the elements of a list, repeating (empty list yields the empty stream). |
| `stream-enumerate` | `(index . element)` conses over a stream, indices counting up from `:start` (default 0). |
| `stream-unfold` | Repeatedly applies `function` to a seed; `function` returns `nil` to stop or `(value . next-seed)` to continue. Finite or infinite depending on `function`. |

```lisp
;; Powers of two, taken lazily from an infinite generator.
(cl-dataflow:stream-collect
  (cl-dataflow:stream-take 5 (cl-dataflow:stream-iterate (lambda (x) (* x 2)) 1)))
;; => (1 2 4 8 16)

;; stream-cycle never ends on its own -- stream-take bounds it.
(cl-dataflow:stream-collect
  (cl-dataflow:stream-take 7 (cl-dataflow:stream-cycle '(:a :b :c))))
;; => (:a :b :c :a :b :c :a)
```

## Windowing and grouping

These slice a stream into sub-lists lazily:

| Function | Produces |
| --- | --- |
| `stream-chunk` | Lists of up to `n` consecutive elements (final chunk may be shorter). `n` must be positive. |
| `stream-window` | Length-`n` sliding windows (each a list), advancing one element at a time; a stream shorter than `n` yields no windows. |
| `stream-partition-by` | Lists grouping each maximal run of consecutive elements sharing the same `(function element)` key (compared with `equal`). |

```lisp
(cl-dataflow:stream-collect (cl-dataflow:stream-chunk 3 (cl-dataflow:stream-range 1 8)))
;; => ((1 2 3) (4 5 6) (7))

(cl-dataflow:stream-collect (cl-dataflow:stream-window 3 (cl-dataflow:stream-range 1 6)))
;; => ((1 2 3) (2 3 4) (3 4 5))
```

## Aggregate consumers

Eager, `:limit`-aware terminal operations for common summaries:

| Function | Returns |
| --- | --- |
| `stream-sum` | Sum of `(key element)` (0 for an empty stream). |
| `stream-min` / `stream-max` | The element with the smallest/largest `(key element)`, or `default` if empty. |
| `stream-find` | The first element satisfying `predicate`, or `default`. |
| `stream-some` | The first non-`nil` `(predicate element)`, or `nil`. |
| `stream-every` | True when every element satisfies `predicate` (true for an empty stream). |
| `stream-last` | The last element, or `default` if empty. |
| `stream-nth` | The 0-based `n`th element, or `default` if the stream is shorter. |

```lisp
(cl-dataflow:stream-sum (cl-dataflow:stream-of 1 2 3 4))
;; => 10

(cl-dataflow:stream-find #'evenp (cl-dataflow:stream-of 1 3 5 6 7))
;; => 6
```

## Additional operators and collectors

A further set of lazy operators and eager map-building collectors, mostly
useful for data-shaping pipelines. Grouping collectors (`stream-group-by`,
`stream-frequencies`, `stream-index-by`) preserve first-seen key order.

| Function | Behavior |
| --- | --- |
| `stream-zip-with` | `(function a b)` for paired elements of two streams, stopping at the shorter. |
| `stream-interleave` | Alternates elements of two streams; once one ends, the remainder of the other follows. |
| `stream-take-nth` | Every `n`th element, starting with the first (indices 0, n, 2n, ...). |
| `stream-dedupe-consecutive` | Collapses consecutive duplicates (under `:test`, default `equal`) to one; non-adjacent duplicates are kept. |
| `stream-interpose` | Inserts `separator` between consecutive elements. |
| `stream-distinct-by` | Like `stream-distinct` but keyed by `(function element)`; keeps the first element per key. |
| `stream-group-by` | Alist `(key . elements)` grouping by `(function element)`. |
| `stream-frequencies` | Alist `(value . count)` counting occurrences of `(key element)`. |
| `stream-index-by` | Alist `(key . element)` indexing by `(function element)`, last element per key wins. |
| `stream-partition` | `(values matching non-matching)` splitting by `predicate`, order-preserving. |
| `stream-split-at` | `(values first-n-list rest-stream)` splitting a stream after `n` elements. |
| `stream-average` | Arithmetic mean of `(key element)`, or `nil` for an empty stream. |

```lisp
(cl-dataflow:stream-frequencies
  (cl-dataflow:stream-of :click :view :click :click :view :purchase :view))
;; => ((:CLICK . 3) (:VIEW . 3) (:PURCHASE . 1))

(multiple-value-bind (evens odds)
    (cl-dataflow:stream-partition #'evenp (cl-dataflow:stream-of 1 2 3 4 5 6))
  (list evens odds))
;; => ((2 4 6) (1 3 5))
```

## Statistics

Statistical consumers force the stream once and fold it in pure Lisp.
**Every one of these returns `nil` on an empty stream** rather than dividing
by zero:

| Function | Returns |
| --- | --- |
| `stream-flatten` | Concatenates the elements of each list yielded by the stream (one level; equivalent to `stream-flat-map` with `list->stream`). |
| `stream-scan1` | Running accumulation seeded by the stream's own first element (so the result starts with that element). |
| `stream-count-if` | The number of elements satisfying `predicate`. |
| `stream-variance` | Population variance of `(key element)`, or `nil` if empty. |
| `stream-stddev` | Population standard deviation, or `nil` if empty. |
| `stream-median` | The median (mean of the two middle values for an even count), or `nil` if empty. |

```lisp
(cl-dataflow:stream-variance (cl-dataflow:stream-of 2 4 4 4 5 5 7 9))
;; => 4

(cl-dataflow:stream-median (cl-dataflow:stream-of 1 2 3 4))
;; => 5/2
```

## Search

| Function | Returns |
| --- | --- |
| `stream-find-index` | The 0-based index of the first element satisfying `predicate`, or `nil`. |
| `stream-none-p` | True when no element satisfies `predicate` (true for an empty stream). |
| `stream-mode` | The most frequently occurring element (first-seen wins ties), or `nil` if empty. `:test` is the hash-table equality used to group elements. |
| `stream-cartesian` | The stream of `(a . b)` conses for every pair drawn from two streams, `b` varying fastest. The second stream is re-consumed once per element of the first — safe because streams are pure. |

```lisp
(cl-dataflow:stream-find-index #'evenp (cl-dataflow:stream-of 1 3 5 6 7))
;; => 3

(cl-dataflow:stream-collect (cl-dataflow:stream-cartesian (cl-dataflow:stream-of 1 2) (cl-dataflow:stream-of :a :b)))
;; => ((1 . :a) (1 . :b) (2 . :a) (2 . :b))
```

## Runnable examples

The example scripts under `examples/` double as smoke tests (see
[Examples](examples.md) and [Testing and Coverage](testing.md)):

```bash
sbcl --script examples/streams.lisp
sbcl --script examples/stream-analytics.lisp
```

`examples/streams.lisp` builds the even-squares pipeline shown above plus a
`stream-scan` running total, a `stream-flat-map` expansion, and a
`stream-distinct` + `stream-reduce` sum. `examples/stream-analytics.lisp`
covers `stream-frequencies`, `stream-group-by`, `stream-partition`,
`stream-window` combined with `stream-average` for sliding-window means, and
a whole-stream `stream-average`.

## Where to go next

- [Reactive Subjects (Push)](reactive.md) for the push-based dual of this API.
- [Combinators and Resilience](combinators.md) for wrapping pipeline nodes
  with retry/fallback logic that composes with streams and subjects alike.
- [Public API Reference](api-reference.md) for the complete, alphabetized
  export list.
