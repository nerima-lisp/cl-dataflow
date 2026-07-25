(in-package #:cl-dataflow)

;;;; Structural primitives: order/size/emptiness, adjacency and neighbour
;;;; accessors, degree, transpose, acyclicity, topological generations, and
;;;; self-loop detection. Also home to WITH-FIFO-QUEUE, the shared
;;;; tail-pointer FIFO used by every breadth-first search in the graph-*.lisp
;;;; family (graph-distance.lisp, graph-flow.lisp), since it must load before
;;;; all of them. Everything here is built on the same one-shot Prolog
;;;; adjacency snapshot the rest of the graph runtime uses (see
;;;; %GRAPH-ADJACENCY / %GRAPH-DIRECTIONAL-ADJACENCY): every traversal
;;;; materialises adjacency once and walks it with an explicit work list --
;;;; never per-node Prolog queries and never unbounded recursion -- so the
;;;; algorithms stay linear and terminate on deep chains and on cyclic graphs.

(defmacro with-fifo-queue ((queue-var enqueue-name &rest initial-values) &body body)
  "Bind QUEUE-VAR to a FIFO work queue seeded with INITIAL-VALUES and ENQUEUE-NAME
to a local function that appends one value to it in O(1) via a hidden tail
pointer, then evaluate BODY. Every breadth-first search in this codebase shares
this enqueue bookkeeping but differs in its own visited/relaxation guard, so
only the queue mechanics are factored out here; BODY still drives the
traversal itself, typically `(loop while QUEUE-VAR do (pop QUEUE-VAR) ...)`."
  (let ((tail (gensym "TAIL")))
    `(let* ((,queue-var (list ,@initial-values))
            (,tail ,queue-var))
       (labels ((,enqueue-name (value)
                  (let ((cell (list value)))
                    (if ,queue-var
                        (setf (cdr ,tail) cell ,tail cell)
                        (setf ,queue-var cell ,tail cell)))))
         ,@body))))

(defun %graph-node-name-set (graph)
  "Sorted list of every node name in GRAPH."
  (sort (%hash-table-keys (%graph-nodes-table graph)) #'string<))

(defun %edge-identity-key (from from-port to to-port)
  "A single NUL-joined string uniquely identifying an edge by its endpoints and
ports. Comparing these keys with EQUAL avoids a multi-clause AND (whose per-clause
false arms are hard to exercise) when matching or ordering edges."
  (format nil "~A~C~A~C~A~C~A" from #\Nul from-port #\Nul to #\Nul to-port))

(defun graph-node-names (graph)
  "Return the names of every node in GRAPH, ordered lexicographically."
  (%graph-node-name-set graph))

(defun graph-order (graph)
  "Return the number of nodes in GRAPH (its order)."
  (hash-table-count (%graph-nodes-table graph)))

(defun graph-size (graph)
  "Return the number of edges in GRAPH (its size). Parallel edges across distinct
ports are counted individually, matching GRAPH-EDGES."
  (length (%graph-edges-list graph)))

(defun graph-empty-p (graph)
  "Return true when GRAPH has no nodes."
  (zerop (graph-order graph)))

(defun %graph-adjacency-snapshot (graph direction)
  "Name -> sorted-neighbour-names table for GRAPH in DIRECTION (:successors or
:predecessors). Isolated graphs (no edges) skip the Prolog query entirely."
  (if (%graph-edges-list graph)
      (%graph-directional-adjacency graph (%graph-rulebase graph) direction)
      (let ((adjacency (%make-result-table)))
        (maphash (lambda (name node)
                   (declare (ignore node))
                   (setf (gethash name adjacency) '()))
                 (%graph-nodes-table graph))
        adjacency)))

(defun %graph-both-adjacencies (graph)
  "Return (VALUES successor-table predecessor-table) for GRAPH. Callers that
need both directions build the underlying Prolog rulebase once and reuse it
for both directional queries, instead of calling %GRAPH-ADJACENCY-SNAPSHOT
twice -- which would rebuild an equivalent rulebase from scratch each time."
  (if (%graph-edges-list graph)
      (let ((rulebase (%graph-rulebase graph)))
        (values (%graph-directional-adjacency graph rulebase :successors)
                (%graph-directional-adjacency graph rulebase :predecessors)))
      (values (%graph-adjacency-snapshot graph :successors)
              (%graph-adjacency-snapshot graph :predecessors))))

(defun %graph-neighbor-name (edge name direction)
  (ecase direction
    (:successors (when (equal (edge-from edge) name) (edge-to edge)))
    (:predecessors (when (equal (edge-to edge) name) (edge-from edge)))))

(defun %graph-neighbor-names (graph name direction)
  (let ((seen (make-hash-table :test #'equal))
        (neighbors '()))
    (dolist (edge (%graph-edges-list graph)
             (sort neighbors #'string<))
      (let ((neighbor (%graph-neighbor-name edge name direction)))
        (when (and neighbor (not (gethash neighbor seen)))
          (setf (gethash neighbor seen) t)
          (push neighbor neighbors))))))

(defun %graph-neighbor-nodes (graph node direction)
  (let ((name (%node-designator-name node)))
    (%ensure-graph-node graph name)
    (let ((nodes (%graph-nodes-table graph)))
      (mapcar (lambda (neighbor)
                 (%copy-node-snapshot (gethash neighbor nodes)))
              (%graph-neighbor-names graph name direction)))))

(defun graph-successors (graph node)
  "Return copies of the immediate successor nodes of NODE (one edge away),
ordered by name."
  (%graph-neighbor-nodes graph node :successors))

(defun graph-predecessors (graph node)
  "Return copies of the immediate predecessor nodes of NODE (one edge away),
ordered by name."
  (%graph-neighbor-nodes graph node :predecessors))

(defun graph-out-degree (graph node)
  "Return the number of distinct successor nodes of NODE. Distinct (from . to)
pairs are counted once, matching the indegree convention in %GRAPH-ADJACENCY."
  (let ((name (%node-designator-name node)))
    (%ensure-graph-node graph name)
    (length (%graph-neighbor-names graph name :successors))))

(defun graph-in-degree (graph node)
  "Return the number of distinct predecessor nodes of NODE."
  (let ((name (%node-designator-name node)))
    (%ensure-graph-node graph name)
    (length (%graph-neighbor-names graph name :predecessors))))

(defun graph-transpose (graph)
  "Return a new graph with every edge reversed.

Node identities, ports and metadata are preserved; each reversed edge B -> A is
attached to B's first output port and A's first input port, since the original
edge's ports need not be valid in the reversed direction. The transpose is meant
for structural analysis (reversed reachability, ancestors-as-descendants), so it
carries topology faithfully while remaining a fully valid, inspectable graph."
  (let ((result (make-graph :metadata (graph-metadata graph)))
        (nodes (%graph-nodes-table graph)))
    (dolist (name (%graph-node-name-set graph))
      (add-node result (%copy-node-snapshot (gethash name nodes))))
    (dolist (edge (reverse (%graph-edges-list graph)))
      (let ((from (gethash (edge-to edge) nodes))
            (to (gethash (edge-from edge) nodes)))
        (add-edge result (edge-to edge) (edge-from edge)
                  :from-port (first (%node-outputs-list from))
                  :to-port (first (%node-inputs-list to)))))
    result))

(defun graph-acyclic-p (graph)
  "Return true when GRAPH contains no directed cycle."
  (handler-case (progn (topological-sort graph) t)
    (graph-cycle-error () nil)))

(defun graph-topological-generations (graph)
  "Return the topological generations of GRAPH: a list of layers, where layer 0
holds every source (indegree 0), layer 1 holds the nodes that become sources once
layer 0 is removed, and so on. Each layer is a list of node copies ordered by
name. Signals GRAPH-CYCLE-ERROR when GRAPH is cyclic, matching TOPOLOGICAL-SORT."
  (let ((nodes (%graph-nodes-table graph))
        (rulebase (%graph-rulebase graph)))
    (multiple-value-bind (successors indegree)
        (%graph-adjacency graph rulebase)
      (let ((generations '())
            (processed (%make-result-table))
            (frontier (%zero-indegree-names indegree)))
        (loop while frontier do
          (push (mapcar (lambda (name) (%copy-node-snapshot (gethash name nodes)))
                        frontier)
                generations)
          (dolist (name frontier)
            (setf (gethash name processed) t))
          (let ((next '()))
            (dolist (name frontier)
              (dolist (successor (gethash name successors))
                (when (zerop (decf (gethash successor indegree)))
                  (push successor next))))
            (setf frontier (sort next #'string<))))
        (unless (= (hash-table-count processed) (hash-table-count nodes))
          (error 'graph-cycle-error
                 :graph graph
                 :nodes (mapcar #'%copy-node-snapshot
                                (%unprocessed-cycle-nodes nodes processed))
                 :detail "Graph contains a cycle; topological generations are undefined."))
        (nreverse generations)))))

(defun %zero-indegree-names (indegree)
  (let ((names '()))
    (maphash (lambda (name count)
               (when (zerop count) (push name names)))
             indegree)
    (sort names #'string<)))

(defun graph-self-loop-nodes (graph)
  "Return the names of nodes carrying a self-loop edge, ordered lexicographically."
  (sort (remove-duplicates
         (loop for edge in (%graph-edges-list graph)
               when (equal (edge-from edge) (edge-to edge))
               collect (edge-from edge))
         :test #'equal)
        #'string<))
