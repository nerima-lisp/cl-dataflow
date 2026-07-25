(in-package #:cl-dataflow)

;;;; cl-prolog-backed graph traversal: the node/edge relation is materialized
;;;; into a rulebase and read with one bulk QUERY-PROLOG call per traversal
;;;; (not one query per node), then walked in pure Lisp -- GRAPH-REACHABLE-P,
;;;; GRAPH-PATH, GRAPH-ANCESTORS, and GRAPH-DESCENDANTS all stay linear and
;;;; stack-safe on deep or cyclic graphs.

(defparameter +graph-node-predicate+ 'graph-node)
(defparameter +graph-edge-predicate+ 'graph-edge)

(defun %graph-rulebase (graph)
  (let ((clauses '()))
    (maphash (lambda (name node)
                (declare (ignore node))
                (push (cl-prolog:make-clause
                      (list +graph-node-predicate+ name)
                      '())
                      clauses))
              (%graph-nodes-table graph))
    (dolist (edge (%graph-edges-list graph))
      (unless (and (gethash (edge-from edge) (%graph-nodes-table graph))
                    (gethash (edge-to edge) (%graph-nodes-table graph)))
        (%signal-node-not-found-error
          graph
          edge
          (format nil "Edge references missing node: ~A -> ~A"
                  (%escaped-display-string (edge-from edge))
                  (%escaped-display-string (edge-to edge)))))
      (push (cl-prolog:make-clause
              (list +graph-edge-predicate+
                    (edge-from edge)
                    (edge-to edge))
              '())
            clauses))
    (cl-prolog:make-rulebase :clauses (nreverse clauses))))

(defun %graph-adjacency (graph rulebase)
  "Return (VALUES successor-table indegree-table) for GRAPH.

The full graph-edge relation is read with a single bulk Prolog query instead of
one predecessor/successor query per node, so building the traversal state is
linear in the number of edges rather than O(V*E). Distinct (from . to) pairs are
counted once, so parallel edges across different ports do not inflate indegree --
matching the deduplicating per-node queries this replaces. Successor lists are
sorted so downstream traversal order stays deterministic."
  (let ((successors (%make-result-table))
        (indegree (%make-result-table))
        (seen-pairs (make-hash-table :test #'equal)))
    (maphash (lambda (name node)
                (declare (ignore node))
                (setf (gethash name indegree) 0)
                (setf (gethash name successors) '()))
              (%graph-nodes-table graph))
    (when (%graph-edges-list graph)
      (dolist (solution (cl-prolog:query-prolog
                          rulebase
                          (list +graph-edge-predicate+ '?from '?to)))
        (let* ((from (cl-prolog:solution-binding '?from solution))
                (to (cl-prolog:solution-binding '?to solution))
                (pair (cons from to)))
          (unless (gethash pair seen-pairs)
            (setf (gethash pair seen-pairs) t)
            (push to (gethash from successors))
            (incf (gethash to indegree))))))
    (maphash (lambda (name succ)
                (setf (gethash name successors) (sort succ #'string<)))
              successors)
    (values successors indegree)))

(defun graph-reachable-p (graph from to)
  "Return true when TO is reachable from FROM through one or more graph edges.

The successor relation is materialised once with a single bulk query (see
%graph-adjacency) and then walked with an explicit work list in pure Lisp. That
keeps the search linear in the reachable subgraph (one Prolog query rather than
two per visited node), bounds stack usage regardless of path length, and
terminates cleanly on cycles via the shared VISITED set."
  (let ((from-name (%node-designator-name from))
        (to-name (%node-designator-name to)))
    (%ensure-graph-node graph from-name)
    (%ensure-graph-node graph to-name)
    (when (%graph-edges-list graph)
      (let* ((rulebase (%graph-rulebase graph))
             (successors (%graph-adjacency graph rulebase))
             (visited (make-hash-table :test #'equal))
             ;; Seed with FROM's direct successors: reaching TO must cross at
             ;; least one edge, so a self-loop is honoured while a bare
             ;; FROM = TO with no edge is not "reachable".
             (worklist (copy-list (gethash from-name successors))))
        (loop while worklist do
          (let ((name (pop worklist)))
            (when (equal name to-name)
              (return t))
            (unless (gethash name visited)
              (setf (gethash name visited) t)
              (dolist (successor (gethash name successors))
                (unless (gethash successor visited)
                  (push successor worklist))))))))))

(defun %graph-directional-adjacency (graph rulebase direction)
  "Return a name -> sorted-neighbor-names table for GRAPH from one bulk edge
query. DIRECTION is :successors (edge from -> to) or :predecessors (edge to ->
from). Distinct (from . to) pairs are counted once."
  (let ((adjacency (%make-result-table))
        (seen-pairs (make-hash-table :test #'equal)))
    (maphash (lambda (name node)
                (declare (ignore node))
                (setf (gethash name adjacency) '()))
              (%graph-nodes-table graph))
    (dolist (solution (cl-prolog:query-prolog
                        rulebase
                        (list +graph-edge-predicate+ '?from '?to)))
      (let* ((from (cl-prolog:solution-binding '?from solution))
              (to (cl-prolog:solution-binding '?to solution))
              (pair (cons from to)))
        (unless (gethash pair seen-pairs)
          (setf (gethash pair seen-pairs) t)
          (ecase direction
            (:successors (push to (gethash from adjacency)))
            (:predecessors (push from (gethash to adjacency)))))))
    (maphash (lambda (name neighbors)
                (setf (gethash name adjacency) (sort neighbors #'string<)))
              adjacency)
    adjacency))

(defun %reachable-closure (adjacency start-name)
  "Sorted names reachable from START-NAME through one or more hops in ADJACENCY.

Seeding the work list with START-NAME's direct neighbours means the closure
follows the same one-or-more-edges rule as GRAPH-REACHABLE-P: in a cycle a node
appears in its own closure, but an isolated node's closure is empty."
  (let ((visited (make-hash-table :test #'equal))
        (worklist (copy-list (gethash start-name adjacency))))
    (loop while worklist do
      (let ((name (pop worklist)))
        (unless (gethash name visited)
          (setf (gethash name visited) t)
          (dolist (next (gethash name adjacency))
            (unless (gethash next visited)
              (push next worklist))))))
    (sort (%hash-table-keys visited) #'string<)))

(defun %graph-closure-nodes (graph node direction)
  (let ((name (%node-designator-name node)))
    (%ensure-graph-node graph name)
    (let ((names (if (%graph-edges-list graph)
                     (%reachable-closure
                      (%graph-directional-adjacency graph (%graph-rulebase graph) direction)
                      name)
                     '()))
          (nodes (%graph-nodes-table graph)))
      (mapcar (lambda (reached)
                (%copy-node-snapshot (gethash reached nodes)))
              names))))

(defun graph-descendants (graph node)
  "Return copies of every node reachable FROM NODE through one or more edges,
ordered by name. Uses the same bulk-query traversal as GRAPH-REACHABLE-P, so it
is linear and terminates on cyclic graphs."
  (%graph-closure-nodes graph node :successors))

(defun graph-ancestors (graph node)
  "Return copies of every node that can reach NODE through one or more edges,
ordered by name."
  (%graph-closure-nodes graph node :predecessors))

(defun %reconstruct-path (parent from-name to-name)
  "Rebuild the FROM-NAME ... TO-NAME path from a BFS PARENT table. TO-NAME must
have a parent entry; the first step is taken through PARENT so a FROM = TO cycle
yields the whole loop rather than a single node."
  (let ((path (list to-name))
        (cursor (gethash to-name parent)))
    (loop
      (push cursor path)
      (when (equal cursor from-name)
        (return))
      (setf cursor (gethash cursor parent)))
    path))

(defun graph-path (graph from to)
  "Return the node names of a shortest path from FROM to TO through one or more
edges (FROM first, TO last), or NIL when TO is unreachable from FROM.

Breadth-first search over the single-query successor adjacency gives a shortest
witness in linear time; PARENT is recorded on first discovery, and seeding with
FROM's direct successors keeps the one-or-more-edges rule (so FROM = TO resolves
only through a cycle)."
  (let ((from-name (%node-designator-name from))
        (to-name (%node-designator-name to)))
    (%ensure-graph-node graph from-name)
    (%ensure-graph-node graph to-name)
    (when (%graph-edges-list graph)
      (let ((successors (%graph-adjacency graph (%graph-rulebase graph)))
            (parent (make-hash-table :test #'equal))
            (enqueued (make-hash-table :test #'equal))
            (frontier '()))
        ;; SUCCESSORS is already deduped per name by %GRAPH-ADJACENCY's
        ;; SEEN-PAIRS, so no name here can repeat and an ENQUEUED guard would
        ;; never trigger.
        (dolist (successor (gethash from-name successors))
          (setf (gethash successor enqueued) t
                (gethash successor parent) from-name)
          (push successor frontier))
        (setf frontier (nreverse frontier))
        (when (gethash to-name parent)
          (return-from graph-path (%reconstruct-path parent from-name to-name)))
        (labels ((expand-one-level (frontier)
                   "Discover every unvisited successor of a name in FRONTIER,
recording PARENT on first discovery, and return the next frontier -- or
return from GRAPH-PATH immediately once TO-NAME is discovered."
                   (let ((next '()))
                     (dolist (name frontier (nreverse next))
                       (dolist (successor (gethash name successors))
                         (unless (gethash successor enqueued)
                           (setf (gethash successor enqueued) t
                                 (gethash successor parent) name)
                           (when (equal successor to-name)
                             (return-from graph-path
                               (%reconstruct-path parent from-name to-name)))
                           (push successor next)))))))
          (loop while frontier do
            (setf frontier (expand-one-level frontier))))))))
