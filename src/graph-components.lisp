(in-package #:cl-dataflow)

;;;; Component analysis: Kosaraju's strongly-connected-components algorithm,
;;;; weakly (undirected) connected components, and the single/multi-component
;;;; predicates and condensation built on top of them. Both passes are
;;;; iterative, so arbitrarily deep or cyclic graphs are safe.

(defun %iterative-dfs-finish-order (names successors)
  "Names of NAMES in decreasing DFS finish time over the SUCCESSORS adjacency.
Implemented with an explicit stack of (name . remaining-successors) frames so
depth is bounded by the heap, not the control stack."
  (let ((visited (make-hash-table :test #'equal))
        (finished '()))
    (dolist (start names)
      (unless (gethash start visited)
        (setf (gethash start visited) t)
        (let ((stack (list (cons start (copy-list (gethash start successors))))))
          (loop while stack do
            (let ((frame (first stack)))
              (if (cdr frame)
                  (let ((next (pop (cdr frame))))
                    (unless (gethash next visited)
                      (setf (gethash next visited) t)
                      (push (cons next (copy-list (gethash next successors))) stack)))
                  (progn
                    (push (car frame) finished)
                    (pop stack))))))))
    ;; FINISHED has the last-finished node at its front, i.e. decreasing finish
    ;; time, which is exactly Kosaraju's second-pass processing order.
    finished))

(defun %collect-component (root adjacency assigned)
  "Names reachable from ROOT through ADJACENCY that are not yet ASSIGNED,
gathered with an explicit work list and marked in ASSIGNED as they are taken."
  (let ((component '())
        (stack (list root)))
    (setf (gethash root assigned) t)
    (loop while stack do
      (let ((name (pop stack)))
        (push name component)
        (dolist (neighbor (gethash name adjacency))
          (unless (gethash neighbor assigned)
            (setf (gethash neighbor assigned) t)
            (push neighbor stack)))))
    (sort component #'string<)))

(defun graph-strongly-connected-components (graph)
  "Return the strongly connected components of GRAPH as a list of lists of node
names. Each component is sorted lexicographically, and the components are ordered
by their smallest member. Every node belongs to exactly one component; a node
with no cycle through it forms a singleton.

Kosaraju's algorithm: one DFS over the successor relation records finish order,
then components are grown by DFS over the predecessor relation in decreasing
finish order. Both passes are iterative, so arbitrarily deep graphs are safe."
  (multiple-value-bind (successors predecessors) (%graph-both-adjacencies graph)
    (let* ((names (%graph-node-name-set graph))
           (order (%iterative-dfs-finish-order names successors))
           (assigned (make-hash-table :test #'equal))
           (components '()))
      (dolist (root order)
        (unless (gethash root assigned)
          (push (%collect-component root predecessors assigned) components)))
      (sort components #'string< :key #'first))))

(defun %undirected-adjacency (graph)
  "Name -> set of neighbour names treating every edge as undirected."
  (multiple-value-bind (successors predecessors) (%graph-both-adjacencies graph)
    (let ((adjacency (%make-result-table)))
      (dolist (name (%graph-node-name-set graph))
        (let ((seen (make-hash-table :test #'equal))
              (neighbors '()))
          (flet ((record (neighbor)
                   (unless (gethash neighbor seen)
                     (setf (gethash neighbor seen) t)
                     (push neighbor neighbors))))
            (dolist (neighbor (gethash name successors))
              (record neighbor))
            (dolist (neighbor (gethash name predecessors))
              (record neighbor)))
          (setf (gethash name adjacency) neighbors)))
      adjacency)))

(defun graph-connected-components (graph)
  "Return the weakly connected components of GRAPH (edges treated as undirected)
as a list of lists of node names. Each component is sorted lexicographically and
the components are ordered by their smallest member."
  (let ((adjacency (%undirected-adjacency graph))
        (assigned (make-hash-table :test #'equal))
        (components '()))
    (dolist (root (%graph-node-name-set graph))
      (unless (gethash root assigned)
        (push (%collect-component root adjacency assigned) components)))
    (sort components #'string< :key #'first)))

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
