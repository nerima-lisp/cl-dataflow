(in-package #:cl-dataflow-kit)

;;;; Topological ordering and boundary queries: TOPOLOGICAL-SORT (Kahn's
;;;; algorithm, iterative) and GRAPH-SOURCE-NODES/GRAPH-SINK-NODES, all
;;;; reading from a single adjacency snapshot instead of a per-node query.

(defun %incoming-edges (graph node-name)
  (remove-if-not (lambda (edge)
                    (equal (edge-to edge) node-name))
                  (%graph-edges-list graph)))

(defun %incoming-edges-index (graph)
  "Map of node-name -> incoming edges, newest-first per node (matching
%INCOMING-EDGES' order, which %EDGE-BINDING-TABLE relies on to break ties
toward the most recently added edge). Built with a single O(E) pass over the
edge list instead of one O(E) %incoming-edges scan per node: walking the
oldest-first REVERSE of the (already newest-first) edge list and pushing onto
each node's bucket leaves the newest edge at the front of that bucket."
  (let ((index (%make-result-table)))
    (dolist (edge (reverse (%graph-edges-list graph)))
      (push edge (gethash (edge-to edge) index)))
    index))

(defun %boundary-nodes (graph boundary-key)
  "Copies of the graph's source (BOUNDARY-KEY :source) or sink (:sink) nodes,
name-ordered. Boundaries are read from a single adjacency snapshot -- a node
with indegree 0 is a source, a node with no successors is a sink -- instead of
a Prolog query per node. This deliberately does not route through
TOPOLOGICAL-SORT: source/sink membership never depends on topological order,
and requiring acyclicity here would make a legally constructed cyclic graph's
boundaries uninspectable, the same gap GRAPH-NODES/GRAPH-EDGES were fixed to
avoid."
  (let* ((rulebase (%graph-rulebase graph))
         (nodes (%graph-nodes-table graph)))
    (multiple-value-bind (successors indegree)
        (%graph-adjacency graph rulebase)
      (mapcar (lambda (name) (%copy-node-snapshot (gethash name nodes)))
              (sort (remove-if-not
                      (lambda (name)
                        (ecase boundary-key
                          (:source (zerop (gethash name indegree)))
                          (:sink (null (gethash name successors)))))
                      (%hash-table-keys nodes))
                    #'string<)))))

(defun graph-source-nodes (graph)
  (%boundary-nodes graph :source))

(defun graph-sink-nodes (graph)
  (%boundary-nodes graph :sink))

(defun %seed-topological-queue (indegree)
  (let ((queue '()))
    (maphash (lambda (name count)
                (declare (ignore count))
                (when (zerop (gethash name indegree))
                  (push name queue)))
              indegree)
    (sort queue #'string<)))

(defun %drain-topological-queue (queue successors indegree nodes)
  "Kahn's algorithm over precomputed SUCCESSORS/INDEGREE tables.

The ready queue is kept in string< order by merging each batch of newly-ready
successors into it, so it never re-sorts the whole queue per iteration yet still
pops the lexicographically smallest ready node -- giving a deterministic order
identical to the previous full-re-sort implementation."
  (let ((result '())
        (processed (%make-result-table)))
    (loop while queue do
      (let* ((name (pop queue))
              (node (gethash name nodes))
              (newly-ready '()))
        (push node result)
        (setf (gethash name processed) t)
        (dolist (successor (gethash name successors))
          (when (zerop (decf (gethash successor indegree)))
            (push successor newly-ready)))
        (when newly-ready
          (setf queue (merge 'list queue (sort newly-ready #'string<) #'string<)))))
    (values (nreverse result) processed)))

(defun %unprocessed-cycle-nodes (nodes processed)
  (let ((cycle-nodes '()))
    (maphash (lambda (name node)
                (unless (gethash name processed)
                  (push node cycle-nodes)))
              nodes)
    (sort cycle-nodes #'string< :key #'node-name)))

(defun topological-sort (graph)
  (let ((nodes (%graph-nodes-table graph))
        (rulebase (%graph-rulebase graph)))
    (multiple-value-bind (successors indegree)
        (%graph-adjacency graph rulebase)
      (multiple-value-bind (result processed)
          (%drain-topological-queue (%seed-topological-queue indegree)
                                    successors
                                    indegree
                                    nodes)
        (unless (= (length result) (hash-table-count nodes))
          (error 'graph-cycle-error
                  :graph graph
                  :nodes (mapcar #'%copy-node-snapshot
                                (%unprocessed-cycle-nodes nodes processed))
                  :detail "Graph contains a cycle or disconnected cycle component."))
        result))))
