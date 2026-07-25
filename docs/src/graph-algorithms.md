# Graph Algorithms

`cl-dataflow` ships a full analysis layer on top of the basic `graph`
structure — construction, mutation, and export are covered in [Graphs](graphs.md);
this page covers everything built *on top of* a graph once it exists:
reachability metrics, component structure, traversal order, weighted paths and
flow, whole-graph metrics, set algebra, and criticality analysis.

Every algorithm here shares one discipline: build the adjacency snapshot once
(`%graph-adjacency-snapshot`/`%graph-adjacency`), then walk it with an
explicit queue, stack, or work list — never per-node Prolog queries and never
unbounded recursion. [Architecture](architecture.md#the-graph-runtime)
explains why: it keeps every traversal here linear (or low-degree polynomial)
and stack-safe on deep chains and cyclic graphs, where a naive recursive
implementation would overflow the control stack or blow up exponentially.

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

## Paths and order

Reachability-derived structural transforms and enumerations: transitive
closure/reduction, topological rank, the critical path, every simple path,
one cycle witness, and Eulerian trails.

- `graph-transitive-closure` — a new graph with the same nodes and an edge
  `a -> b` for every ordered pair where `b` is reachable from `a` (a node on
  a cycle gains a self-edge). The source graph is unmodified.
- `graph-transitive-reduction` — the minimal edge set with the same
  reachability as an *acyclic* graph (drops an edge `u -> v` when `v` is
  still reachable from `u` through some other direct successor). Signals
  `graph-cycle-error` on a cyclic graph, since the reduction is only unique
  on a DAG.
- `graph-topological-rank` — an alist `(name . rank)` where rank is the
  length of the longest path from any source to that node; sources have rank
  0. Signals `graph-cycle-error` on a cycle.
- `graph-longest-path` — the node names of a longest path through an acyclic
  graph, i.e. its critical path, from a source to the deepest reachable node.
- `graph-all-paths` — every simple path (no repeated node) from `from` to
  `to`, as an ordered list of name-lists. Enumeration is exponential in the
  worst case and meant for small graphs; `:max-paths` (default 10000, `NIL`
  disables it) bounds the count and signals `invalid-input-error` if
  exceeded, and `:max-depth` bounds the number of edges per path.
- `graph-find-cycle` — the node names of one directed cycle (an ordered list
  whose last element repeats the first), or `NIL` on an acyclic graph. Reuses
  the strongly connected components plus `graph-path` over the induced
  subgraph, so it stays safe on deep graphs.
- `graph-eulerian-path` — an Eulerian trail: a sequence of node names
  traversing every edge exactly once, or `NIL` when none exists. Works on the
  directed multigraph (parallel edges each used once); computed with
  Hierholzer's algorithm after checking in/out-degree balance, with the
  name-least successor taken first for a deterministic result.

```lisp
;; The critical path is the longest dependency chain.
(cl-dataflow:graph-longest-path *graph*) ; => ("fetch" "compile" "test" "package")

;; compile -> package is redundant once compile -> test -> package exists.
(cl-dataflow:graph-size (cl-dataflow:graph-transitive-reduction *graph*)) ; => 3

;; Every simple path from fetch to package.
(cl-dataflow:graph-all-paths *graph* "fetch" "package")
;; => (("fetch" "compile" "package") ("fetch" "compile" "test" "package"))
```

## Weighted paths and flow

Edge-metadata-driven algorithms: Dijkstra's shortest weighted path/distance
and Edmonds-Karp maximum flow / minimum cut. Both read a numeric value out of
`edge-metadata` via a configurable key/default, exactly like `graph-max-flow`
and `graph-weighted-distance` document, and both signal `invalid-input-error`
if that value isn't a non-negative real.

- `graph-weighted-distance` — the minimum total edge weight from `from` to
  `to` (traversing at least one edge), or `NIL` if unreachable. Each edge's
  weight is `(getf (edge-metadata edge) weight-key default-weight)`;
  `weight-key` defaults to `:weight` and `default-weight` to 1.
- `graph-weighted-path` — the node-name sequence of a minimum-weight path
  (`from` first, `to` last), or `NIL` if unreachable; same weight
  conventions.
- `graph-weighted-distances-from` — an alist `(name . cost)` of the minimum
  weighted distance from `from` to every node it reaches — Dijkstra to all
  targets, the weighted companion to `graph-distances-from`.
- `graph-max-flow` — the maximum flow value from `source` to `sink` over
  edge-metadata capacities (`:capacity-key`, default `:capacity`;
  `:default-capacity`, default 1), computed by Edmonds-Karp
  (breadth-first-augmenting Ford-Fulkerson). Parallel edges' capacities add.
  Returns 0 when `sink` is unreachable or the two nodes coincide; runs in
  polynomial time and terminates on cyclic graphs because every augmentation
  strictly saturates an edge.
- `graph-min-cut` — the minimum `source`-to-`sink` cut as a list of directed
  `(from to)` edge pairs whose removal disconnects `sink`, with total
  capacity equal to `graph-max-flow`. Found via the max-flow min-cut theorem:
  after Edmonds-Karp saturates the network, the cut is exactly the edges
  leaving the set of nodes still reachable from `source` in the residual
  graph — reusing the same search, not a second pass.

```lisp
(defparameter *wg* (cl-dataflow:make-graph))
(dolist (name '("a" "b" "c"))
  (cl-dataflow:add-node *wg* (cl-dataflow:make-node name)))
(setf (cl-dataflow:edge-metadata (cl-dataflow:add-edge *wg* "a" "b")) '(:weight 5))
(setf (cl-dataflow:edge-metadata (cl-dataflow:add-edge *wg* "a" "c")) '(:weight 9))
(setf (cl-dataflow:edge-metadata (cl-dataflow:add-edge *wg* "b" "c")) '(:weight 2))

;; The direct a -> c edge costs 9; routing through b costs only 5 + 2 = 7.
(cl-dataflow:graph-weighted-distance *wg* "a" "c") ; => 7
(cl-dataflow:graph-weighted-path *wg* "a" "c")      ; => ("a" "b" "c")

(defparameter *net* (cl-dataflow:make-graph))
(dolist (name '("s" "a" "b" "t"))
  (cl-dataflow:add-node *net* (cl-dataflow:make-node name)))
(setf (cl-dataflow:edge-metadata (cl-dataflow:add-edge *net* "s" "a")) '(:capacity 3))
(setf (cl-dataflow:edge-metadata (cl-dataflow:add-edge *net* "s" "b")) '(:capacity 2))
(setf (cl-dataflow:edge-metadata (cl-dataflow:add-edge *net* "a" "t")) '(:capacity 2))
(setf (cl-dataflow:edge-metadata (cl-dataflow:add-edge *net* "b" "t")) '(:capacity 3))

(cl-dataflow:graph-max-flow *net* "s" "t")  ; => 4
(cl-dataflow:graph-min-cut *net* "s" "t")   ; => (("a" "t") ("s" "b"))
```

## Metrics

Whole-graph and per-node summary statistics: density, degree distribution,
clustering, reciprocity, bipartiteness, coloring, structural equality, and
weak reachability.

- `graph-density` — distinct edges divided by the maximum possible
  `V*(V-1)`; 0 for fewer than two nodes.
- `graph-degree-histogram` — an alist `(degree . count)` over each node's
  total degree (distinct successors plus distinct predecessors), ascending.
- `graph-clustering-coefficient` — a node's local clustering coefficient: the
  fraction of pairs among its distinct undirected neighbors that are
  themselves adjacent (how close its neighborhood is to a clique); 0 with
  fewer than two neighbors.
- `graph-average-clustering` — the mean clustering coefficient over every
  node; 0 for an empty graph.
- `graph-reciprocity` — the fraction of distinct non-loop directed edges
  whose reverse edge is also present; 0 with no non-loop edges.
- `graph-bipartite-p` — true when the undirected view is 2-colorable; a
  self-loop makes a graph non-bipartite.
- `graph-greedy-coloring` — an alist `(name . color)` assigning each node a
  non-negative integer color via greedy first-fit over nodes in name order,
  so adjacent nodes never share a color. Generalizes `graph-bipartite-p`
  (which only tests 2-colorability); coloring is NP-hard so the result is
  valid but not necessarily minimal.
- `graph-equal-p` — structural equality of two graphs: same nodes (names,
  ports, metadata) and same edges (endpoints, ports, metadata), independent
  of insertion order, via `graph-to-plist`. Node handlers are runtime
  closures and are not compared.
- `graph-undirected-reachable-p` — true when `from` and `to` lie in the same
  weakly connected component (edge direction ignored); a node is always
  undirected-reachable from itself.

```lisp
(cl-dataflow:graph-density *graph*)               ; => 1/3
(cl-dataflow:graph-degree-histogram *graph*)       ; => ((1 . 1) (2 . 2) (3 . 1))

;; The undirected view has a triangle (compile-test, test-package,
;; compile-package), an odd cycle, so it isn't 2-colorable.
(cl-dataflow:graph-bipartite-p *graph*)            ; => NIL
(cl-dataflow:graph-greedy-coloring *graph*)
;; => (("compile" . 0) ("fetch" . 1) ("package" . 1) ("test" . 2))
```

## Algebra

Set operations and functional transforms over graphs. All of these produce a
fresh graph and never mutate their inputs; edges are compared by identity
(endpoints plus ports).

- `graph-union` — every node and edge of both graphs; shared node names
  appear once (the first graph's definition wins), and `:metadata` overrides
  the result's metadata (default: a copy of the first graph's).
- `graph-intersection` — the nodes present in both graphs (by name) and the
  edges present in both (by identity); the first graph's node/metadata
  definitions are used.
- `graph-difference` — all of the first graph's nodes, but only the edges
  whose identity does *not* also appear in the second graph — edge
  subtraction with nodes kept.
- `graph-diff` — a structured plist describing how the second graph differs
  from the first: `(:added-nodes ... :removed-nodes ... :added-edges (...)
  :removed-edges (...))`, the report-style complement to `graph-difference`.
- `graph-filter-nodes` — the subgraph induced by the nodes for which a
  predicate (called on each node) is true, together with the edges among
  them (see `graph-subgraph` on [Graphs](graphs.md)).
- `graph-map-nodes` — a new graph with every node name replaced by
  `(funcall name-function name)` and every incident edge rewritten
  accordingly; `name-function` must be injective or `add-node` will signal a
  duplicate.

```lisp
(cl-dataflow:graph-diff *graph* (cl-dataflow:graph-filter-nodes
                                 *graph*
                                 (lambda (node) (not (equal (cl-dataflow:node-name node) "lint")))))
;; => (:added-nodes () :removed-nodes () :added-edges () :removed-edges ())
```

## Criticality

Single-point-of-failure and mandatory-waypoint analysis: articulation
points, bridges, and the dominator/post-dominator tree. Articulation points
and bridges are computed the recursion-free way — remove the candidate and
recount weakly connected components — which is `O(V*(V+E))`/`O(E*(V+E))`, but
never grows the control stack and correctly handles multigraphs.

- `graph-articulation-points` — the names of the cut vertices of the
  undirected view: nodes whose removal increases the number of weakly
  connected components, i.e. single points of failure whose loss
  disconnects the graph.
- `graph-bridges` — the critical connections of the undirected view, as
  `(a b)` pairs (`a` string< `b`): a connection whose removal (of every edge
  between the pair, for multigraphs) leaves the two nodes in different weakly
  connected components.
- `graph-dominators` — the immediate-dominator map rooted at `source`, as an
  alist `(node . idom)`: for every node reachable from `source` other than
  `source` itself, the closest node through which every path from `source`
  must pass. This is the directed counterpart of articulation points and the
  classical substrate of dataflow analysis. Computed by the iterative
  Cooper-Harvey-Kennedy algorithm over reverse postorder with an
  explicit-stack DFS, so it stays polynomial and stack-safe on deep, cyclic
  graphs.
- `graph-post-dominators` — the dual toward a `sink`: for every node that can
  reach `sink`, the closest mandatory waypoint every path from that node to
  `sink` must cross. It is exactly `graph-dominators` run on the reversed
  graph rooted at `sink`, sharing the same iterative machinery.

```lisp
;; "compile" is the sole cut vertex: sever it and "fetch" is stranded from
;; the triangle "compile"-"test"-"package" left behind.
(cl-dataflow:graph-articulation-points *graph*) ; => ("compile")
(cl-dataflow:graph-bridges *graph*)              ; => (("compile" "fetch"))
(cl-dataflow:graph-dominators *graph* "fetch")
;; => (("compile" . "fetch") ("package" . "compile") ("test" . "compile"))
```

Together, dominators and post-dominators bracket every node by what must run
before it and what must run after it — the same structural question
`graph-articulation-points`/`graph-bridges` ask, but oriented and rooted.

## See also

- [Graphs](graphs.md) — construction, mutation, subgraphs, merging, and
  export/serialization (`graph-to-plist`, `graph->dot`, `graph->mermaid`).
- [Architecture](architecture.md#the-graph-runtime) — why every algorithm on
  this page is an iterative, explicit queue/stack traversal over a
  once-built adjacency snapshot.
- [Observability and Serialization](observability.md) — rendering graphs
  (and pipelines built from them) as Graphviz DOT or Mermaid diagrams.
- [Public API Reference](api-reference.md) — the full alphabetized export
  list, including every function named on this page.
