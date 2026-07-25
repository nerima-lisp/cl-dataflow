(in-package #:cl-dataflow)

;;;; Whole-graph connectivity predicates, the strongly-connected-component
;;;; condensation, and single-source distance metrics. These build on the
;;;; component and adjacency machinery and stay iterative; the condensation is
;;;; always a DAG (a cycle would contradict the components being maximal).

(defun graph-connected-p (graph)
  "Return true when GRAPH is weakly connected -- all nodes lie in one component
(edge direction ignored). The empty graph and a single node are connected."
  (<= (length (graph-connected-components graph)) 1))

(defun graph-strongly-connected-p (graph)
  "Return true when GRAPH is strongly connected -- every node reaches every other,
i.e. it has at most one strongly connected component. The empty graph and a single
node qualify."
  (<= (length (graph-strongly-connected-components graph)) 1))

(defun graph-self-loop-nodes (graph)
  "Return the names of nodes carrying a self-loop edge, ordered lexicographically."
  (sort (remove-duplicates
         (loop for edge in (%graph-edges-list graph)
               when (equal (edge-from edge) (edge-to edge))
               collect (edge-from edge))
         :test #'equal)
        #'string<))

(defun graph-condensation (graph)
  "Return the condensation of GRAPH: a new DAG with one node per strongly connected
component (named by the component's smallest member, with the full member list in
its `:members` metadata) and an edge between components wherever an original edge
crosses between them. GRAPH is not modified."
  (let ((representative (make-hash-table :test #'equal))
        (result (make-graph :metadata (graph-metadata graph))))
    (dolist (component (graph-strongly-connected-components graph))
      (let ((rep (first component)))
        (dolist (member component)
          (setf (gethash member representative) rep))
        (add-node result (make-node rep :metadata (list :members component)))))
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (edge (%graph-edges-list graph))
        (let ((from-rep (gethash (edge-from edge) representative))
              (to-rep (gethash (edge-to edge) representative)))
          (unless (equal from-rep to-rep)
            (let ((key (cons from-rep to-rep)))
              (unless (gethash key seen)
                (setf (gethash key seen) t)
                (add-edge result from-rep to-rep)))))))
    result))

(defun graph-distances-from (graph from)
  "Return an alist (NAME . HOP-DISTANCE) of every node reachable from FROM through
one or more edges, via breadth-first search. FROM itself appears only when a cycle
returns to it. Ordered by name."
  (let ((from-name (%node-designator-name from)))
    (%ensure-graph-node graph from-name)
    (let ((successors (%graph-adjacency graph (%graph-rulebase graph)))
          (distance (make-hash-table :test #'equal))
          (frontier '())
          (depth 1))
      ;; FROM's successors are distinct and DISTANCE starts empty, so no seed
      ;; needs a presence guard (see GRAPH-DISTANCE).
      (dolist (successor (gethash from-name successors))
        (setf (gethash successor distance) depth)
        (push successor frontier))
      (setf frontier (nreverse frontier))
      (loop while frontier do
        (incf depth)
        (let ((next '()))
          (dolist (name frontier)
            (dolist (successor (gethash name successors))
              (unless (gethash successor distance)
                (setf (gethash successor distance) depth)
                (push successor next))))
          (setf frontier (nreverse next))))
      (sort (loop for name being the hash-keys of distance using (hash-value d)
                  collect (cons name d))
            #'string< :key #'car))))

(defun graph-bfs-order (graph from)
  "Return the node names reachable from FROM in breadth-first order, starting with
FROM itself, each appearing once. Ties within a level are broken by name. Iterative,
so deep graphs are safe."
  (let ((from-name (%node-designator-name from)))
    (%ensure-graph-node graph from-name)
    (let ((successors (%graph-adjacency-snapshot graph :successors))
          (visited (make-hash-table :test #'equal))
          (order '())
          (frontier (list from-name)))
      (setf (gethash from-name visited) t)
      (loop while frontier do
        (let ((next '()))
          (dolist (name frontier)
            (push name order)
            (dolist (successor (gethash name successors))
              (unless (gethash successor visited)
                (setf (gethash successor visited) t)
                (push successor next))))
          (setf frontier (nreverse next))))
      (nreverse order))))

(defun graph-dfs-order (graph from)
  "Return the node names reachable from FROM in depth-first preorder, starting with
FROM, each appearing once. The name-least successor is descended first. Iterative
(explicit stack), so deep graphs are safe."
  (let ((from-name (%node-designator-name from)))
    (%ensure-graph-node graph from-name)
    (let ((successors (%graph-adjacency-snapshot graph :successors))
          (visited (make-hash-table :test #'equal))
          (order '())
          (stack (list from-name)))
      (loop while stack do
        (let ((name (pop stack)))
          (unless (gethash name visited)
            (setf (gethash name visited) t)
            (push name order)
            (dolist (successor (reverse (gethash name successors)))
              (unless (gethash successor visited)
                (push successor stack))))))
      (nreverse order))))

(defun graph-eccentricity (graph node)
  "Return the eccentricity of NODE: the greatest hop distance to any node reachable
from it, or 0 when NODE reaches nothing."
  (let ((distances (mapcar #'cdr (graph-distances-from graph node))))
    (if distances
        (reduce #'max distances)
        0)))

(defun %graph-eccentricities (graph)
  "Return an alist (NAME . ECCENTRICITY), ordered like GRAPH-NODE-NAMES."
  (loop for name in (graph-node-names graph)
        collect (cons name (graph-eccentricity graph name))))

(defun graph-closeness-centrality (graph node)
  "Return the closeness centrality of NODE: the number of nodes reachable from it
divided by the total hop distance to all of them, or 0 when NODE reaches nothing. A
higher value means NODE reaches the rest of the graph in fewer hops on average."
  (let* ((distances (mapcar #'cdr (graph-distances-from graph node)))
         (total (reduce #'+ distances :initial-value 0)))
    (if (zerop total)
        0
        (/ (length distances) total))))

(defun %betweenness-bfs (source names successors)
  "Brandes' BFS phase from SOURCE over SUCCESSORS. Returns (VALUES STACK
PREDECESSORS SIGMA): STACK holds every reached node in farthest-last visit
order (so the accumulation phase can walk it farthest-first), PREDECESSORS
maps each node to its shortest-path predecessors from SOURCE, and SIGMA counts
the number of distinct shortest paths from SOURCE to each node."
  (let ((stack '())
        (predecessors (%make-result-table))
        (sigma (%make-result-table))
        (distance (%make-result-table)))
    (dolist (name names)
      (setf (gethash name predecessors) '()
            (gethash name sigma) 0
            (gethash name distance) -1))
    (setf (gethash source sigma) 1
          (gethash source distance) 0)
    (with-fifo-queue (queue enqueue source)
      (loop while queue do
        (let ((v (pop queue)))
          (push v stack)
          (dolist (w (gethash v successors))
            (when (< (gethash w distance) 0)
              (setf (gethash w distance) (1+ (gethash v distance)))
              (enqueue w))
            (when (= (gethash w distance) (1+ (gethash v distance)))
              (incf (gethash w sigma) (gethash v sigma))
              (push v (gethash w predecessors)))))))
    (values stack predecessors sigma)))

(defun %betweenness-accumulate (source names stack predecessors sigma betweenness)
  "Brandes' dependency-accumulation phase: fold one SOURCE's BFS (STACK,
PREDECESSORS, SIGMA) into BETWEENNESS. Walking STACK farthest-first guarantees
every node's own dependency total is finished before it contributes to its
predecessors', so each node's share of the shortest paths through it is added
to BETWEENNESS exactly once."
  (let ((delta (%make-result-table)))
    (dolist (name names)
      (setf (gethash name delta) 0))
    (dolist (w stack)
      (dolist (v (gethash w predecessors))
        (incf (gethash v delta)
              (* (/ (gethash v sigma) (gethash w sigma))
                 (+ 1 (gethash w delta)))))
      (unless (equal w source)
        (incf (gethash w betweenness) (gethash w delta))))))

(defun graph-betweenness-centrality (graph)
  "Return an alist (NAME . SCORE) of unnormalised betweenness centrality: for each
node, the total over all ordered source/target pairs of the fraction of shortest
paths between them that pass through the node. Computed with Brandes' algorithm over
unweighted directed edges (iterative BFS plus reverse dependency accumulation, so
deep graphs are safe). Ordered by name."
  (let ((names (%graph-node-name-set graph))
        (successors (%graph-adjacency-snapshot graph :successors))
        (betweenness (%make-result-table)))
    (dolist (name names)
      (setf (gethash name betweenness) 0))
    (dolist (source names)
      (multiple-value-bind (stack predecessors sigma)
          (%betweenness-bfs source names successors)
        (%betweenness-accumulate source names stack predecessors sigma betweenness)))
    (sort (loop for name being the hash-keys of betweenness using (hash-value score)
                collect (cons name score))
          #'string< :key #'car)))

;;; --- Graph extremum-eccentricity metrics (data + macro) -------------------
;;; DIAMETER/RADIUS report the extreme eccentricity VALUE over the graph;
;;; CENTER/PERIPHERY report the NAMES whose eccentricity equals that extreme.
;;; Both pairs share the same fold-over-%GRAPH-ECCENTRICITIES shape, differing
;;; only in which comparator (#'MAX or #'MIN) picks the extremum, so each pair
;;; is generated from a schema of (NAME COMPARATOR DOCSTRING) specs instead of
;;; being hand-written per function.

(defmacro define-graph-extremum-eccentricity (&body specs)
  `(progn
     ,@(mapcar (lambda (spec)
                 (destructuring-bind (defun-name comparator docstring) spec
                   `(defun ,defun-name (graph)
                      ,docstring
                      (let ((eccentricities (mapcar #'cdr (%graph-eccentricities graph))))
                        (if eccentricities (reduce ,comparator eccentricities) 0)))))
               specs)))

(define-graph-extremum-eccentricity
  (graph-diameter #'max
   "Return the diameter of GRAPH: the largest eccentricity over all nodes -- the
longest shortest-path distance between any reachable pair. 0 for a graph with no
edges.")
  (graph-radius #'min
   "Return the radius of GRAPH: the smallest eccentricity over all nodes. Under the
directed, reaches-nothing-is-0 eccentricity convention (see GRAPH-ECCENTRICITY),
any sink node makes the radius 0. 0 for a graph with no nodes."))

(defmacro define-graph-extremum-eccentricity-names (&body specs)
  `(progn
     ,@(mapcar (lambda (spec)
                 (destructuring-bind (defun-name comparator docstring) spec
                   `(defun ,defun-name (graph)
                      ,docstring
                      (let ((eccentricities (%graph-eccentricities graph)))
                        (when eccentricities
                          (let ((extremum (reduce ,comparator eccentricities :key #'cdr)))
                            (loop for (name . eccentricity) in eccentricities
                                  when (= eccentricity extremum)
                                  collect name)))))))
               specs)))

(define-graph-extremum-eccentricity-names
  (graph-center #'min
   "Return the center of GRAPH: the names of the nodes whose eccentricity equals the
radius, ordered lexicographically. These are the nodes closest (in worst-case hops)
to everything they reach. Empty for a graph with no nodes.")
  (graph-periphery #'max
   "Return the periphery of GRAPH: the names of the nodes whose eccentricity equals
the diameter, ordered lexicographically -- the most far-reaching nodes, those whose
shortest paths stretch the whole diameter. Empty for a graph with no nodes."))

(defun %graph-distance-totals (graph)
  "Return (values SUM COUNT) over the shortest-path hop distances of every ordered
pair of distinct nodes whose target is reachable from its source. Self-returns
through cycles are excluded so a node is never paired with itself."
  (let ((sum 0)
        (count 0))
    (dolist (name (graph-node-names graph))
      (dolist (entry (graph-distances-from graph name))
        (unless (equal (car entry) name)
          (incf sum (cdr entry))
          (incf count))))
    (values sum count)))

(defun graph-wiener-index (graph)
  "Return the Wiener index of GRAPH: the sum of shortest-path hop distances over
every ordered pair of distinct nodes for which the target is reachable from the
source. Unreachable pairs contribute nothing. 0 for a graph with no edges."
  (values (%graph-distance-totals graph)))

(defun graph-average-path-length (graph)
  "Return the average shortest-path length of GRAPH: its Wiener index divided by the
number of reachable ordered pairs of distinct nodes. 0 when no node reaches another
(no such pairs), so it never divides by zero."
  (multiple-value-bind (sum count) (%graph-distance-totals graph)
    (if (zerop count)
        0
        (/ sum count))))
