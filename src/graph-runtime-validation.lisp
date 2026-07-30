(in-package #:cl-dataflow)

;;;; Graph mutation and structural validation: ADD-NODE/ADD-EDGE/FIND-NODE and
;;;; the port/duplicate/missing-node checks VALIDATE-GRAPH and every mutator
;;;; run before committing a change.

(defun %signal-graph-error (graph detail)
  (error 'graph-error
          :graph graph
          :detail detail))

(defun %signal-node-not-found-error (graph designator detail)
  (error 'node-not-found-error
          :graph graph
          :designator (%copy-error-value designator)
          :detail detail))

(defun %signal-unknown-edge-port (graph edge kind port)
  (%signal-graph-error
    graph
    (format nil "Edge ~A -> ~A uses unknown ~A port ~A"
            (%escaped-display-string (edge-from edge))
            (%escaped-display-string (edge-to edge))
            kind
            (%escaped-display-string port))))

(defun %validate-node-port-list (graph node kind ports)
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (port ports)
      (when (gethash port seen)
        (%signal-graph-error graph
                              (format nil "Node ~A has duplicate ~A port ~A"
                                      (%escaped-display-string (node-name node))
                                      kind
                                      (%escaped-display-string port))))
      (setf (gethash port seen) t))))

(defun %ensure-node (designator)
  (typecase designator
    (node designator)
    (t (%signal-invalid-input-error
         'node
         (%copy-error-value designator)
         (%expected-object-detail "NODE" designator)))))

(defun %validate-node-port-lists (graph node)
  (%validate-node-port-list graph
                            node
                            "input"
                            (%normalize-port-list (%read-slot node 'inputs)))
  (%validate-node-port-list graph
                            node
                            "output"
                            (%normalize-port-list (%read-slot node 'outputs))))

(defun %ensure-graph-node (graph designator)
  (let* ((name (%node-designator-name designator))
          (node (gethash name (%graph-nodes-table graph))))
    (or node
        (%signal-node-not-found-error graph
                                      designator
                                      (format nil "Node not found: ~A"
                                              (%escaped-display-string name))))))

(defun %ensure-graph-node-name (graph designator)
  "Resolve DESIGNATOR to its name and signal NODE-NOT-FOUND-ERROR unless it
names a node in GRAPH, returning the resolved name. For callers that need
the name string afterward rather than the NODE itself -- %ENSURE-GRAPH-NODE
already resolves DESIGNATOR internally, so calling both would resolve it
twice."
  (let ((name (%node-designator-name designator)))
    (%ensure-graph-node graph name)
    name))

(defun %validate-node-ports (graph edge)
  (let ((from-node (find-node graph (edge-from edge)))
        (to-node (find-node graph (edge-to edge))))
    (unless from-node
      (%signal-node-not-found-error graph
                                    edge
                                    (format nil "Missing source node: ~A"
                                            (%escaped-display-string (edge-from edge)))))
    (unless to-node
      (%signal-node-not-found-error graph
                                    edge
                                    (format nil "Missing destination node: ~A"
                                            (%escaped-display-string (edge-to edge)))))
    (%validate-node-port-lists graph from-node)
    (%validate-node-port-lists graph to-node)
    (unless (member (edge-from-port edge) (%node-outputs-list from-node) :test #'equal)
      (%signal-unknown-edge-port graph edge "output" (edge-from-port edge)))
    (unless (member (edge-to-port edge) (%node-inputs-list to-node) :test #'equal)
      (%signal-unknown-edge-port graph edge "input" (edge-to-port edge)))))

(defun %validate-graph-structure (graph)
  "Validate structural integrity only: node port lists are well formed and every
edge references existing nodes and ports. This is O(V+E) and issues no Prolog
queries, so it is safe to run on the read path. It deliberately does NOT check
acyclicity, so a legally constructed cyclic graph stays inspectable."
  (maphash (lambda (name node)
              (declare (ignore name))
              (%validate-node-port-lists graph node))
            (%graph-nodes-table graph))
  (dolist (edge (%graph-edges-list graph))
    (%validate-node-ports graph edge))
  t)

(defun validate-graph (graph)
  "Full validation: structural integrity plus acyclicity via topological-sort."
  (%validate-graph-structure graph)
  (topological-sort graph)
  t)

(defun add-node (graph node)
  (let ((normalized-node (%ensure-node node)))
    (%validate-node-port-lists graph normalized-node)
    (when (find-node graph (node-name normalized-node))
      (%signal-graph-error graph
                            (format nil "Node already exists: ~A"
                                    (%escaped-display-string
                                     (node-name normalized-node)))))
    (let ((name (node-name normalized-node))
          (nodes (%graph-nodes-table graph)))
      (setf (gethash name nodes) normalized-node))
    normalized-node))

(defun find-node (graph name)
  (gethash (%normalize-name name) (%graph-nodes-table graph)))

(defun %signal-duplicate-edge (graph edge)
  (%signal-graph-error graph
                        (format nil "Edge already exists: ~A:~A -> ~A:~A"
                                (%escaped-display-string (edge-from edge))
                                (%escaped-display-string (edge-from-port edge))
                                (%escaped-display-string (edge-to edge))
                                (%escaped-display-string (edge-to-port edge)))))

(defun add-edge (graph from to &key from-port to-port)
  ;; Multiple edges may legitimately target the same (to . to-port): the graph
  ;; layer is used standalone for reachability/topology (see
  ;; graph-advanced-property-test.lisp's random DAGs, which route many
  ;; predecessors into one node's default "value" port), independent of the
  ;; pipeline binding layer's single-producer-per-port convention. Only exact
  ;; duplicate edges are rejected here; see %EDGE-BINDING-TABLE for how
  ;; pipeline execution resolves multiple producers on one input port.
  (let* ((from-node (%ensure-graph-node graph from))
          (to-node (%ensure-graph-node graph to))
          (edge (make-edge from-node to-node
                          :from-port from-port
                          :to-port to-port)))
    (%validate-node-ports graph edge)
    (when (find-if (lambda (existing)
                      (and (equal (edge-from existing) (edge-from edge))
                          (equal (edge-from-port existing) (edge-from-port edge))
                          (equal (edge-to existing) (edge-to edge))
                          (equal (edge-to-port existing) (edge-to-port edge))))
                    (%graph-edges-list graph))
      (%signal-duplicate-edge graph edge))
    (setf (slot-value graph 'edges)
          (cons edge (%graph-edges-list graph)))
    edge))
