(in-package #:cl-dataflow.test)

;;;; Model-based / stateful property testing of the state-machine runtime.
;;;;
;;;; `gen-state-machine` drives a reference transition model over a random event
;;;; trace and records the resulting states. The same trace is replayed through
;;;; the real `run-state-machine`, and the two final states must agree. This is a
;;;; differential test: the cl-weave model and the cl-dataflow runtime are
;;;; independent implementations of the same transition relation.
;;;;
;;;; The machine is TOTAL over the event alphabet {"fwd", "back"} across states
;;;; {"a", "b", "c"} (every state/event pair has exactly one transition), so no
;;;; event in a generated trace can raise INVALID-TRANSITION-ERROR.

(defun %cyclic-reference-step (state event)
  (if (string= event "fwd")
      (cond ((string= state "a") "b")
            ((string= state "b") "c")
            (t "a"))
      (cond ((string= state "a") "c")
            ((string= state "c") "b")
            (t "a"))))

(defun %build-cyclic-machine ()
  (make-state-machine
   :state "a"
   :transitions (list (make-transition "a" "fwd" "b")
                      (make-transition "b" "fwd" "c")
                      (make-transition "c" "fwd" "a")
                      (make-transition "a" "back" "c")
                      (make-transition "b" "back" "a")
                      (make-transition "c" "back" "b"))))

(it-property "run-state-machine matches a reference model over random event traces"
    ((trace (gen-state-machine "a"
                               #'%cyclic-reference-step
                               (gen-member '("fwd" "back"))
                               :min-length 0
                               :max-length 40)))
  (let ((events (getf trace :events))
        (expected-final (getf trace :final))
        (machine (%build-cyclic-machine)))
    (multiple-value-bind (updated-machine records)
        (run-state-machine machine events)
      (is (equal (length records) (length events)))
      (is (equal (state-machine-state updated-machine) expected-final)))))

(it-property "state-machine history records every applied transition in order"
    ((trace (gen-state-machine "a"
                               #'%cyclic-reference-step
                               (gen-member '("fwd" "back"))
                               :min-length 0
                               :max-length 40)))
  (let ((events (getf trace :events))
        (machine (%build-cyclic-machine)))
    (run-state-machine machine events)
    ;; History is newest-first; reversed it is the applied event order.
    (is (equal (reverse (mapcar (lambda (record) (getf record :event-type))
                                (state-machine-history machine)))
               events))))
