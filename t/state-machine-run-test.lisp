(in-package #:cl-dataflow.test)

(deftest state-machine-run-sequence
  (with-state-machine-run-fixture (machine)
    (multiple-value-bind (updated-machine transition-records)
        (run-state-machine machine '("start" "finish"))
      (declare (ignore updated-machine))
      (assert-event-sequence transition-records '("start" "finish")))
    (assert-state-machine-state machine "completed")))

(deftest state-machine-run-sequence-accepts-event-objects
  (with-state-machine-run-fixture (machine)
    (let ((events (list (make-event "start" :payload '(:step 1))
                        (make-event "finish" :payload '(:step 2)))))
      (multiple-value-bind (updated-machine transition-records)
          (run-state-machine machine events)
        (declare (ignore updated-machine))
        (assert-event-sequence transition-records '("start" "finish"))
        (is (equal (state-machine-state machine) "completed"))))))

(deftest state-machine-run-with-context-returns-transition-records-and-context
  (with-state-machine-run-fixture (machine)
    (multiple-value-bind (updated-machine transition-records context)
        (run-state-machine-with-context machine '("start" "finish"))
      (declare (ignore updated-machine))
      (assert-event-sequence transition-records '("start" "finish"))
      (is (equal (context-state context) "completed"))
      (assert-event-sequence (context-trace context) '("finish" "start")))))

(deftest state-machine-run-with-context-reuses-provided-context
  (with-idle-start-transition-machine (machine)
    (let ((context (make-context :state "idle")))
      (multiple-value-bind (updated-machine transition-records returned-context)
          (run-state-machine-with-context machine '("start") :context context)
        (declare (ignore updated-machine))
        (is (eq returned-context context))
        (assert-event-sequence transition-records '("start"))
        (is (equal (context-state context) "running"))
        (assert-event-sequence (context-trace context) '("start"))))))

(deftest state-machine-run-with-context-creates-default-context
  (let ((machine (make-state-machine :state "idle"
                                     :transitions '())))
    (multiple-value-bind (updated-machine transition-records context)
        (run-state-machine-with-context machine '())
      (declare (ignore updated-machine))
      (is (null transition-records))
      (is (context-p context))
      (is (equal (context-state context) "idle"))
      (is (equal (context-trace context) '())))))
