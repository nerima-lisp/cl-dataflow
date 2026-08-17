(in-package #:cl-dataflow-kit)

;;;; STEP-STATE-MACHINE's continuation-passing execution chain: resolve the
;;;; matching transition, run its action, then commit the resulting state and
;;;; history/trace records -- each phase named and explicitly handing off to
;;;; the next via a CONTINUATION argument rather than a plain return.

(defmacro %signal-state-machine-error (condition machine event-type detail &rest initargs)
  `(error ',condition
          :state (state-machine-state ,machine)
          :event-type ,event-type
          :detail ,detail
          ,@initargs))

(defun %resolve-transition/cps (machine event context event-type continuation)
  (multiple-value-bind (transition first-match)
      (%find-transition-selection machine event context event-type)
    (unless first-match
      (%signal-state-machine-error invalid-transition-error
                                   machine
                                   event-type
                                   (%transition-error-detail machine event-type)))
    (unless transition
      (%signal-state-machine-error guard-failed-error
                                   machine
                                   event-type
                                   (%guard-error-detail machine event-type)
                                   :transition (%copy-state-transition first-match)))
    (funcall continuation transition)))

(defun %run-transition-action/cps (machine transition event context continuation)
  (let ((action (transition-action transition))
        (previous-state (state-machine-state machine))
        (next-state (transition-to transition))
        (action-result nil))
    (when action
      (multiple-value-bind (computed result)
          (funcall action machine event context)
        (when computed
          (setf next-state (%normalize-name computed)))
        (setf action-result result)))
    (funcall continuation previous-state next-state action-result)))

(defstruct (%transition-handoff
            (:constructor %make-transition-handoff
                (transition event-type previous-state next-state action-result))
            (:copier nil))
  transition
  event-type
  previous-state
  next-state
  action-result)

(defun %run-transition/cps (machine transition event context event-type continuation)
  (%run-transition-action/cps
   machine
   transition
   event
   context
   (lambda (previous-state next-state action-result)
     (funcall continuation
              (%make-transition-handoff transition
                                        event-type
                                        previous-state
                                        next-state
                                        action-result)))))

(defun %make-transition-record (transition event-type previous-state next-state action-result)
  (list :from (transition-from transition)
        :event-type event-type
        :to next-state
        :state-before previous-state
        :guard-passed t
        :action-result (%copy-structured-value action-result)))

(defun %record-transition-history (machine transition-record)
  ;; Takes ownership of TRANSITION-RECORD: %COMMIT-TRANSITION/CPS builds it fresh
  ;; and hands independent copies to the trace and the caller, so history can
  ;; store this one directly without a further copy.
  (let ((history-limit (state-machine-history-limit machine)))
    (setf (slot-value machine 'history)
          (%trim-transition-history
           (if (eql history-limit 0)
               '()
               (cons transition-record
                     (%state-machine-history-list machine)))
           history-limit))))

(defun %record-context-trace (context transition-record)
  (when context
    (%push-context-trace-entry context (%copy-transition-record transition-record))))

(defun %commit-transition/cps (machine context handoff continuation)
  (let ((transition-record
          (%make-transition-record
           (%transition-handoff-transition handoff)
           (%transition-handoff-event-type handoff)
           (%transition-handoff-previous-state handoff)
           (%transition-handoff-next-state handoff)
           (%transition-handoff-action-result handoff))))
    (%record-transition-history machine transition-record)
    (setf (state-machine-state machine)
          (%transition-handoff-next-state handoff))
    (when context
      (setf (context-state context)
            (%transition-handoff-next-state handoff)))
    (%record-context-trace context transition-record)
    (funcall continuation machine (%copy-transition-record transition-record))))

(defun %step-state-machine/cps (machine event context event-type continuation)
  (%resolve-transition/cps
   machine
   event
   context
   event-type
   (lambda (transition)
     (%run-transition/cps
     machine
      transition
      event
      context
      event-type
      (lambda (handoff)
        (%commit-transition/cps machine context handoff continuation))))))

(defun %run-state-machine-events/cps (machine events context continuation)
  (labels ((advance-events (current-machine remaining-events transition-records)
             (if (endp remaining-events)
                 (funcall continuation current-machine (nreverse transition-records))
                 (let ((event (first remaining-events)))
                   (%step-state-machine/cps
                    current-machine
                    event
                    context
                    (%event-type-designator event)
                    (lambda (updated-machine transition-record)
                      (advance-events updated-machine
                                      (rest remaining-events)
                                      (cons transition-record transition-records))))))))
    (advance-events machine events (list))))
