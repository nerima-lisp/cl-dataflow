(in-package #:cl-dataflow)

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

;;;; Graph analysis built on the same one-shot Prolog adjacency snapshot the rest
;;;; of the graph runtime uses (see %GRAPH-ADJACENCY / %GRAPH-DIRECTIONAL-ADJACENCY).
;;;; Every traversal here materialises adjacency once and walks it with an explicit
;;;; work list -- never per-node Prolog queries and never unbounded recursion -- so
;;;; the algorithms stay linear and terminate on deep chains and on cyclic graphs.

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
  (let* ((names (%graph-node-name-set graph))
         (successors (%graph-adjacency-snapshot graph :successors))
         (predecessors (%graph-adjacency-snapshot graph :predecessors))
         (order (%iterative-dfs-finish-order names successors))
         (assigned (make-hash-table :test #'equal))
         (components '()))
    (dolist (root order)
      (unless (gethash root assigned)
        (push (%collect-component root predecessors assigned) components)))
    (sort components #'string< :key #'first)))

(defun %undirected-adjacency (graph)
  "Name -> set of neighbour names treating every edge as undirected."
  (let ((successors (%graph-adjacency-snapshot graph :successors))
        (predecessors (%graph-adjacency-snapshot graph :predecessors))
        (adjacency (%make-result-table)))
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
    adjacency))

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

(defun graph-distance (graph from to)
  "Return the number of edges on a shortest path from FROM to TO (traversing at
least one edge), or NIL when TO is unreachable from FROM. FROM = TO resolves only
through a cycle, matching GRAPH-PATH / GRAPH-REACHABLE-P."
  (let ((from-name (%node-designator-name from))
        (to-name (%node-designator-name to)))
    (%ensure-graph-node graph from-name)
    (%ensure-graph-node graph to-name)
    (when (%graph-edges-list graph)
      (let ((successors (%graph-adjacency graph (%graph-rulebase graph)))
            (distance (make-hash-table :test #'equal))
            (frontier '())
            (depth 1))
        ;; FROM's direct successors are distinct (adjacency deduplicates), and
        ;; DISTANCE starts empty, so every seed is new -- no presence guard needed.
        (dolist (successor (gethash from-name successors))
          (setf (gethash successor distance) depth)
          (push successor frontier))
        (setf frontier (nreverse frontier))
        (loop
          (when (gethash to-name distance)
            (return (gethash to-name distance)))
          (unless frontier (return nil))
          (incf depth)
          (let ((next '()))
            (dolist (name frontier)
              (dolist (successor (gethash name successors))
                (unless (gethash successor distance)
                  (setf (gethash successor distance) depth)
                  (push successor next))))
            (setf frontier (nreverse next))))))))
