(in-package #:cl-dataflow)

;;;; Combinators over node handlers and pipelines. A node handler is an ordinary
;;;; (INPUT CONTEXT) -> OUTPUT closure, so behaviours like retry, fallback, and
;;;; memoisation are expressed as handler -> handler transformations, and richer
;;;; nodes are built by re-wrapping an existing node's handler (WRAP-NODE).

;;; --- Handler adapters (function -> handler) ------------------------------

(defun mapping-handler (function)
  "Adapt a unary FUNCTION into a node handler that ignores the context and returns
(FUNCALL FUNCTION INPUT)."
  (lambda (input context)
    (declare (ignore context))
    (funcall function input)))

(defun compose-handlers (&rest handlers)
  "Return a handler that threads INPUT through each of HANDLERS left to right,
passing the shared CONTEXT to every step. With no handlers this is the identity."
  (lambda (input context)
    (let ((value input))
      (dolist (handler handlers value)
        (setf value (funcall handler value context))))))

;;; --- Handler wrappers (handler -> handler) -------------------------------

(defun %reject-unless-condition-type (condition condition-type)
  "Re-signal CONDITION unless it matches CONDITION-TYPE -- the condition-type
filter RETRYING-HANDLER and FALLBACK-HANDLER both apply before their own,
genuinely different, recovery action (retry vs. fall back)."
  (unless (typep condition condition-type)
    (error condition)))

(defun retrying-handler (handler &key (attempts 3) (condition-type 'error))
  "Wrap HANDLER so that a signalled condition of CONDITION-TYPE is retried, up to
ATTEMPTS total invocations. A condition outside CONDITION-TYPE is re-signalled
immediately, and the last failure is re-signalled once ATTEMPTS is exhausted."
  (when (< attempts 1)
    (error 'invalid-input-error
           :expected 'positive-integer
           :value attempts
           :detail "RETRYING-HANDLER requires at least one attempt."))
  (lambda (input context)
    (let ((attempt 0))
      (loop
        (handler-case
            (return (funcall handler input context))
          (error (condition)
            (incf attempt)
            (%reject-unless-condition-type condition condition-type)
            (when (>= attempt attempts)
              (error condition))))))))

(defun fallback-handler (handler fallback &key (condition-type 'error))
  "Wrap HANDLER so that a signalled condition of CONDITION-TYPE yields a fallback
result instead of propagating. When FALLBACK is a function it is called with
(INPUT CONTEXT CONDITION); otherwise FALLBACK is returned verbatim. Conditions
outside CONDITION-TYPE propagate unchanged."
  (lambda (input context)
    (handler-case
        (funcall handler input context)
      (error (condition)
        (%reject-unless-condition-type condition condition-type)
        (if (functionp fallback)
            (funcall fallback input context condition)
            fallback)))))

(defun memoizing-handler (handler &key (test 'equal) (key #'identity))
  "Wrap HANDLER with a cache keyed by (FUNCALL KEY INPUT) under equality TEST. A
repeated key returns the cached result without re-invoking HANDLER. The cache
lives in the returned closure, so distinct wrappers do not share state."
  (let ((cache (make-hash-table :test test)))
    (lambda (input context)
      (let ((cache-key (funcall key input)))
        (multiple-value-bind (value present) (gethash cache-key cache)
          (if present
              value
              (setf (gethash cache-key cache)
                    (funcall handler input context))))))))

(defun tapping-handler (handler side-effect)
  "Wrap HANDLER so that SIDE-EFFECT is invoked with (INPUT OUTPUT CONTEXT) after
HANDLER runs. The handler's output is returned unchanged; SIDE-EFFECT's value is
discarded. Useful for logging or metrics without altering the data flow."
  (lambda (input context)
    (let ((output (funcall handler input context)))
      (funcall side-effect input output context)
      output)))

;;; --- Node wrappers (node -> node) ----------------------------------------

(defun wrap-node (node wrapper)
  "Return a fresh node identical to NODE but whose handler is
(FUNCALL WRAPPER (NODE-HANDLER NODE)). WRAPPER is a handler -> handler function.
The result is not attached to any graph."
  (make-node (node-name node)
             :inputs (node-inputs node)
             :outputs (node-outputs node)
             :metadata (node-metadata node)
             :handler (funcall wrapper (node-handler node))))

(defmacro define-node-wrapper (&body specs)
  "For each (NAME LAMBDA-LIST HANDLER-CALL DOCSTRING) in SPECS, define NAME as
(NAME NODE . LAMBDA-LIST) returning a copy of NODE whose handler is rebuilt by
HANDLER-CALL -- a form that calls the underlying handler-wrapper function
(RETRYING-HANDLER, FALLBACK-HANDLER, ...) with the anaphoric `handler` (bound
by WRAP-NODE) and LAMBDA-LIST's parameters in scope. Every member of this
family only differs in which wrapper function it forwards to and with what
arguments."
  `(progn
     ,@(mapcar (lambda (spec)
                 (destructuring-bind (name lambda-list handler-call docstring) spec
                   `(defun ,name (node ,@lambda-list)
                      ,docstring
                      (wrap-node node (lambda (handler) ,handler-call)))))
               specs)))

(define-node-wrapper
  (node-with-retry (&key (attempts 3) (condition-type 'error))
   (retrying-handler handler :attempts attempts :condition-type condition-type)
   "Return a copy of NODE whose handler retries on CONDITION-TYPE (see
RETRYING-HANDLER).")
  (node-with-fallback (fallback &key (condition-type 'error))
   (fallback-handler handler fallback :condition-type condition-type)
   "Return a copy of NODE whose handler falls back on CONDITION-TYPE (see
FALLBACK-HANDLER).")
  (node-with-memoization (&key (test 'equal) (key #'identity))
   (memoizing-handler handler :test test :key key)
   "Return a copy of NODE whose handler memoises results (see MEMOIZING-HANDLER).")
  (node-with-tap (side-effect)
   (tapping-handler handler side-effect)
   "Return a copy of NODE whose handler taps its output through SIDE-EFFECT (see
TAPPING-HANDLER)."))

;;; --- Pipeline composition ------------------------------------------------

(defun run-pipeline-sequence (pipelines &key input context)
  "Run PIPELINES in order, threading each pipeline's result into the next as its
input, and return (VALUES FINAL-RESULT CONTEXT). A single shared context (created
when CONTEXT is NIL) accumulates the events, effects, and trace of every stage, so
the whole composite run is observable as one unit. An empty PIPELINES list returns
(VALUES INPUT CONTEXT)."
  (let ((ctx (%ensure-pipeline-context context))
        (value input))
    (dolist (pipeline pipelines)
      (setf value (run-pipeline pipeline :input value :context ctx)))
    (values value ctx)))
