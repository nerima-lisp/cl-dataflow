(in-package #:cl-dataflow)

;;;; Pipeline construction (MAKE-PIPELINE, COPY-PIPELINE, the PIPELINE-STAGES
;;;; setter) and RUN-PIPELINE's execution. RUN-PIPELINE builds a
;;;; PIPELINE-EXECUTION-PLAN once -- graph-ordered stage signatures, the
;;;; incoming-edge index, and per-node input/output value-key plans -- caches
;;;; it on the pipeline, and reuses it while the topology is unchanged. Each
;;;; run then iterates the cached stages, driving every node handler and
;;;; folding results into the context by precomputed key, so a re-run does no
;;;; graph analysis and allocates no per-stage continuation.

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

(defun %pipeline-edge-signature-table (edge-signatures)
  "Edge -> its EDGE-SIGNATURE built once so %PIPELINE-INPUT-KEY-PLAN's per-binding
lookup is O(1) instead of rescanning EDGE-SIGNATURES linearly."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (signature edge-signatures)
      (setf (gethash (%pipeline-edge-signature-edge signature) table) signature))
    table))

(defun %pipeline-input-key-plan (binding-plan target-signature edge-signature-table)
  (cons
    (car binding-plan)
    (loop for (target-port . edge) in (cdr binding-plan)
          for edge-signature = (gethash edge edge-signature-table)
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

(defun %pipeline-node-result-plan-table (stage-signatures output-key-plans)
  "Node -> (NAME . OUTPUT-KEY-PLAN) built once so %PIPELINE-SINK-RESULT-PLAN's
per-sink lookup is O(1) instead of rescanning STAGE-SIGNATURES linearly."
  (let ((table (make-hash-table :test #'eq)))
    (loop for signature in stage-signatures
          for output-key-plan in output-key-plans
          do (setf (gethash (%pipeline-stage-signature-node signature) table)
                   (cons (%pipeline-stage-signature-name signature) (cdr output-key-plan))))
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
              (if incoming
                  (1+ (reduce #'max incoming
                        :key (lambda (edge) (gethash (edge-from edge) level-by-name 0))))
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

(defun %make-pipeline-execution-plan (graph stages)
  (let* ((incoming-index (%incoming-edges-index graph))
          (stage-signatures
        (loop for stage in stages
              collect (%make-pipeline-stage-signature stage)))
          (edge-signatures
        (loop for edge in (%graph-edges-list graph)
              collect (%make-pipeline-edge-signature edge)))
          (edge-signature-table (%pipeline-edge-signature-table edge-signatures))
          (input-binding-plans
        (loop for node in stages
              for incoming-edges = (gethash (node-name node) incoming-index)
              collect (cons
            (not (endp incoming-edges))
            (%node-input-binding-plan node incoming-edges))))
          (input-key-plans
        (loop for binding-plan in input-binding-plans
              for signature in stage-signatures
              collect (%pipeline-input-key-plan binding-plan signature edge-signature-table)))
          (output-key-plans
        (mapcar #'%pipeline-output-key-plan stage-signatures))
          (sinks (%sink-nodes-in-order graph stages))
          (node-result-plan-table
        (%pipeline-node-result-plan-table stage-signatures output-key-plans)))
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
            collect (%pipeline-sink-result-plan sink node-result-plan-table))
      :edge-signatures
      edge-signatures
      :levels
      (%pipeline-node-levels stages incoming-index)
      :stage-plan-table
      (%pipeline-stage-plan-table stages input-key-plans output-key-plans))))

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
      (%rebuild-pipeline-execution-plan pipeline))))

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
    ;; MAKE-PIPELINE runs %REMAP-PIPELINE-STAGES over this, which already builds
    ;; a fresh list, so PIPELINE-STAGES' defensive COPY-LIST would be discarded.
    (%pipeline-stages-list pipeline)
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

(defun %resolve-node-input (context node input input-key-plan)
  "The read-only half of running a node: compute its NODE-INPUT from already-
stored upstream values. Split out from %RUN-NODE so PIPELINE-PARALLEL.LISP can
run it before spawning a level's handlers -- safe unguarded even under
:PARALLEL, since a level's inputs only ever reference earlier, already-
completed levels."
  (let ((has-incoming-p (car input-key-plan))
        (bindings (cdr input-key-plan)))
    (cond
      ((null bindings)
        (if has-incoming-p nil
          (%node-input-binding node input)))
      ((null (cdr bindings)) (%read-value-by-key context (cdar bindings)))
      (t (%collapse-single-binding-list (%resolve-input-key-plan context bindings))))))

(defun %finalize-node-run (context node node-input output output-names output-key-plan)
  "The recording half of running a node: fold its already-computed OUTPUT into
CONTEXT. Split out from %RUN-NODE so PIPELINE-PARALLEL.LISP can run it, for
every node in a level, sequentially on the orchestrating thread after that
level's handlers have all been awaited -- keeping every write to CONTEXT
single-threaded regardless of :PARALLEL."
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
  output)

(defun %run-node (context node input input-key-plan output-names output-key-plan)
  (let* ((node-input (%resolve-node-input context node input input-key-plan))
          (output (funcall (node-handler node) node-input context)))
    (%finalize-node-run context node node-input output output-names output-key-plan)))

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

(defun %ensure-pipeline-context (context)
  (or context (make-context)))

(defun run-pipeline (pipeline &key input context parallel)
  "Run PIPELINE's stages against INPUT, folding results into CONTEXT (a fresh
one if not supplied). With PARALLEL true, stages that share a topological
level (no dependency path between them; see %PIPELINE-NODE-LEVELS) run their
handlers concurrently via cl-concurrent-kit -- see PIPELINE-PARALLEL.LISP for
the concurrency-safety argument. Every value/trace write still happens on one
thread, so a :PARALLEL run produces byte-identical results to a sequential one
whenever no two same-level handlers both call EMIT-EVENT/PERFORM-EFFECT (those
two serialize against each other but not against other handlers' pure work);
if they do, memory safety is still guaranteed, but the relative order of
their events/effects is not."
  (let* ((plan (%ensure-pipeline-execution-plan pipeline))
          (ctx (%ensure-pipeline-context context))
          (sink-result-plans (%pipeline-execution-plan-sink-result-plans plan)))
    (if parallel
        (%run-pipeline-levels-parallel ctx plan sink-result-plans input)
        (%run-pipeline-stages
          ctx
          (%pipeline-execution-plan-stages plan)
          sink-result-plans
          input
          (%pipeline-execution-plan-input-key-plans plan)
          (%pipeline-execution-plan-output-key-plans plan)))))

(defun run-pipeline-with-context (pipeline &key input context parallel)
  (let ((ctx (%ensure-pipeline-context context)))
    (values (run-pipeline pipeline :input input :context ctx :parallel parallel) ctx)))
