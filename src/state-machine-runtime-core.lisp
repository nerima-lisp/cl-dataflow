(in-package #:cl-dataflow)

;;;; State-machine construction (MAKE-TRANSITION, MAKE-STATE-MACHINE,
;;;; COPY-STATE-MACHINE) and the transition-selection internals
;;;; (%FIND-TRANSITION-SELECTION, %TRANSITION-GUARD-SATISFIED-P) the CPS
;;;; execution layer in state-machine-runtime-cps.lisp drives.

(defun make-transition (from event-type to &key guard action metadata)
  (make-instance 'state-transition
                 :from (%normalize-name from)
                 :event-type (%normalize-name event-type)
                 :to (%normalize-name to)
                 :guard guard
                 :action action
                 :metadata (%normalize-metadata metadata)))

(defun %resolve-state-machine-state (state initial-state)
  (cond
    (state
     (let ((resolved-state (%normalize-name state))
           (resolved-initial-state (%normalize-name (or initial-state state))))
       (values resolved-state resolved-initial-state)))
    (initial-state
     (let ((resolved-initial-state (%normalize-name initial-state)))
       (values resolved-initial-state resolved-initial-state)))
    (t
     (%signal-invalid-input-error
       '(or state initial-state)
       nil
       "State machine requires STATE or INITIAL-STATE."))))

(defun %copy-transition-history (history)
  (mapcar #'%copy-transition-record history))

(defun %validate-state-machine-history-limit (limit)
  (unless (or (null limit)
              (and (integerp limit) (not (minusp limit))))
    (%signal-invalid-input-error
      '(or null unsigned-integer)
      limit
      "STATE-MACHINE-HISTORY-LIMIT limit must be NIL or a non-negative integer."))
  limit)

(defun %trim-transition-history (history limit)
  (if (and limit (< limit (length history)))
      (subseq history 0 limit)
      history))

(defun %copy-state-transition (transition)
  (unless (state-transition-p transition)
    (%signal-invalid-input-error
      'state-transition
      transition
      (format nil "Expected STATE-TRANSITION, got ~S" transition)))
  (make-transition (transition-from transition)
                   (transition-event-type transition)
                   (transition-to transition)
                   :guard (transition-guard transition)
                   :action (transition-action transition)
                   :metadata (transition-metadata transition)))

(defun %copy-transition-record (record)
  (%copy-structured-value record))

(defun make-state-machine (&key state initial-state transitions history history-limit metadata)
  (multiple-value-bind (resolved-state resolved-initial-state)
      (%resolve-state-machine-state state initial-state)
    (let ((resolved-history-limit
            (%validate-state-machine-history-limit history-limit)))
      (make-instance 'state-machine
                     :state resolved-state
                     :initial-state resolved-initial-state
                     :transitions transitions
                     :history (%trim-transition-history
                               (%copy-transition-history history)
                               resolved-history-limit)
                     :history-limit resolved-history-limit
                     :metadata (%normalize-metadata metadata)))))

(defun %make-state-machine-transition-index (transitions)
  "Build the FROM-state -> event-type -> transitions lookup MACHINE selects on.
Both levels are EQUALP hash tables (case-insensitive string keys, matching the
old STRING-EQUAL scan), and each candidate list preserves definition order so
guard fall-through still picks the first satisfied transition."
  (let ((index (make-hash-table :test 'equalp)))
    (dolist (transition transitions)
      (let* ((from-key (copy-seq (string (transition-from transition))))
             (event-key (copy-seq (string (transition-event-type transition))))
             (event-index (or (gethash from-key index)
                              (setf (gethash from-key index)
                                    (make-hash-table :test 'equalp)))))
        (push transition (gethash event-key event-index))))
    (maphash (lambda (from-key event-index)
               (declare (ignore from-key))
               (maphash (lambda (event-key candidates)
                          (setf (gethash event-key event-index) (nreverse candidates)))
                        event-index))
             index)
    index))

(defun %reindex-state-machine-transitions (machine transitions)
  "Store a freshly-copied TRANSITIONS list on MACHINE together with its lookup
index, keeping the two slots in lock-step."
  (let ((copied (mapcar #'%copy-state-transition transitions)))
    (setf (slot-value machine 'transitions) copied
          (slot-value machine 'transition-index)
          (%make-state-machine-transition-index copied))))

(defmethod initialize-instance :after ((machine state-machine) &key)
  (%reindex-state-machine-transitions machine (slot-value machine 'transitions)))

(defmethod (setf state-machine-transitions) (transitions (machine state-machine))
  (%reindex-state-machine-transitions machine transitions)
  transitions)

(defmethod state-machine-transitions ((machine state-machine))
  (mapcar #'%copy-state-transition
          (slot-value machine 'transitions)))

(defun copy-state-machine (machine)
  (make-state-machine :state (state-machine-state machine)
                      :initial-state (state-machine-initial-state machine)
                      :transitions (%state-machine-transitions-list machine)
                      ;; Live list, like :TRANSITIONS above -- MAKE-STATE-MACHINE
                      ;; already runs %COPY-TRANSITION-HISTORY over whatever it is
                      ;; given, so reading through the copying STATE-MACHINE-HISTORY
                      ;; and copying that again made three copies to produce one.
                      :history (%state-machine-history-list machine)
                      :history-limit (state-machine-history-limit machine)
                      :metadata (%normalize-metadata (state-machine-metadata machine))))

(defun reset-state-machine (machine)
  (setf (state-machine-state machine)
        (state-machine-initial-state machine))
  machine)

(defun state-machine-last-transition (machine)
  (%last-raw-item (%state-machine-history-list machine) #'%copy-transition-record))

(defun %event-type-designator (event)
  (typecase event
    (event (event-type event))
    (t (%normalize-name event))))

(defun %indexed-matching-transitions (machine event-type)
  "Every transition whose FROM state and EVENT-TYPE match MACHINE's current state,
in definition order, read from the precomputed transition index in O(1) rather
than scanning the whole transition list."
  (let ((event-index (gethash (string (state-machine-state machine))
                              (slot-value machine 'transition-index))))
    (when event-index
      (gethash (string event-type) event-index))))

(defun %transition-guard-satisfied-p (transition machine event context)
  (let ((guard (transition-guard transition)))
    (or (null guard)
        (funcall guard machine event context))))

(defun %find-transition-selection (machine event context event-type)
  "Return selected transition and the first matching transition, if any."
  (loop with first-match = nil
        for transition in (%indexed-matching-transitions machine event-type)
        do (when (%transition-guard-satisfied-p transition machine event context)
             (return (values transition transition)))
           (unless first-match
             (setf first-match transition))
        finally (return (values nil first-match))))

(defun %transition-error-detail (machine event-type &optional (detail "No transition"))
  (format nil "~A from ~A on event ~A" detail
          (%escaped-display-string (state-machine-state machine))
          (%escaped-display-string event-type)))

(defun %guard-error-detail (machine event-type)
  (%transition-error-detail machine event-type "Guard rejected transition"))
