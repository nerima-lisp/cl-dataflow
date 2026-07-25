(in-package #:cl-dataflow.test)

;;;; Guards select among transitions that share the same FROM state and event.
;;;; A rejecting guard must fall through to the next matching transition instead
;;;; of aborting the whole step, and GUARD-FAILED-ERROR is signalled only when
;;;; every matching transition's guard rejects.
(defun %always (value)
  (lambda (machine event context)
    (declare (ignore machine event context))
    value))

(defun %guarded-pair-machine (guard-a guard-b)
  "An 'idle' state machine with two candidate transitions on event 'go', to
state 'a' guarded by GUARD-A and to state 'b' guarded by GUARD-B (NIL means
unguarded, matching TRANSITION's own :GUARD default) -- the shared fixture
every guard-selection test below builds, varying only which guards reject,
pass, or are absent."
  (make-state-machine
    :state
    "idle"
    :transitions
    (list
      (make-transition "idle" "go" "a" :guard guard-a)
      (make-transition "idle" "go" "b" :guard guard-b))))

(deftest
  guarded-transition-selection-falls-through-to-passing-guard
  (let ((machine (%guarded-pair-machine (%always nil) nil)))
    (step-state-machine machine "go")
    (is (equal (state-machine-state machine) "b"))))

(deftest
  guarded-transition-selection-prefers-first-passing-guard
  (let ((machine (%guarded-pair-machine (%always t) nil)))
    (step-state-machine machine "go")
    (is (equal (state-machine-state machine) "a"))))

(deftest
  guarded-transition-selection-signals-when-all-guards-reject
  (let ((machine (%guarded-pair-machine (%always nil) (%always nil))))
    (signals guard-failed-error (step-state-machine machine "go"))))

(deftest
  can-step-p-true-when-any-matching-guard-passes
  (let ((machine (%guarded-pair-machine (%always nil) nil)))
    (is (state-machine-can-step-p machine "go"))))

(deftest
  can-step-p-false-when-all-matching-guards-reject
  (let ((machine (%guarded-pair-machine (%always nil) (%always nil))))
    (is (not (state-machine-can-step-p machine "go")))))

(deftest guarded-transition-selection-uses-context
  ;; The runtime context flows into every candidate guard during selection, so a
  ;; context-keyed guard set can enable different transitions from the same
  ;; (state, event) pair. Exercised through CAN-STEP-P, which runs the same
  ;; guard-aware selection without committing a transition.
  (let ((machine (make-state-machine
                  :state "idle"
                  :transitions (list (make-transition
                                      "idle" "go" "blocked"
                                      :guard (lambda (m e context)
                                                (declare (ignore m e))
                                                (eq context :take-blocked)))
                                      (make-transition
                                      "idle" "go" "allowed"
                                      :guard (lambda (m e context)
                                                (declare (ignore m e))
                                                (eq context :take-allowed)))))))
    (is (state-machine-can-step-p machine "go" :context :take-allowed))
    (is (state-machine-can-step-p machine "go" :context :take-blocked))
    (is (not (state-machine-can-step-p machine "go" :context :neither)))))

(deftest state-machine-transition-index-tracks-internal-transitions
  (labels ((bucket (machine state event-type)
              (let ((event-index
                      (gethash (string state)
                              (slot-value machine
                                          'cl-dataflow::transition-index))))
                (and event-index
                    (gethash (string event-type) event-index)))))
    (let* ((first (make-transition 'idle 'go "first"))
            (second (make-transition "IDLE" "go" "second"))
            (other (make-transition "idle" "stop" "stopped"))
            (machine (make-state-machine
                      :state "idle"
                      :transitions (list first second other)))
            (internal
              (cl-dataflow::%state-machine-transitions-list machine))
            (copy (copy-state-machine machine)))
      (is (equal (bucket machine "IDLE" 'go)
                  (subseq internal 0 2)))
      (is (not (eq first (first internal))))
      (is (equal (bucket copy 'idle 'go)
                  (subseq (cl-dataflow::%state-machine-transitions-list copy)
                          0 2)))
      (is (not (eq (first internal)
                    (first (cl-dataflow::%state-machine-transitions-list copy)))))
      (is (state-machine-can-step-p machine 'go))
      (setf (state-machine-transitions machine)
            (list (make-transition "idle" 'resume "running")))
      (is (null (bucket machine "idle" "go")))
      (is (= 1 (length (bucket machine "IDLE" "RESUME"))))))
  (let ((empty (make-state-machine :state "idle")))
    (is (= 0 (hash-table-count
              (slot-value empty
                          'cl-dataflow::transition-index))))))

(deftest state-machine-direct-instance-initializes-transition-index
  (let* ((first (make-transition "idle" "go" "first"))
          (second (make-transition "idle" "go" "second"))
          (machine
              (make-instance
                  'state-machine
                  :state
                  "idle"
                  :initial-state
                  "idle"
                  :transitions
                  (list first second))))
      (is (state-machine-can-step-p machine "go"))
      (is
          (equal
              '("first" "second")
              (mapcar
                  #'transition-to
                  (cl-dataflow::%indexed-matching-transitions machine "go"))))))

(deftest state-machine-transition-index-owns-mutable-names
  (let* ((from (copy-seq "idle"))
          (event-type (copy-seq "go"))
          (machine
              (make-state-machine
                  :state
                  "idle"
                  :transitions
                  (list (make-transition from event-type "done")))))
      (setf (char from 0) (char "x" 0))
      (setf (char event-type 0) (char "n" 0))
      (is (state-machine-can-step-p machine "go"))
      (is (not (state-machine-can-step-p machine "no")))
      (is (not (state-machine-can-step-p machine "xdle")))))

(deftest state-machine-direct-instance-owns-mutable-names
  (let* ((from (copy-seq "idle"))
          (event-type (copy-seq "go"))
          (machine
              (make-instance
                  'state-machine
                  :state
                  "idle"
                  :initial-state
                  "idle"
                  :transitions
                  (list (make-transition from event-type "done")))))
      (setf (char from 0) (char "x" 0))
      (setf (char event-type 0) (char "n" 0))
      (is (state-machine-can-step-p machine "go"))
      (is (not (state-machine-can-step-p machine "no")))
      (is (not (state-machine-can-step-p machine "xdle")))))
