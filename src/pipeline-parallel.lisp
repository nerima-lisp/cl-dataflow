(in-package #:cl-dataflow)

(defparameter +parallel-worker-limit+ 4 "Bound CCK-backed parallel work to a small fixed executor.")

;;;; RUN-PIPELINE's :PARALLEL mode: run each topological level's node handlers
;;;; concurrently via cl-concurrent-kit's structured concurrency
;;;; (WITH-TASK-SCOPE/SPAWN/AWAIT), while keeping every write to CONTEXT on a
;;;; single thread. See %PIPELINE-NODE-LEVELS (pipeline-plan-runtime.lisp) for how
;;;; a plan is partitioned into levels, and %WITH-CONTEXT-LOCK-IF-PRESENT
;;;; (core-runtime-helpers.lisp) plus EMIT-EVENT/PERFORM-EFFECT's own locking
;;;; (events.lisp/effects.lisp) for how those two stay safe when two
;;;; same-level handlers call them concurrently.
;;;;
;;;; A level's nodes have no dependency path between them (that is what a
;;;; level IS), so every node-input a level's handlers read was written by an
;;;; earlier, already-completed level -- reading it concurrently, before any
;;;; of this level's own writes exist, needs no lock. WITH-TASK-SCOPE
;;;; guarantees every spawned handler has finished (successfully, by error, or
;;;; cancelled) before it returns, so the sequential fold below never overlaps
;;;; a still-running handler.

(defun %ensure-context-lock (context)
  "Install a lock on CONTEXT if it does not already have one, so
EMIT-EVENT/PERFORM-EFFECT can serialize correctly once concurrent handlers may
call them. Idempotent, and only ever called by RUN-PIPELINE before any task is
spawned, so there is no race in creating it."
  (unless (slot-value context 'lock)
    (setf (slot-value context 'lock)
          (cl-concurrent-kit:make-lock :name "cl-dataflow context")))
  context)

(defun %run-pipeline-level-sequentially (context node plan input)
  "A single-node level: run it exactly like the fully sequential path, with no
scope/thread-spawn overhead. Covers every node of a purely linear (no
fan-out) pipeline, the common case."
  (%run-node context node input (car plan) (cadr plan) (cddr plan)))

(defun %spawn-level-handlers (scope level node-inputs context executor)
  "Start every node in LEVEL handler as a child of SCOPE using EXECUTOR and
return promises in LEVEL order."
  (mapcar
    (lambda (node node-input)
      (cl-concurrent-kit:spawn
        scope
        (lambda () (funcall (node-handler node) node-input context))
        :executor executor))
    level
    node-inputs))

(defun %run-pipeline-level-concurrently (context level plans input executor)
  (let ((node-inputs
          (mapcar
            (lambda (node plan) (%resolve-node-input context node input (car plan)))
            level
            plans)))
    (cl-concurrent-kit:with-task-scope (scope)
      (let* ((promises (%spawn-level-handlers scope level node-inputs context executor))
             (outputs (mapcar #'cl-concurrent-kit:await promises)))
        (loop for node in level
              for node-input in node-inputs
              for output in outputs
              for plan in plans
              do (%finalize-node-run context node node-input output (cadr plan) (cddr plan)))))))

(defun %run-pipeline-level (context level stage-plan-table input executor)
  (let ((plans (mapcar (lambda (node) (gethash node stage-plan-table)) level)))
    (if (null (cdr level))
        (%run-pipeline-level-sequentially context (first level) (first plans) input)
        (%run-pipeline-level-concurrently context level plans input executor))))

(defun %run-pipeline-levels-parallel (context plan sink-result-plans input)
  "Run a pipeline with one bounded fixed executor shared across concurrent levels."
  (%ensure-context-lock context)
  (let* ((levels (%pipeline-execution-plan-levels plan))
         (stage-plan-table (%pipeline-execution-plan-stage-plan-table plan))
         (executor-size
           (min
            +parallel-worker-limit+
            (loop for level in levels
                  maximize (length level) into size
                  finally (return (max 1 (or size 0)))))))
    (if (> executor-size 1)
        (cl-concurrent-kit:with-executor (executor :size executor-size)
          (dolist (level levels)
            (%run-pipeline-level context level stage-plan-table input executor)))
        (dolist (level levels)
          (%run-pipeline-level context level stage-plan-table input nil))))
  (%finalize-pipeline-run context sink-result-plans))

(defun %map-pipeline-parallel (pipeline inputs)
  "Run MAP-PIPELINE inputs on a bounded executor while preserving input order."
  (let ((input-count (length inputs)))
    (if (zerop input-count)
        nil
        (let ((executor-size
                (min input-count +parallel-worker-limit+)))
          (cl-concurrent-kit:with-executor (executor :size executor-size)
            (cl-concurrent-kit:executor-map
              executor
              (lambda (input) (run-pipeline pipeline :input input))
              inputs
              :max-in-flight executor-size))))))
