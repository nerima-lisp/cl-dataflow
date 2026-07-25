(in-package #:cl-dataflow)

;;;; Resolves how values flow along pipeline edges at run time: turning a
;;;; node's raw result into per-output-port bindings, collecting a node's
;;;; per-input-port bindings from its incoming edges (newest edge wins a
;;;; contested port), and collecting sink nodes' bindings into a pipeline's
;;;; final result shape. The port/edge binding plans are split from value
;;;; reads so a cached execution plan can precompute the plan once and only
;;;; the by-key value lookups run per execution.

(defun %node-output-bindings (node result &optional (outputs (%node-outputs-list node)))
  (cond
    ((null outputs) '())
    ((%single-output-scalar-result-p outputs result)
      (%scalar-output-binding outputs result))
    (t (%normalize-output-structure result outputs))))

(defun %binding-list-p (value)
  (and (listp value) (or (null value) (every #'consp value))))

(defun %single-output-scalar-result-p (outputs result)
  (and (= (length outputs) 1) (not (%binding-list-p result))))

(defun %scalar-output-binding (outputs result)
  (list (cons (first outputs) result)))

(defun %node-input-binding (node input)
  (%normalize-structured-input input (%node-inputs-list node)))

(defun %collapse-single-binding-list (bindings)
  (if (= (length bindings) 1) (cdar bindings)
    bindings))

(defun %edge-binding-table (incoming-edges)
  "Map each input port to the edge that feeds it. INCOMING-EDGES is newest-first
(see ADD-EDGE), so when two edges target the same port -- a graph the pipeline
binding layer cannot represent as two simultaneous producers -- the
most-recently-added edge wins and earlier ones are ignored, rather than the
insertion order silently deciding it the other way."
  (let ((bindings (%make-result-table)))
    (dolist (edge incoming-edges bindings)
      (unless (gethash (edge-to-port edge) bindings)
        (setf (gethash (edge-to-port edge) bindings) edge)))))

(defun %node-input-binding-plan (node incoming-edges)
  (let ((binding-table (%edge-binding-table incoming-edges)))
    (loop for port in (%node-inputs-list node)
          for edge = (gethash port binding-table)
          when edge
            collect (cons port edge))))

(defun %resolve-input-binding-plan (context binding-plan)
  (loop for (port . edge) in binding-plan
        collect (cons port (%read-value context (edge-from edge) (edge-from-port edge)))))

(defun %incoming-edge-bindings (context node incoming-edges)
  (%resolve-input-binding-plan
    context
    (%node-input-binding-plan node incoming-edges)))

(defun %resolve-input-key-plan (context binding-plan)
  (loop for (port . key) in binding-plan
        collect (cons port (%read-value-by-key context key))))

(defun %collect-node-inputs (context graph node input &optional incoming-index)
  (let ((incoming
        (if incoming-index (gethash (node-name node) incoming-index)
          (%incoming-edges graph (node-name node)))))
    (if incoming (%collapse-single-binding-list (%incoming-edge-bindings context node incoming))
      (%node-input-binding node input))))

(defun %sink-output-bindings (context node)
  (loop for port in (%node-outputs-list node)
        collect (cons port (%read-value context (node-name node) port))))

(defun %sink-result-entry (context node)
  (cons (node-name node) (%sink-output-bindings context node)))

(defun %collapse-single-sink-result (sink-entry)
  (let ((values (cdr sink-entry)))
    (if (= (length values) 1) (cdar values)
      values)))

(defun %sink-nodes-in-order (graph order)
  ;; Sinks are the nodes with no outgoing edge. Deriving them from one adjacency
  ;; snapshot keeps pipeline result collection linear; the previous per-node
  ;; predicate rebuilt the whole Prolog rulebase for every node in ORDER.
  (let ((successors (%graph-adjacency graph (%graph-rulebase graph))))
    (remove-if-not (lambda (node)
                      (null (gethash (node-name node) successors)))
                    order)))

(defun %collect-cached-sink-results (context sink-result-plans)
  (let ((sinks
        (mapcar
          (lambda (sink-plan)
            (cons
              (car sink-plan)
              (loop for (port . key) in (cdr sink-plan)
                    collect (cons port (%read-value-by-key context key)))))
          sink-result-plans)))
    (cond
      ((null sinks) nil)
      ((= (length sinks) 1) (%collapse-single-sink-result (first sinks)))
      (t sinks))))

(defun %collect-sink-results (graph context order)
  (let ((sink-nodes (%sink-nodes-in-order graph order)))
    (let ((sinks
          (mapcar
            (lambda (node)
              (%sink-result-entry context node))
            sink-nodes)))
      (cond
        ((null sinks) nil)
        ((= (length sinks) 1) (%collapse-single-sink-result (first sinks)))
        (t sinks)))))
