# Graphs

A `graph` is a collection of named `node`s connected by `edge`s. This page
covers the structural half of the graph API: building a graph, validating it,
querying its shape, mutating and composing graphs, and exporting them.
Definitions of `node`, `edge`, and `graph` themselves live in
[Core Concepts](core-concepts.md); the analysis layer built on top of this
structure — connectivity, centrality, criticality, flow, and the rest —
lives on [Graph Algorithms](graph-algorithms.md). Once a graph is validated it
can back an executable [Pipeline](pipelines.md).

## Building a graph

`make-graph` creates an empty graph. `make-node` and `make-edge` create the
values `add-node` and `add-edge` insert:

```lisp
(defparameter *graph* (cl-dataflow:make-graph))

(cl-dataflow:add-node *graph* (cl-dataflow:make-node "ingest"))
(cl-dataflow:add-node *graph* (cl-dataflow:make-node "parse"))
(cl-dataflow:add-node *graph* (cl-dataflow:make-node "load"))

(cl-dataflow:add-edge *graph* "ingest" "parse")
(cl-dataflow:add-edge *graph* "parse" "load")

(cl-dataflow:find-node *graph* "parse")
;; => #<NODE parse>
```

`add-edge` takes node designators (a name or a `node`) for `from`/`to`, plus
`:from-port`/`:to-port` keywords that default to `"value"`. `find-node`
returns `nil` when no node with that name exists.

`add-node` and `add-edge` both reject rather than silently reinterpret a
conflicting call:

| Rule | Behavior |
| --- | --- |
| Node names are unique per graph | `add-node` signals `graph-error` on a duplicate name, rather than retargeting existing edges to a replacement node. |
| Edges are unique by `(from-node from-port to-node to-port)` | `add-edge` signals `graph-error` on an exact duplicate, rather than double-counting the connection. Multiple edges into the *same* input port from *different* sources are still allowed at the graph layer — that convention only gets resolved down to "newest edge wins" once a pipeline binds inputs. |
| Edge endpoints must exist | `add-edge` signals `node-not-found-error` if either endpoint name is not already in the graph. |
| Edge ports must be declared on the node | `add-edge` signals `graph-error` if `from-port`/`to-port` is not one of the node's declared `outputs`/`inputs`. |

## Validating structure and order

`validate-graph` runs full validation: structural integrity (every edge
references an existing node and a declared port, no duplicate ports on a
node) plus acyclicity, by calling `topological-sort` internally and letting
its `graph-cycle-error` propagate. `topological-sort` returns nodes in a
deterministic dependency order, computed with Kahn's algorithm over a single
bulk-queried adjacency snapshot of the graph's `cl-prolog` edge relation —
see [Architecture](architecture.md#the-graph-runtime) for the full
explanation of that runtime.

```lisp
(cl-dataflow:validate-graph *graph*)
;; => T

(mapcar #'cl-dataflow:node-name (cl-dataflow:topological-sort *graph*))
;; => ("ingest" "parse" "load")
```

A cyclic graph is still a legally constructed graph — `add-node`/`add-edge`,
`graph-nodes`/`graph-edges`, and the structural queries below all work on it.
Only `validate-graph` and `topological-sort` (and anything that calls them,
like pipeline construction) reject cycles, by signaling `graph-cycle-error`
with the unprocessed cyclic nodes attached.

## Structural queries

`graph-source-nodes` and `graph-sink-nodes` return the graph's boundary
nodes — indegree-zero and no-successors, respectively — read from the same
adjacency snapshot, name-ordered:

```lisp
(mapcar #'cl-dataflow:node-name (cl-dataflow:graph-source-nodes *graph*))
;; => ("ingest")
(mapcar #'cl-dataflow:node-name (cl-dataflow:graph-sink-nodes *graph*))
;; => ("load")
```

`graph-reachable-p`, `graph-descendants`, `graph-ancestors`, and `graph-path`
answer reachability questions over the same edge relation:

```lisp
(cl-dataflow:graph-reachable-p *graph* "ingest" "load")
;; => T

(mapcar #'cl-dataflow:node-name (cl-dataflow:graph-descendants *graph* "ingest"))
;; => ("load" "parse")

(mapcar #'cl-dataflow:node-name (cl-dataflow:graph-ancestors *graph* "load"))
;; => ("ingest" "parse")

(cl-dataflow:graph-path *graph* "ingest" "load")
;; => ("ingest" "parse" "load")
```

`graph-path` returns the node names of a shortest witnessing path (`from`
first, `to` last), found by breadth-first search over the bulk-queried
successor adjacency, or `nil` when `to` is unreachable from `from`.

All four follow the same **one-or-more-edges** convention: reaching a node
requires crossing at least one edge, so a bare `from` = `to` with no
self-loop does not count as reachable, but a genuine self-loop or a cycle
that returns to `from` does. Because traversal tracks a visited set instead
of recursing, all four terminate cleanly on cyclic graphs rather than
looping forever.

## Mutating and composing graphs

`add-node`/`add-edge` are append-only. The rest of the mutation API fills in
removal and composition:

| Function | Effect |
| --- | --- |
| `remove-node` | Removes a node and every edge incident to it, **in place**. Signals `node-not-found-error` if absent. |
| `remove-edge` | Removes one edge by endpoints/ports, **in place**. Returns `t` if a matching edge was removed, `nil` if none existed. |
| `graph-subgraph` | Returns a **new** graph induced by a set of node names: those nodes plus every edge whose endpoints are both in the set. Names absent from the graph are ignored; the graph is not modified. |
| `graph-merge` | Returns a **new** graph that is the disjoint union of two graphs. Node names must not collide between the two inputs — a shared name signals `graph-error`. Neither input is modified. |
| `graph-relabel-node` | Returns a **new** graph with one node renamed and every incident edge rewritten to match. Signals `node-not-found-error` if the old name is absent, `graph-error` if the new name is already taken. |
| `graph-contract-edge` | Returns a **new** graph with two adjacent nodes merged into one: every edge incident to the absorbed node is redirected to the surviving node's first port, edges that become self-loops through the merge are dropped, and edges that become duplicates after redirecting collapse into one (the first edge's metadata wins). |

```lisp
(cl-dataflow:remove-edge *graph* "parse" "load")
;; => nil  (no such edge; parse -> load was never added)

(cl-dataflow:remove-node *graph* "ingest")
;; => *graph*, now missing "ingest" and the "ingest" -> "parse" edge

(defparameter *sub* (cl-dataflow:graph-subgraph *graph* '("parse" "load")))

(defparameter *merged*
  (cl-dataflow:graph-merge *sub* (cl-dataflow:make-graph)))

(defparameter *renamed*
  (cl-dataflow:graph-relabel-node *merged* "parse" "transform"))

(defparameter *contracted*
  (cl-dataflow:graph-contract-edge *graph* "parse" "load"))
```

Only `remove-node` and `remove-edge` mutate their argument; `graph-subgraph`,
`graph-merge`, `graph-relabel-node`, and `graph-contract-edge` are pure
derivations that always return a fresh graph.

## Copying and equality

`copy-graph` returns an independent deep copy — nodes, edges, and metadata —
so the original and the copy can be mutated without cross-talk. Structural
equality between two graphs is `graph-equal-p`, covered alongside the other
equality predicates in [Public API Reference](api-reference.md); it compares
graphs through their deterministic plist serialization rather than object
identity.

## Export and serialization

`graph->dot` and `graph->mermaid` render a graph for visualization, walking
a deterministic snapshot — nodes name-sorted, edges sorted by
`(from from-port to to-port)` — so the same graph always produces the same
text:

```lisp
(cl-dataflow:graph->dot *dag* :name "deps")
;; => "digraph deps {\n  \"a\";\n  ...\n}\n"

(cl-dataflow:graph->mermaid *dag* :direction "LR")
;; => "flowchart LR\n  n0[\"a\"]\n  ...\n"
```

`graph-layout` assigns each node an `(layer . index)` coordinate pair:
`layer` is the node's topological generation (sources at layer 0), and
`index` is its 0-based position within that layer in name order. It is meant
to feed custom renderers — `graph->dot` and `graph->mermaid` delegate actual
layout to their own engines — and, like `topological-sort`, it signals
`graph-cycle-error` on a cyclic graph:

```lisp
(cl-dataflow:graph-layout *dag*)
;; => (("a" 0 . 0) ("b" 1 . 0) ("c" 1 . 1) ("d" 2 . 0))
```

`graph-to-plist` and `plist-to-graph` round-trip a graph's structure through
a plain plist of `:metadata`, `:nodes`, and `:edges`:

```lisp
(defparameter *plist* (cl-dataflow:graph-to-plist *dag*))
(defparameter *restored* (cl-dataflow:plist-to-graph *plist*))

(cl-dataflow:graph-equal-p *dag* *restored*)
;; => T
```

Node handlers are runtime closures, not data, so they are **not** part of
`graph-to-plist`'s output — `plist-to-graph` rebuilds every node with the
default identity handler. The round trip preserves topology, ports, and
metadata, which is everything needed to persist, diff, or transmit a graph's
shape; it is not meant to preserve handler behavior.
