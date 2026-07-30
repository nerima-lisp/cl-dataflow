(in-package #:cl-dataflow)

;;;; Iterative (feedback) pipeline execution: repeatedly feed a pipeline's result
;;;; back in as its next input. This adds the recurrent/settling computation model
;;;; on top of the base single-pass DAG execution -- run a fixed number of times,
;;;; run to a fixpoint, or run while a predicate holds. All iterations share one
;;;; context, so events, effects, and trace accumulate across the whole run.
;;;; Defaults are resolved in the body (not the lambda list) so both the supplied
;;;; and default paths are exercisable.

(defparameter +default-max-pipeline-iterations+ 1000
  "Iteration cap RUN-PIPELINE-UNTIL-FIXPOINT and RUN-PIPELINE-WHILE fall back to
when MAX-ITERATIONS is not supplied, so a mistakenly non-converging or
always-true predicate still terminates.")

(defun run-pipeline-times (pipeline n &key input context parallel)
  "Run PIPELINE N times, feeding each run's result in as the next run's input, and
return (VALUES FINAL-RESULT CONTEXT). N = 0 returns (VALUES INPUT CONTEXT). PARALLEL
is passed through to each RUN-PIPELINE call; see its docstring."
  (let ((ctx (%ensure-pipeline-context context))
        (value input))
    (dotimes (iteration n (values value ctx))
      (setf value (run-pipeline pipeline :input value :context ctx :parallel parallel)))))

(defun run-pipeline-until-fixpoint (pipeline &key input context test max-iterations parallel)
  "Run PIPELINE repeatedly, feeding each result back in as input, until a run
produces a result equal (under TEST, default #'EQUAL) to the value fed into it -- a
fixpoint -- or MAX-ITERATIONS (default 1000) runs have completed. Returns (VALUES
RESULT ITERATIONS FIXPOINT-P), where FIXPOINT-P is true only when a fixpoint was
reached before the iteration cap. PARALLEL is passed through to each RUN-PIPELINE
call; see its docstring."
  (let ((ctx (%ensure-pipeline-context context))
        (comparison (or test #'equal))
        (limit (or max-iterations +default-max-pipeline-iterations+))
        (value input))
    (dotimes (iteration limit (values value limit nil))
      (let ((next (run-pipeline pipeline :input value :context ctx :parallel parallel)))
        (when (funcall comparison next value)
          (return (values next (1+ iteration) t)))
        (setf value next)))))

(defun run-pipeline-while (pipeline predicate &key input context max-iterations parallel)
  "Run PIPELINE repeatedly (feeding result back as input) while PREDICATE holds on
the current value, up to MAX-ITERATIONS (default 1000). PREDICATE is checked before
each run, so it can stop immediately. Returns (VALUES FINAL-VALUE ITERATIONS).
PARALLEL is passed through to each RUN-PIPELINE call; see its docstring."
  (let ((ctx (%ensure-pipeline-context context))
        (limit (or max-iterations +default-max-pipeline-iterations+))
        (value input)
        (iterations 0))
    (loop
      (when (or (>= iterations limit) (not (funcall predicate value)))
        (return (values value iterations)))
      (setf value (run-pipeline pipeline :input value :context ctx :parallel parallel))
      (incf iterations))))
