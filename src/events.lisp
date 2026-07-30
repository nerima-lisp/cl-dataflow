(in-package #:cl-dataflow)

;;;; Event construction and EMIT-EVENT, plus %PUSH-CONTEXT-TRACE-ENTRY: the
;;;; single append point for a context's trace list that EMIT-EVENT,
;;;; PERFORM-EFFECT, and state-machine transition recording all share, so
;;;; TRACE-COUNT can never drift from (LENGTH TRACE).

(defun %push-context-trace-entry (context entry)
  "The single append point for the context's trace list: EMIT-EVENT,
PERFORM-EFFECT, and state-machine transition recording all go through this so
TRACE-COUNT can never drift from (length trace). Unguarded, like
%STORE-VALUE-BY-KEY: callers that need atomicity against concurrent node
handlers (EMIT-EVENT, PERFORM-EFFECT) take CONTEXT's lock themselves, around
their own whole read-then-push sequence, before calling this."
  (setf (%context-trace-list context) (cons entry (%context-trace-list context)))
  (incf (slot-value context 'trace-count))
  entry)

(defun make-event (type &key payload metadata trace-index)
  (make-instance 'event
                 :type (%normalize-name type)
                 :payload (%copy-structured-value payload)
                 :metadata (%normalize-metadata metadata)
                 :trace-index trace-index))

(defun emit-event (context type &key payload metadata)
  ;; Locked as one unit (not via %PUSH-CONTEXT-TRACE-ENTRY's own guard, which
  ;; would be a second, non-reentrant acquisition -- cl-concurrent-kit's lock
  ;; is a plain SB-THREAD:MUTEX, not actually recursive despite MAKE-LOCK's
  ;; docstring, confirmed empirically): reading TRACE-COUNT for TRACE-INDEX and
  ;; pushing to EVENTS/TRACE must be indivisible, or two node handlers emitting
  ;; concurrently under RUN-PIPELINE's :PARALLEL mode could read the same
  ;; stale count and assign the same TRACE-INDEX to two different events.
  (%with-context-lock-if-present (context)
    (let ((event (make-event type
                             :payload payload
                             :metadata metadata
                             :trace-index (%context-trace-count context))))
      (setf (slot-value context 'events)
            (cons (%copy-event event) (%context-events-list context)))
      (%push-context-trace-entry context
                                  (list :event (event-type event)
                                        :payload (event-payload event)
                                        :trace-index (event-trace-index event)))
      event)))
