(in-package #:cl-dataflow)

;;;; The effect boundary's core: constructing an EFFECT and PERFORM-EFFECT,
;;;; which looks up the type's registered handler, runs it, and records the
;;;; result into the context's effect list and trace.

(defun make-effect (type &key payload metadata trace-index result)
  (make-instance
    'effect
    :type
    (%normalize-name type)
    :payload
    (%copy-structured-value payload)
    :metadata
    (%normalize-metadata metadata)
    :trace-index
    trace-index
    :result
    (%copy-structured-value result)))

(defun perform-effect (context type &key payload metadata)
  ;; Locked as one unit, same reasoning as EMIT-EVENT: TRACE-INDEX allocation
  ;; and the placeholder/final trace-entry pushes must be indivisible under
  ;; RUN-PIPELINE's :PARALLEL mode. This also serializes the effect HANDLER
  ;; call itself against any sibling node's concurrent PERFORM-EFFECT in the
  ;; same level -- a deliberately conservative choice: the trace bookkeeping
  ;; mutates the same TRACE-ENTRY both before and after the handler runs, so
  ;; splitting the lock around just the handler call would let a sibling's
  ;; effect interleave its own trace push between this one's placeholder and
  ;; final state. Node HANDLERS (the actual parallelism target) still run
  ;; fully concurrently; only the comparatively rare effect-performing path
  ;; serializes.
  (%with-context-lock-if-present (context)
    (let* ((effect
          (make-effect
            type
            :payload
            payload
            :metadata
            metadata
            :trace-index
            (%context-trace-count context)))
          (handler
          ;; The live table, not CONTEXT-EFFECT-HANDLERS: that reader snapshots
          ;; the whole table, and copying every registered handler to resolve one
          ;; key would put an O(handlers) allocation on every performed effect.
          (gethash (%normalize-handler-key type) (%context-effect-handler-table context))))
      (unless handler
        (error
          'effect-handler-missing-error
          :effect-type
          (effect-type effect)
          :effect
          (%copy-effect effect)
          :detail
          (format
            nil
            "No effect handler registered for ~A"
            (%escaped-display-string (effect-type effect)))))
      (let ((trace-entry
            (list
              :effect
              (effect-type effect)
              :payload
              (effect-payload effect)
              :result
              nil
              :handled-p
              nil
              :trace-index
              (effect-trace-index effect))))
        (%push-context-trace-entry context trace-entry)
        (let ((result (funcall handler effect context)))
          (setf (effect-result effect) result
                (getf trace-entry :result) (%copy-structured-value (effect-result effect)))
          (remf trace-entry :handled-p)
          (setf (slot-value context 'effects)
                (cons (%copy-effect effect) (%context-effects-list context)))
          effect)))))
