(in-package #:cl-dataflow)

;;;; Pipeline construction (MAKE-PIPELINE, COPY-PIPELINE, the PIPELINE-STAGES
;;;; setter) and RUN-PIPELINE's execution. RUN-PIPELINE builds a
;;;; PIPELINE-EXECUTION-PLAN once -- graph-ordered stage signatures, the
;;;; incoming-edge index, and per-node input/output value-key plans -- caches
;;;; it on the pipeline, and reuses it while the topology is unchanged. Each
;;;; run then iterates the cached stages, driving every node handler and
;;;; folding results into the context by precomputed key, so a re-run does no
;;;; graph analysis and allocates no per-stage continuation.

(progn
  (defun %build-pipeline-graph (graph stages)
    (cond
      (graph
        (let ((copied-graph (copy-graph graph)))
          (values
            copied-graph
            (%remap-pipeline-stages copied-graph (or stages (topological-sort graph))))))
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
  (defun %pipeline-input-key-plan (binding-plan target-signature edge-signatures)
    (cons
      (car binding-plan)
      (loop for (target-port . edge) in (cdr binding-plan)
            for edge-signature = (find
          edge
          edge-signatures
          :key
          #'%pipeline-edge-signature-edge
          :test
          #'eq)
            for private-target-port = (find
          target-port
          (%pipeline-stage-signature-inputs target-signature)
          :test
          #'equal)
            collect (cons
          private-target-port
          (%pipeline-value-key
            (%pipeline-edge-signature-from edge-signature)
            (%pipeline-edge-signature-from-port edge-signature))))))
  (defun %pipeline-sink-result-plan (sink stage-signatures output-key-plans)
    (loop for signature in stage-signatures
          for output-key-plan in output-key-plans
          when (eq sink (%pipeline-stage-signature-node signature))
            return (cons (%pipeline-stage-signature-name signature) (cdr output-key-plan))))
  (defun %make-pipeline-execution-plan (graph stages)
    (let* ((incoming-index (%incoming-edges-index graph))
            (stage-signatures
          (loop for stage in stages
                collect (%make-pipeline-stage-signature stage)))
            (edge-signatures
          (loop for edge in (%graph-edges-list graph)
                collect (%make-pipeline-edge-signature edge)))
            (input-binding-plans
          (loop for node in stages
                for incoming-edges = (gethash (node-name node) incoming-index)
                collect (cons
              (not (endp incoming-edges))
              (%node-input-binding-plan node incoming-edges))))
            (input-key-plans
          (loop for binding-plan in input-binding-plans
                for signature in stage-signatures
                collect (%pipeline-input-key-plan binding-plan signature edge-signatures)))
            (output-key-plans
          (mapcar #'%pipeline-output-key-plan stage-signatures))
            (sinks (%sink-nodes-in-order graph stages)))
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
        (loop for sink in sinks
              collect (%pipeline-sink-result-plan sink stage-signatures output-key-plans))
        :edge-signatures
        edge-signatures)))
  (defun %pipeline-edge-signature-current-p (edge signature)
    (and
      (eq edge (%pipeline-edge-signature-edge signature))
      (equal (edge-from edge) (%pipeline-edge-signature-from signature))
      (equal (edge-from-port edge) (%pipeline-edge-signature-from-port signature))
      (equal (edge-to edge) (%pipeline-edge-signature-to signature))
      (equal (edge-to-port edge) (%pipeline-edge-signature-to-port signature))))
  (defun %pipeline-stage-signature-current-p (graph stage signature)
    (and
      (eq stage (%pipeline-stage-signature-node signature))
      (equal (node-name stage) (%pipeline-stage-signature-name signature))
      (equal (%node-inputs-list stage) (%pipeline-stage-signature-inputs signature))
      (equal (%node-outputs-list stage) (%pipeline-stage-signature-outputs signature))
      (eq stage (find-node graph (node-name stage)))))
  (defun %pipeline-stage-signatures-current-p (graph stages signatures)
    (do ((remaining-stages stages (cdr remaining-stages))
          (remaining-signatures signatures (cdr remaining-signatures)))
      ((or (endp remaining-stages) (endp remaining-signatures))
        (and (endp remaining-stages) (endp remaining-signatures)))
      (unless (%pipeline-stage-signature-current-p
          graph
          (car remaining-stages)
          (car remaining-signatures))
        (return nil))))
  (defun %pipeline-edge-signatures-current-p (edges signatures)
    (do ((remaining-edges edges (cdr remaining-edges))
          (remaining-signatures signatures (cdr remaining-signatures)))
      ((or (endp remaining-edges) (endp remaining-signatures))
        (and (endp remaining-edges) (endp remaining-signatures)))
      (unless (%pipeline-edge-signature-current-p
          (car remaining-edges)
          (car remaining-signatures))
        (return nil))))
  (defun %pipeline-execution-plan-current-p (pipeline plan)
    (and
      plan
      (let ((graph (pipeline-graph pipeline)))
        (and
          (eq graph (%pipeline-execution-plan-graph plan))
          (%pipeline-stage-signatures-current-p
            graph
            (%pipeline-execution-plan-stages plan)
            (%pipeline-execution-plan-stage-signatures plan))
          (%pipeline-edge-signatures-current-p
            (%graph-edges-list graph)
            (%pipeline-execution-plan-edge-signatures plan))))))
  (defun %rebuild-pipeline-execution-plan (pipeline)
    (let* ((graph (pipeline-graph pipeline))
            (stages (%remap-pipeline-stages graph (%pipeline-stages-list pipeline)))
            (plan (%make-pipeline-execution-plan graph stages)))
      (setf (slot-value pipeline 'stages) stages
            (%pipeline-execution-plan pipeline) plan)
      plan))
  (defun %ensure-pipeline-execution-plan (pipeline)
    (let ((plan (%pipeline-execution-plan pipeline)))
      (if (%pipeline-execution-plan-current-p pipeline plan) plan
        (%rebuild-pipeline-execution-plan pipeline)))))

(defun make-pipeline (&key graph stages metadata)
  (multiple-value-bind (resolved-graph resolved-stages) (%build-pipeline-graph graph stages)
    (validate-graph resolved-graph)
    (let ((internal-stages (copy-list resolved-stages)))
      (make-instance
        'pipeline
        :graph
        resolved-graph
        :stages
        internal-stages
        :execution-plan
        (%make-pipeline-execution-plan resolved-graph internal-stages)
        :metadata
        (%normalize-metadata metadata)))))

(defun copy-pipeline (pipeline)
  (make-pipeline
    :graph
    (pipeline-graph pipeline)
    :stages
    (pipeline-stages pipeline)
    :metadata
    (pipeline-metadata pipeline)))

(defmethod (setf pipeline-stages) (stages (pipeline pipeline))
  (let ((graph (pipeline-graph pipeline)))
    (validate-graph graph)
    (let ((remapped-stages
          (if stages (%remap-pipeline-stages graph stages)
            '())))
      (setf (slot-value pipeline 'stages) remapped-stages
            (%pipeline-execution-plan pipeline) nil)
      remapped-stages)))

(defmethod pipeline-stages ((pipeline pipeline))
  (copy-list (%pipeline-stages-list pipeline)))

(defun %copy-node-output-bindings (bindings)
  (mapcar
    (lambda (binding)
      (cons (car binding) (%copy-structured-value (cdr binding))))
    bindings))

(defun %make-node-trace-record (node node-input bindings)
  (list
    :node
    (node-name node)
    :input
    node-input
    :output
    (%copy-node-output-bindings bindings)))

(defun %record-node-run (context node node-input bindings output-key-plan)
  (loop for binding in bindings
        for key-binding = (assoc (car binding) output-key-plan :test #'string-equal)
        do (%store-value-by-key context (cdr key-binding) (cdr binding)))
  (%push-context-trace-entry
    context
    (%make-node-trace-record node node-input bindings)))

(defun %run-node (context node input input-key-plan output-names output-key-plan)
  (let* ((has-incoming-p (car input-key-plan))
          (bindings (cdr input-key-plan))
          (node-input
        (cond
          ((null bindings)
            (if has-incoming-p nil
              (%node-input-binding node input)))
          ((null (cdr bindings)) (%read-value-by-key context (cdar bindings)))
          (t (%collapse-single-binding-list (%resolve-input-key-plan context bindings)))))
          (output (funcall (node-handler node) node-input context)))
    (if (%single-output-scalar-result-p output-names output)
        (let ((output-name (caar output-key-plan)))
          (%store-value-by-key context (cdar output-key-plan) output)
          (%push-context-trace-entry
            context
            (%make-node-trace-record node node-input (list (cons output-name output)))))
        (%record-node-run
          context node node-input
          (%node-output-bindings node output output-names)
          output-key-plan))
    output))

(defun %finalize-pipeline-run (context sink-result-plans)
  (setf (context-result context) (%collect-cached-sink-results context sink-result-plans))
  (context-result context))

(defun %run-pipeline-stages (context order sink-result-plans input input-key-plans output-key-plans)
  (loop for node in order
        for input-key-plan in input-key-plans
        for output-key-plan in output-key-plans
        do (%run-node context node input input-key-plan
                      (car output-key-plan)
                      (cdr output-key-plan)))
  (%finalize-pipeline-run context sink-result-plans))

(progn
  (defun %ensure-pipeline-context (context)
    (or context (make-context)))
  (defun run-pipeline (pipeline &key input context)
    (let* ((plan (%ensure-pipeline-execution-plan pipeline))
            (ctx (%ensure-pipeline-context context))
            (order (%pipeline-execution-plan-stages plan))
            (sink-result-plans (%pipeline-execution-plan-sink-result-plans plan))
            (input-key-plans (%pipeline-execution-plan-input-key-plans plan))
            (output-key-plans (%pipeline-execution-plan-output-key-plans plan)))
      (%run-pipeline-stages
        ctx
        order
        sink-result-plans
        input
        input-key-plans
        output-key-plans)))
  (defun run-pipeline-with-context (pipeline &key input context)
    (let ((ctx (%ensure-pipeline-context context)))
      (values (run-pipeline pipeline :input input :context ctx) ctx))))
