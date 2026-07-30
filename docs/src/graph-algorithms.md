# Graph Algorithms

`cl-dataflow` ships a full analysis layer on top of the basic `graph`
structure — construction, mutation, and export are covered in [Graphs](graphs.md).
This page covers the structural layer built directly on top of a graph:
reachability metrics, component structure, and traversal order.
[Graph Analysis](graph-analysis.md) continues from here with weighted paths
and flow, whole-graph metrics, set algebra, and criticality analysis.

Every algorithm here shares one discipline: build the adjacency snapshot once
(`%graph-adjacency-snapshot`/`%graph-adjacency`), then walk it with an
explicit queue, stack, or work list — never per-node Prolog queries and never
unbounded recursion. [Architecture](architecture.md#the-graph-runtime)
explains why: it keeps every traversal here linear (or low-degree polynomial)
and stack-safe on deep chains and cyclic graphs, where a naive recursive
implementation would overflow the control stack or blow up exponentially.
[Graph Analysis](graph-analysis.md) shares this same discipline.

All of the examples below assume:

```lisp
(defparameter *graph* (cl-dataflow:make-graph))
```

and build up nodes/edges as shown per section. See the [Public API
Reference](api-reference.md) for the complete, alphabetized export list, and
[Observability and Serialization](observability.md) for rendering a graph as
Graphviz DOT or Mermaid (`graph->dot`/`graph->mermaid`) once you've analyzed it.

## Basic queries and structure

The cheapest layer: node/edge counts, immediate neighbors, degree, the
reversed graph, and an acyclicity check. Most of these are O(1) or a single
adjacency-snapshot pass.

- `graph-node-names` — every node name, lexicographically sorted.
- `graph-order` / `graph-size` — node count / edge count (parallel edges
  across distinct ports count individually, matching `graph-edges`).
- `graph-empty-p` — true when the graph has no nodes.
- `graph-successors` / `graph-predecessors` — copies of the immediate
  successor/predecessor nodes of a node, one edge away, ordered by name.
- `graph-out-degree` / `graph-in-degree` — the count of distinct
  successors/predecessors (distinct `(from . to)` pairs count once).
- `graph-transpose` — a new graph with every edge reversed; node identities,
  ports, and metadata are preserved, and reversed edges attach to each node's
  first output/input port since the original ports need not be valid in
  reverse.
- `graph-acyclic-p` — true when the graph has no directed cycle (built on
  `topological-sort`, catching `graph-cycle-error`).
- `graph-self-loop-nodes` — the names of nodes carrying an edge to
  themselves, lexicographically sorted. Self-loops are the edge case several
  algorithms on this page single out — they make a graph non-bipartite and
  are excluded from `graph-reciprocity` — so this is the direct way to find
  them.

```lisp
(dolist (name '("fetch" "compile" "test" "package"))
  (cl-dataflow:add-node *graph* (cl-dataflow:make-node name)))
(dolist (edge '(("fetch" "compile") ("compile" "test") ("compile" "package")
                ("test" "package")))
  (cl-dataflow:add-edge *graph* (first edge) (second edge)))

(cl-dataflow:graph-order *graph*)            ; => 4
(cl-dataflow:graph-size *graph*)              ; => 4
(cl-dataflow:graph-out-degree *graph* "compile") ; => 2
(cl-dataflow:graph-acyclic-p *graph*)          ; => T

;; "What feeds into package, reversed?" -- transpose flips the whole graph.
(mapcar #'cl-dataflow:node-name
        (cl-dataflow:graph-successors (cl-dataflow:graph-transpose *graph*) "package"))
;; => ("compile" "test")
```

## Connected components and condensation

The component-structure family: strongly connected components (mutual
reachability), weakly connected components (reachability ignoring edge
direction), the parallelizable layering of a DAG, and the SCC condensation.

- `graph-strongly-connected-components` — the strongly connected components,
  as a list of lexicographically sorted name lists, ordered by their smallest
  member. Computed with Kosaraju's algorithm: an iterative DFS over
  successors records finish order, then components are grown by iterative DFS
  over predecessors in decreasing finish order. A node with no cycle through
  it is its own singleton component.
- `graph-connected-components` — the *weakly* connected components (edges
  treated as undirected), same ordering convention.
- `graph-topological-generations` — the topological generations: layer 0
  holds every source (indegree 0), layer 1 holds the nodes that become
  sources once layer 0 is removed, and so on. Each layer is a list of node
  copies ordered by name. This is the layering that tells you which stages of
  a dependency DAG can run in parallel. Signals `graph-cycle-error` on a
  cyclic graph.
- `graph-connected-p` / `graph-strongly-connected-p` — the whole-graph
  predicates over those two component families: true when every node lies in
  one weakly / strongly connected component. Both are "at most one
  component", so the empty graph and a single node qualify either way.
- `graph-condensation` — a new DAG with one node per strongly connected
  component (named after the component's smallest member, with the full
  member list under its `:members` metadata) and an edge between components
  wherever an original edge crosses between them. The condensation is always
  acyclic — a cycle in it would contradict the components being maximal.

```lisp
(defparameter *cycle* (cl-dataflow:make-graph))
(dolist (name '("x" "y" "z" "w"))
  (cl-dataflow:add-node *cycle* (cl-dataflow:make-node name)))
(dolist (edge '(("x" "y") ("y" "z") ("z" "x") ("z" "w")))
  (cl-dataflow:add-edge *cycle* (first edge) (second edge)))

(cl-dataflow:graph-strongly-connected-components *cycle*)
;; => (("w") ("x" "y" "z"))

;; The condensation collapses the cycle into one node, "x", with :members
;; ("x" "y" "z"), keeping the outgoing edge to "w".
(cl-dataflow:graph-node-names (cl-dataflow:graph-condensation *cycle*))
;; => ("w" "x")
```

## Traversal order

`graph-bfs-order` and `graph-dfs-order` return the actual visitation sequence
from a source node, rather than a distance or reachability set — useful when
you need a concrete execution or inspection order rather than just "what's
reachable."

- `graph-bfs-order` — breadth-first order from `from`, starting with `from`
  itself, each node appearing once; ties within a level are broken by name.
- `graph-dfs-order` — depth-first preorder from `from`, with the name-least
  successor descended first, so the result is deterministic.

Both are iterative (explicit queue/stack), so deep graphs are safe.

```lisp
(cl-dataflow:graph-bfs-order *graph* "fetch") ; => ("fetch" "compile" "package" "test")
(cl-dataflow:graph-dfs-order *graph* "fetch") ; => ("fetch" "compile" "package" "test")
```

## Distance and centrality

Hop-count metrics and the classic centrality measures, all built over BFS.
`graph-eccentricity`/`graph-diameter`/`graph-radius`/`graph-center`/`graph-periphery`
share the directed convention that a node reaching nothing has eccentricity 0
— see each docstring for the exact edge case.

- `graph-distance` — the shortest hop count from `from` to `to` (traversing
  at least one edge), or `NIL` if `to` is unreachable. `from` = `to` resolves
  only through a cycle.
- `graph-distances-from` — an alist `(name . hop-distance)` for every node
  reachable from `from`, via one BFS pass. This is the all-destinations
  companion `graph-distance` doesn't provide, and it underlies eccentricity,
  closeness, Wiener index, and average path length below.
- `graph-eccentricity` — the greatest hop distance from a node to anything it
  reaches (0 if it reaches nothing).
- `graph-diameter` / `graph-radius` — the largest / smallest eccentricity
  over the whole graph.
- `graph-center` / `graph-periphery` — the node names whose eccentricity
  equals the radius / diameter, respectively.
- `graph-wiener-index` — the sum of shortest-path hop distances over every
  ordered pair of distinct, reachable nodes.
- `graph-average-path-length` — that sum divided by the number of such pairs
  (0, never a division by zero, when there are none).
- `graph-closeness-centrality` — the count of nodes a node reaches divided by
  the total hop distance to them; higher means it reaches the rest of the
  graph in fewer hops on average.
- `graph-betweenness-centrality` — an alist `(name . score)` of unnormalized
  betweenness: for each node, the total fraction of shortest paths between
  every other ordered pair that pass through it. Computed with Brandes'
  algorithm (iterative BFS per source plus a reverse dependency-accumulation
  pass), identifying the "broker" nodes a dataflow graph routes through.

```lisp
(cl-dataflow:graph-distance *graph* "fetch" "package")    ; => 2
(cl-dataflow:graph-eccentricity *graph* "fetch")           ; => 2
(cl-dataflow:graph-diameter *graph*)                       ; => 2
(cl-dataflow:graph-closeness-centrality *graph* "fetch")   ; => 3/5

;; Betweenness picks out "compile" as the broker between fetch and the rest.
(cl-dataflow:graph-betweenness-centrality *graph*)
;; => (("compile" . 2) ("fetch" . 0) ("package" . 0) ("test" . 0))
```

## See also

- [Graph Analysis](graph-analysis.md) — weighted paths and flow, whole-graph
  metrics, set algebra, and criticality analysis, continuing directly from
  this page.
- [Graphs](graphs.md) — construction, mutation, subgraphs, merging, and
  export/serialization (`graph-to-plist`, `graph->dot`, `graph->mermaid`).
- [Architecture](architecture.md#the-graph-runtime) — why every algorithm on
  this page is an iterative, explicit queue/stack traversal over a
  once-built adjacency snapshot.
- [Observability and Serialization](observability.md) — rendering graphs
  (and pipelines built from them) as Graphviz DOT or Mermaid diagrams.
- [Public API Reference](api-reference.md) — the full alphabetized export
  list, including every function named on this page.
