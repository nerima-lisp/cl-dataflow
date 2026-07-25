(in-package #:cl-dataflow.test)

(define-snapshot-isolation-test copy-state-machine-produces-independent-machine
  ((transition (make-transition "idle" "start" "running"
                                 :metadata '((:kind :transition))))
   (payload (vector (list :nested "ok")))
   (history (list (list :from "idle"
                        :event-type "start"
                        :to "running"
                        :state-before "idle"
                        :guard-passed t
                        :action-result payload)))
   (metadata '((:kind :machine)))
   (machine (make-state-machine :state "running"
                                :initial-state "idle"
                                :transitions (list transition)
                                :history history
                                :metadata metadata))
   (replacement-transition (make-transition "running" "stop" "idle")))
  (copy (copy-state-machine machine))
  (progn
    (is (equal (state-machine-state copy) "running"))
    (is (equal (state-machine-initial-state copy) "idle"))
    (is (equal (state-machine-metadata copy) '((:kind :machine))))
    (is (equal (mapcar #'transition-from (state-machine-transitions copy))
               '("idle")))
    (is (equal (mapcar #'transition-event-type (state-machine-transitions copy))
               '("start")))
    (is (equal (mapcar #'transition-to (state-machine-transitions copy))
               '("running")))
    (is (equalp (state-machine-history copy) history))
    (let ((copy-action-result
            (getf (first (slot-value copy 'cl-dataflow::history)) :action-result)))
      (setf (second (aref copy-action-result 0)) "mutated-copy"))
    (setf (state-machine-state copy) "stopped"
          (state-machine-transitions copy) (list replacement-transition)
          (state-machine-history copy)
          (list (list :from "running"
                      :event-type "stop"
                      :to "idle"
                      :state-before "running"
                      :guard-passed t
                       :action-result '(:ok t))))
    (setf (cadar (slot-value copy 'cl-dataflow::metadata)) :mutated-copy))
  (is (equal (state-machine-state machine) "running"))
  (is (equal (state-machine-metadata machine) '((:kind :machine))))
  (is (equal (mapcar #'transition-event-type (state-machine-transitions machine))
             '("start")))
  (is (equalp (state-machine-history machine) history)))

(define-snapshot-isolation-test transition-accessors-return-independent-snapshots
  ((transition (make-transition "idle" "start" "running"
                                :metadata '((:kind :transition)))))
  (metadata-snapshot (transition-metadata transition))
  (setf (cadr (first metadata-snapshot)) :changed)
  (is (equal (transition-metadata transition)
             '((:kind :transition)))))
