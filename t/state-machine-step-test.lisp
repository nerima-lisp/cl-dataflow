(in-package #:cl-dataflow.test)

(deftest state-machine-transition
  (with-idle-start-transition-machine (machine)
    (step-state-machine machine "start")
    (is (equal (state-machine-state machine) "running"))))

(deftest state-transition-accessors-and-predicate
  (let ((action (lambda (machine event context)
                  (declare (ignore machine event context))
                  :ok)))
    (with-idle-start-transition-machine (machine :action action)
      (let ((transition (first (state-machine-transitions machine))))
        (is (state-transition-p transition))
        (is (equal (transition-from transition) "idle"))
        (is (eq (transition-action transition) action))))))

(deftest state-machine-guard-failure
  (with-idle-start-transition-machine (machine
                                       :guard (lambda (machine event context)
                                                (declare (ignore machine event context))
                                                nil))
    (signals guard-failed-error
      (step-state-machine machine "start"))))

(deftest state-machine-guard-failure-exposes-condition-data
  (with-idle-start-transition-machine (machine
                                       :guard (lambda (machine event context)
                                                (declare (ignore machine event context))
                                                nil))
    (with-captured-condition (captured guard-failed-error)
        (step-state-machine machine "start")
      (assert-state-machine-condition captured
                                      guard-failed-error
                                      "idle"
                                      "start"
                                      "Guard rejected transition from idle on event start"
                                      :transition (first (state-machine-transitions machine))))))

(deftest state-machine-invalid-transition
  (let ((machine (make-state-machine :state "idle" :transitions '())))
    (signals invalid-transition-error
      (step-state-machine machine "start"))))

(deftest state-machine-invalid-transition-exposes-condition-data
  (let* ((machine (make-state-machine :state "idle" :transitions '()))
         (captured
           (capture-condition (condition invalid-transition-error)
             (step-state-machine machine "start"))))
    (is captured)
    (assert-state-machine-condition captured
                                    invalid-transition-error
                                    "idle"
                                    "start"
                                    "No transition from idle on event start")))

(deftest state-machine-condition-details-escape-control-characters
  (let* ((raw (format nil "spoof~%tab~Creturn~Cdel~Cend"
                       #\Tab
                       #\Return
                       (code-char 127)))
          (state (format nil "idle-~A" raw))
          (event (format nil "start-~A" raw))
          (machine (make-state-machine :state state :transitions '())))
    (with-captured-condition (captured invalid-transition-error)
        (step-state-machine machine event)
      (let ((detail (invalid-transition-detail captured))
            (report (condition-report-string captured)))
        (is (search "\\n" detail))
        (is (search "\\t" detail))
        (is (search "\\r" detail))
        (is (search "\\x7F;" detail))
        (is (search "\\n" report))
        (is (not (search (format nil "~%tab") detail)))
        (is (not (search (format nil "~Creturn" #\Tab) detail)))
        (is (not (search (format nil "~Cdel" #\Return) detail)))))))

(deftest state-machine-action-override
  (with-idle-start-transition-machine (machine
                                       :action (lambda (machine event context)
                                                 (declare (ignore machine event context))
                                                 "completed"))
    (step-state-machine machine "start")
    (is (equal (state-machine-state machine) "completed"))))

(deftest state-machine-constructor-derives-missing-state
  (let ((machine (make-state-machine :initial-state "idle"
                                     :transitions '())))
    (is (equal (state-machine-state machine) "idle"))
    (is (equal (state-machine-initial-state machine) "idle"))))

(deftest state-machine-constructor-requires-an-explicit-state-designator
  (with-captured-condition (captured invalid-input-error)
      (make-state-machine :transitions '())
    (is (equal (invalid-input-expected captured)
               '(or cl-dataflow::state cl-dataflow::initial-state)))
    (is (null (invalid-input-value captured)))
    (is (equal (invalid-input-detail captured)
               "State machine requires STATE or INITIAL-STATE."))))

(deftest state-machine-action-result-is-captured
  (with-idle-start-transition-machine (machine
                                       :action (lambda (machine event context)
                                                 (declare (ignore machine event context))
                                                 (values "completed"
                                                         '(:note "transitioned"))))
      (multiple-value-bind (updated-machine transition-record)
        (step-state-machine machine "start")
      (declare (ignore updated-machine))
      (is (equal (state-machine-state machine) "completed"))
      (assert-transition-record transition-record
        (:action-result '(:note "transitioned")))
      (is (equal transition-record
                 (state-machine-last-transition machine))))))

(deftest state-machine-step-updates-context-state-and-trace
  (with-idle-start-transition-machine (machine)
    (let ((context (make-context :state "idle")))
      (with-stepped-state-machine (updated-machine transition-record machine "start"
                                                       :context context
                                                       :history-entry history-entry
                                                       :trace-entry trace-entry)
        (is (eq updated-machine machine))
        (is (equal (context-state context) "running"))
        (assert-transition-records (list transition-record history-entry)
          (:event-type "start"))
        (assert-transition-record trace-entry
          (:from "idle")
          (:event-type "start")
          (:to "running")
          (:state-before "idle")
          (:guard-passed t)
          (:action-result nil))))))

(deftest state-machine-step-with-event-object-preserves-event-for-action-and-normalizes-state
  (let* ((captured-event nil)
         (captured-context nil)
         (event (make-event "start" :payload '(:step 1))))
    (with-idle-start-transition-machine (machine
                                         :action (lambda (machine action-event action-context)
                                                   (declare (ignore machine))
                                                   (setf captured-event action-event
                                                         captured-context action-context)
                                                   (values 'completed
                                                           (list :event-type (event-type action-event)
                                                                 :payload (event-payload action-event)))))
      (let ((context (make-context :state "idle")))
        (with-stepped-state-machine (updated-machine transition-record machine event
                                                     :context context
                                                     :history-entry history-entry
                                                     :trace-entry trace-entry)
          (is (eq updated-machine machine))
          (is (eq captured-event event))
          (is (eq captured-context context))
          (is (equal (state-machine-state machine) "COMPLETED"))
          (is (equal (context-state context) "COMPLETED"))
          (assert-transition-records (list transition-record history-entry trace-entry)
            (:from "idle")
            (:event-type "start")
            (:to "COMPLETED")
            (:state-before "idle")
            (:guard-passed t)
            (:action-result '(:event-type "start" :payload (:step 1)))))))))

(deftest state-machine-transition-records-are-copied-across-boundaries
  (with-idle-start-transition-machine (machine)
    (let ((context (make-context :state "idle")))
      (with-stepped-state-machine (updated-machine transition-record machine "start"
                                                   :context context
                                                   :history-entry history-record
                                                   :trace-entry trace-record)
        (is (eq updated-machine machine))
        (set-plist-entry transition-record :to "mutated")
        (set-plist-entry history-record :event-type "history-mutated")
        (set-plist-entry trace-record :state-before "trace-mutated")
        (assert-transition-record transition-record
          (:to "mutated"))
        (assert-transition-record history-record
          (:event-type "history-mutated")
          (:to "running")
          (:state-before "idle"))
        (assert-transition-record trace-record
          (:state-before "trace-mutated")
          (:to "running")
          (:event-type "start"))
        (assert-transition-records (list (first (state-machine-history machine))
                                         (first (context-trace context)))
          (:to "running"))))))
