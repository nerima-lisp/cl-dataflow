(in-package #:cl-dataflow)

;;;; Pipeline execution-plan construction is split from pipeline execution so
;;;; the cached plan's data derivation can evolve independently of the runtime
;;;; loop that consumes it.
;;;; Pipeline construction (MAKE-PIPELINE, COPY-PIPELINE, the PIPELINE-STAGES
;;;; setter) and RUN-PIPELINE's execution consume the execution-plan builders
;;;; defined in PIPELINE-PLAN-RUNTIME.LISP.
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
   (equal
    (%node-inputs-list stage)
    (%pipeline-stage-signature-inputs signature))
   (equal
    (%node-outputs-list stage)
    (%pipeline-stage-signature-outputs signature))
   (eq stage (find-node graph (node-name stage)))))

(defmacro %pipeline-matching-pairs-current-p (((left-item right-item)
                                               left-list
                                               right-list)
                                              &body
                                              body)
  `(do ((remaining-left ,left-list (cdr remaining-left))
        (remaining-right ,right-list (cdr remaining-right)))
       ((or (endp remaining-left) (endp remaining-right))
        (and (endp remaining-left) (endp remaining-right)))
     (let ((,left-item (car remaining-left))
           (,right-item (car remaining-right)))
       (unless (progn ,@body)
         (return nil)))))

(defun %pipeline-stage-signatures-current-p (graph stages signatures)
  (%pipeline-matching-pairs-current-p
   ((stage signature) stages signatures)
   (%pipeline-stage-signature-current-p graph stage signature)))

(defun %pipeline-edge-signatures-current-p (edges signatures)
  (%pipeline-matching-pairs-current-p
   ((edge signature) edges signatures)
   (%pipeline-edge-signature-current-p edge signature)))

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
         (stages
          (%remap-pipeline-stages graph (%pipeline-stages-list pipeline)))
         (plan (%make-pipeline-execution-plan graph stages)))
    (setf (slot-value pipeline 'stages) stages
          (%pipeline-execution-plan pipeline) plan)
    plan))

(defun %ensure-pipeline-execution-plan (pipeline)
  (let ((plan (%pipeline-execution-plan pipeline)))
    (if (%pipeline-execution-plan-current-p pipeline plan) plan
      (%rebuild-pipeline-execution-plan pipeline))))

(defun make-pipeline (&key graph stages metadata)
  (multiple-value-bind (resolved-graph resolved-stages) (%build-pipeline-graph
                                                         graph
                                                         stages)
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
        for key-binding = (assoc
                           (car binding)
                           output-key-plan
                           :test
                           #'string-equal)
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
      (t
       (%collapse-single-binding-list
        (%resolve-input-key-plan context bindings))))))

(defun %finalize-node-run (context
                           node
                           node-input
                           output
                           output-names
                           output-key-plan)
  "The recording half of running a node: fold its already-computed OUTPUT into
CONTEXT. Split out from %RUN-NODE so PIPELINE-PARALLEL.LISP can run it, for
every node in a level, sequentially on the orchestrating thread after that
level's handlers have all been awaited -- keeping every write to CONTEXT
single-threaded regardless of :PARALLEL."
  (if (%single-output-scalar-result-p output-names output) (let ((output-name
                                                                  (caar
                                                                   output-key-plan)))
                                                             (%store-value-by-key
                                                              context
                                                              (cdar
                                                               output-key-plan)
                                                              output)
                                                             (%push-context-trace-entry
                                                              context
                                                              (%make-node-trace-record
                                                               node
                                                               node-input
                                                               (list
                                                                (cons
                                                                 output-name
                                                                 output)))))
    (%record-node-run
     context
     node
     node-input
     (%node-output-bindings node output output-names)
     output-key-plan))
  output)

(defun %run-node (context
                  node
                  input
                  input-key-plan
                  output-names
                  output-key-plan)
  (let* ((node-input (%resolve-node-input context node input input-key-plan))
         (output (funcall (node-handler node) node-input context)))
    (%finalize-node-run
     context
     node
     node-input
     output
     output-names
     output-key-plan)))

(defun %finalize-pipeline-run (context sink-result-plans)
  (setf (context-result context) (%collect-cached-sink-results
                                  context
                                  sink-result-plans))
  (context-result context))

(defun %run-pipeline-stages (context
                             order
                             sink-result-plans
                             input
                             input-key-plans
                             output-key-plans)
  (loop for node in order
        for input-key-plan in input-key-plans
        for output-key-plan in output-key-plans
        do (%run-node
            context
            node
            input
            input-key-plan
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
    (if parallel (%run-pipeline-levels-parallel
                  ctx
                  plan
                  sink-result-plans
                  input)
      (%run-pipeline-stages
       ctx
       (%pipeline-execution-plan-stages plan)
       sink-result-plans
       input
       (%pipeline-execution-plan-input-key-plans plan)
       (%pipeline-execution-plan-output-key-plans plan)))))

(defun run-pipeline-with-context (pipeline &key input context parallel)
  (let ((ctx (%ensure-pipeline-context context)))
    (values
     (run-pipeline pipeline :input input :context ctx :parallel parallel)
     ctx)))
