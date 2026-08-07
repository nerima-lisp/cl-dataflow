(in-package #:cl-dataflow)

;;;; Pipeline execution-plan construction is split from pipeline execution so
;;;; the cached plan's data derivation can evolve independently of the runtime
;;;; loop that consumes it.
(defun %build-pipeline-graph (graph stages)
  (cond
    (graph
     (let ((copied-graph (copy-graph graph)))
       (values
        copied-graph
        (%remap-pipeline-stages
         copied-graph
         (or stages (topological-sort graph))))))
    (stages (%build-sequential-graph stages))
    (t (values (make-graph) '()))))

(defun %copy-pipeline-stage-ports (ports)
  (mapcar #'copy-seq ports))

(defun %make-pipeline-stage-signature (stage)
  (make-instance
   'pipeline-stage-signature
   :node
   stage
   :name
   (copy-seq (node-name stage))
   :inputs
   (%copy-pipeline-stage-ports (%node-inputs-list stage))
   :outputs
   (%copy-pipeline-stage-ports (%node-outputs-list stage))))

(defun %make-pipeline-edge-signature (edge)
  (make-instance
   'pipeline-edge-signature
   :edge
   edge
   :from
   (%copy-structured-value (edge-from edge))
   :from-port
   (%copy-structured-value (edge-from-port edge))
   :to
   (%copy-structured-value (edge-to edge))
   :to-port
   (%copy-structured-value (edge-to-port edge))))

(defun %pipeline-value-key (name port)
  (list name port))

(defun %pipeline-output-key-plan (signature)
  (let ((outputs (%pipeline-stage-signature-outputs signature))
        (name (%pipeline-stage-signature-name signature)))
    (cons
     outputs
     (loop for port in outputs
           collect (cons port (%pipeline-value-key name port))))))

(defun %pipeline-edge-signature-table (edge-signatures)
  "Edge -> its EDGE-SIGNATURE built once so %PIPELINE-INPUT-KEY-PLAN's per-binding
lookup is O(1) instead of rescanning EDGE-SIGNATURES linearly."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (signature edge-signatures)
      (setf (gethash (%pipeline-edge-signature-edge signature) table) signature))
    table))

(defun %pipeline-input-key-plan (binding-plan
                                 target-signature
                                 edge-signature-table)
  (cons
   (car binding-plan)
   (loop for (target-port . edge) in (cdr binding-plan)
         for edge-signature = (gethash edge edge-signature-table)
         for private-target-port = (find
                                    target-port
                                    (%pipeline-stage-signature-inputs
                                     target-signature)
                                    :test
                                    #'equal)
         collect (cons
                  private-target-port
                  (%pipeline-value-key
                   (%pipeline-edge-signature-from edge-signature)
                   (%pipeline-edge-signature-from-port edge-signature))))))

(defun %pipeline-node-result-plan-table (stage-signatures output-key-plans)
  "Node -> (NAME . OUTPUT-KEY-PLAN) built once so %PIPELINE-SINK-RESULT-PLAN's
per-sink lookup is O(1) instead of rescanning STAGE-SIGNATURES linearly."
  (let ((table (make-hash-table :test #'eq)))
    (loop for signature in stage-signatures
          for output-key-plan in output-key-plans
          do (setf (gethash (%pipeline-stage-signature-node signature) table) (cons
                                                                               (%pipeline-stage-signature-name
                                                                                signature)
                                                                               (cdr
                                                                                output-key-plan))))
    table))

(defun %pipeline-sink-result-plan (sink node-result-plan-table)
  (gethash sink node-result-plan-table))

(defun %pipeline-node-levels (stages incoming-index)
  "Group STAGES (already topologically ordered) into levels: level 0 holds
every node with no incoming edge among STAGES, and each later level holds
nodes whose every incoming edge originates in an earlier level (its own level
is 1 + the maximum level among its direct predecessors). Nodes sharing a
level have no dependency path between them, so RUN-PIPELINE's :PARALLEL mode
may run a level's handlers concurrently; each level keeps its members in
STAGES' original (deterministic, string< tie-broken) relative order."
  (when stages
    (let ((level-by-name (make-hash-table :test #'equal))
          (nodes-by-level (make-hash-table :test #'eql))
          (max-level 0))
      (dolist (node stages)
        (let* ((incoming (gethash (node-name node) incoming-index))
               (level
                (if incoming (1+
                              (reduce
                               #'max
                               incoming
                               :key
                               (lambda (edge)
                                 (gethash (edge-from edge) level-by-name 0))))
                  0)))
          (setf (gethash (node-name node) level-by-name) level)
          (setf max-level (max max-level level))
          (push node (gethash level nodes-by-level))))
      (loop for level from 0 to max-level
            collect (nreverse (gethash level nodes-by-level))))))

(defun %pipeline-stage-plan-table (stages input-key-plans output-key-plans)
  "Node -> (INPUT-KEY-PLAN . OUTPUT-KEY-PLAN) built once so a per-level,
per-node lookup is O(1) instead of rescanning the flat, STAGES-parallel
INPUT-KEY-PLANS/OUTPUT-KEY-PLANS lists."
  (let ((table (make-hash-table :test #'eq)))
    (loop for node in stages
          for input-key-plan in input-key-plans
          for output-key-plan in output-key-plans
          do (setf (gethash node table) (cons input-key-plan output-key-plan)))
    table))

(defun %pipeline-stage-signatures (stages)
  (loop for stage in stages
        collect (%make-pipeline-stage-signature stage)))

(defun %pipeline-edge-signatures (graph)
  (loop for edge in (%graph-edges-list graph)
        collect (%make-pipeline-edge-signature edge)))

(defun %pipeline-input-binding-plans (stages incoming-index)
  (loop for node in stages
        for incoming-edges = (gethash (node-name node) incoming-index)
        collect (cons
                 (not (endp incoming-edges))
                 (%node-input-binding-plan node incoming-edges))))

(defun %pipeline-input-key-plans (input-binding-plans
                                  stage-signatures
                                  edge-signature-table)
  (loop for binding-plan in input-binding-plans
        for signature in stage-signatures
        collect (%pipeline-input-key-plan
                 binding-plan
                 signature
                 edge-signature-table)))

(defun %pipeline-output-key-plans (stage-signatures)
  (mapcar #'%pipeline-output-key-plan stage-signatures))

(defmacro %with-pipeline-stage-io-plans ((incoming-index
                                          stage-signatures
                                          edge-signatures
                                          input-binding-plans
                                          input-key-plans
                                          output-key-plans)
                                         (graph stages)
                                         &body
                                         body)
  `(multiple-value-bind (,incoming-index
                         ,stage-signatures
                         ,edge-signatures
                         ,input-binding-plans
                         ,input-key-plans
                         ,output-key-plans) (%pipeline-stage-io-plans
                                             ,graph
                                             ,stages)
     ,@body))

(defun %pipeline-stage-io-plans (graph stages)
  (let* ((incoming-index (%incoming-edges-index graph))
         (stage-signatures (%pipeline-stage-signatures stages))
         (edge-signatures (%pipeline-edge-signatures graph))
         (edge-signature-table (%pipeline-edge-signature-table edge-signatures))
         (input-binding-plans
          (%pipeline-input-binding-plans stages incoming-index))
         (input-key-plans
          (%pipeline-input-key-plans
           input-binding-plans
           stage-signatures
           edge-signature-table))
         (output-key-plans (%pipeline-output-key-plans stage-signatures)))
    (values
     incoming-index
     stage-signatures
     edge-signatures
     input-binding-plans
     input-key-plans
     output-key-plans)))

(defun %pipeline-derived-plans (graph
                                stages
                                incoming-index
                                stage-signatures
                                input-key-plans
                                output-key-plans)
  (let* ((sinks (%sink-nodes-in-order graph stages))
         (node-result-plan-table
          (%pipeline-node-result-plan-table stage-signatures output-key-plans)))
    (values
     sinks
     (loop for sink in sinks
           collect (%pipeline-sink-result-plan sink node-result-plan-table))
     (%pipeline-node-levels stages incoming-index)
     (%pipeline-stage-plan-table stages input-key-plans output-key-plans))))

(defmacro %with-pipeline-derived-plans ((sinks
                                         sink-result-plans
                                         levels
                                         stage-plan-table)
                                        (graph
                                         stages
                                         incoming-index
                                         stage-signatures
                                         input-key-plans
                                         output-key-plans)
                                        &body
                                        body)
  `(multiple-value-bind (,sinks ,sink-result-plans ,levels ,stage-plan-table) (%pipeline-derived-plans
                                                                               ,graph
                                                                               ,stages
                                                                               ,incoming-index
                                                                               ,stage-signatures
                                                                               ,input-key-plans
                                                                               ,output-key-plans)
     ,@body))

(defun %make-pipeline-execution-plan-instance (graph
                                               stages
                                               incoming-index
                                               stage-signatures
                                               edge-signatures
                                               input-binding-plans
                                               input-key-plans
                                               output-key-plans
                                               sinks
                                               sink-result-plans
                                               levels
                                               stage-plan-table)
  (make-instance
   'pipeline-execution-plan
   :graph
   graph
   :stages
   stages
   :stage-signatures
   stage-signatures
   :incoming-index
   incoming-index
   :input-binding-plans
   input-binding-plans
   :input-key-plans
   input-key-plans
   :output-key-plans
   output-key-plans
   :sinks
   sinks
   :sink-result-plans
   sink-result-plans
   :edge-signatures
   edge-signatures
   :levels
   levels
   :stage-plan-table
   stage-plan-table))

(defun %make-pipeline-execution-plan (graph stages)
  (%with-pipeline-stage-io-plans
   (incoming-index
    stage-signatures
    edge-signatures
    input-binding-plans
    input-key-plans
    output-key-plans)
   (graph stages)
   (%with-pipeline-derived-plans
    (sinks sink-result-plans levels stage-plan-table)
    (graph
     stages
     incoming-index
     stage-signatures
     input-key-plans
     output-key-plans)
    (%make-pipeline-execution-plan-instance
     graph
     stages
     incoming-index
     stage-signatures
     edge-signatures
     input-binding-plans
     input-key-plans
     output-key-plans
     sinks
     sink-result-plans
     levels
     stage-plan-table))))
