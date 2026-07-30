(in-package #:cl-dataflow)

;;;; Whole-graph metrics: edge density, degree distribution, bipartiteness,
;;;; clustering, reciprocity, and weak (undirected) reachability. GRAPH-EQUAL-P
;;;; lives in equality-predicates.lisp alongside the other structural-equality
;;;; predicates it shares a plist-comparison contract with. Predicates here reuse
;;;; the connected-component / adjacency machinery rather than re-deriving structure.

(defun %distinct-edge-count (graph)
  "Number of distinct (from . to) pairs in GRAPH; parallel edges count once."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (edge (%graph-edges-list graph))
      (setf (gethash (cons (edge-from edge) (edge-to edge)) seen) t))
    (hash-table-count seen)))

(defun graph-density (graph)
  "Return the directed edge density of GRAPH: distinct edges divided by the maximum
possible V*(V-1). Returns 0 when GRAPH has fewer than two nodes. Parallel edges
across distinct ports count once."
  (let ((order (graph-order graph)))
    (if (< order 2)
        0
        (/ (%distinct-edge-count graph) (* order (1- order))))))

(defun graph-degree-histogram (graph)
  "Return an alist (DEGREE . COUNT) over each node's total degree -- the number of
distinct successors plus distinct predecessors -- ordered by ascending degree."
  (multiple-value-bind (successors predecessors) (%graph-both-adjacencies graph)
    (let ((counts (make-hash-table :test #'eql)))
      (dolist (name (%graph-node-name-set graph))
        (incf (gethash (+ (length (gethash name successors))
                          (length (gethash name predecessors)))
                       counts 0)))
      (sort (loop for degree being the hash-keys of counts using (hash-value count)
                  collect (cons degree count))
            #'< :key #'car))))

(defun graph-bipartite-p (graph)
  "Return true when GRAPH's underlying undirected graph is 2-colourable (bipartite).
Edge direction is ignored; a self-loop makes the graph non-bipartite."
  (let ((adjacency (%undirected-adjacency graph))
        (color (make-hash-table :test #'equal)))
    (block done
      (labels ((expand-frontier (frontier)
                 "Colour every uncoloured neighbour of a name in FRONTIER
opposite its own name's colour, and return the next frontier -- or return
NIL from DONE the moment two adjacent names already share a colour."
                 (let ((next '()))
                   (dolist (name frontier)
                     (let ((name-color (gethash name color)))
                       (dolist (neighbor (gethash name adjacency))
                         (let ((neighbor-color (gethash neighbor color)))
                           (cond
                             ((null neighbor-color)
                              (setf (gethash neighbor color) (- 1 name-color))
                              (push neighbor next))
                             ((= neighbor-color name-color)
                              (return-from done nil)))))))
                   next)))
        (dolist (start (%graph-node-name-set graph) t)
          (unless (gethash start color)
            (setf (gethash start color) 0)
            (let ((frontier (list start)))
              (loop while frontier do
                (setf frontier (expand-frontier frontier))))))))))

(defun graph-greedy-coloring (graph)
  "Return an alist (NAME . COLOR) assigning each node a non-negative integer color so
that adjacent nodes (edge direction ignored) never share a color, using greedy
first-fit over nodes in name order. Graph colouring is NP-hard, so the result is a
valid but not necessarily minimum colouring; it generalises GRAPH-BIPARTITE-P (which
tests for a valid 2-colouring). Ordered by name."
  (let ((adjacency (%undirected-adjacency graph))
        (color (make-hash-table :test #'equal)))
    (dolist (name (%graph-node-name-set graph))
      (let ((used (make-hash-table :test #'eql)))
        (dolist (neighbor (gethash name adjacency))
          (let ((neighbor-color (gethash neighbor color)))
            (when neighbor-color
              (setf (gethash neighbor-color used) t))))
        (let ((candidate 0))
          (loop while (gethash candidate used) do (incf candidate))
          (setf (gethash name color) candidate))))
    (sort (loop for name being the hash-keys of color using (hash-value assigned)
                collect (cons name assigned))
          #'string< :key #'car)))

(defun graph-undirected-reachable-p (graph from to)
  "Return true when FROM and TO lie in the same weakly connected component of GRAPH
(edge direction ignored). A node is always undirected-reachable from itself."
  (let ((from-name (%ensure-graph-node-name graph from))
        (to-name (%ensure-graph-node-name graph to)))
    (let ((component (find-if (lambda (names) (member from-name names :test #'equal))
                              (graph-connected-components graph))))
      (and (member to-name component :test #'equal) t))))

(defun %undirected-neighbor-sets (graph)
  "Name -> hash set of distinct undirected neighbours, excluding the node itself so
self-loops never inflate a neighbourhood."
  (let ((adjacency (%undirected-adjacency graph))
        (result (%make-result-table)))
    (maphash (lambda (name neighbors)
               (let ((set (make-hash-table :test #'equal)))
                 (dolist (neighbor neighbors)
                   (unless (equal neighbor name)
                     (setf (gethash neighbor set) t)))
                 (setf (gethash name result) set)))
             adjacency)
    result))

(defun %clustering-coefficient-for-sets (name sets)
  "The local clustering coefficient of NAME read from SETS (as built by
%UNDIRECTED-NEIGHBOR-SETS), so a whole-graph caller that already has SETS never
rebuilds it per node."
  (let* ((neighbors (loop for neighbor being the hash-keys of (gethash name sets)
                          collect neighbor))
         (degree (length neighbors)))
    (if (< degree 2)
        0
        (let ((links 0))
          (loop for tail on neighbors
                for left = (car tail)
                do (dolist (right (cdr tail))
                     (when (gethash right (gethash left sets))
                       (incf links))))
          (/ links (/ (* degree (1- degree)) 2))))))

(defun graph-clustering-coefficient (graph node)
  "Return the local clustering coefficient of NODE over GRAPH's undirected view: the
fraction of the pairs of NODE's distinct neighbours that are themselves adjacent (how
close the neighbourhood is to a clique). 0 when NODE has fewer than two neighbours.
Edge direction and self-loops are ignored; parallel edges count once."
  (let ((name (%ensure-graph-node-name graph node)))
    (%clustering-coefficient-for-sets name (%undirected-neighbor-sets graph))))

(defun graph-average-clustering (graph)
  "Return the average local clustering coefficient over every node of GRAPH -- the
mean of GRAPH-CLUSTERING-COEFFICIENT, a global measure of how tightly neighbourhoods
cluster. 0 for a graph with no nodes.

The undirected neighbour sets are built once and shared across every node instead
of GRAPH-CLUSTERING-COEFFICIENT's one-rebuild-per-call, so this stays O(V+E) instead
of O(V*(V+E))."
  (let ((names (graph-node-names graph)))
    (if names
        (let ((sets (%undirected-neighbor-sets graph)))
          (/ (reduce #'+ (mapcar (lambda (name)
                                   (%clustering-coefficient-for-sets name sets))
                                 names))
             (length names)))
        0)))

(defun graph-reciprocity (graph)
  "Return the reciprocity of GRAPH: the fraction of its distinct directed edges
(FROM -> TO with FROM /= TO) whose reverse edge TO -> FROM is also present. Parallel
edges count once and self-loops are ignored. 0 when GRAPH has no non-loop edges."
  (let ((pairs (make-hash-table :test #'equal)))
    (dolist (edge (%graph-edges-list graph))
      (let ((from (edge-from edge))
            (to (edge-to edge)))
        (unless (equal from to)
          (setf (gethash (cons from to) pairs) t))))
    (let ((total 0)
          (mutual 0))
      (maphash (lambda (pair present)
                 (declare (ignore present))
                 (incf total)
                 (when (gethash (cons (cdr pair) (car pair)) pairs)
                   (incf mutual)))
               pairs)
      (if (zerop total)
          0
          (/ mutual total)))))
