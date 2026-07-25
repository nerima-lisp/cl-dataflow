(in-package #:cl-dataflow.test)

(deftest state-machine-reset-restores-initial-state
  (let ((machine (make-state-machine
                  :state "running"
                  :initial-state "idle"
                  :transitions (list (make-transition "idle" "start" "running")))))
    (reset-state-machine machine)
    (is (equal (state-machine-state machine) "idle"))))

(define-snapshot-isolation-test state-machine-copy-produces-independent-machine
  ((machine (make-state-machine
              :state "idle"
              :metadata '((:kind :original))
              :transitions (list (make-transition "idle" "start" "running"
                                                  :metadata '((:labels "alpha")))))))
  (copy (copy-state-machine machine))
  (progn
    (is (not (eq copy machine)))
    (setf (state-machine-state copy) "running")
    (setf (state-machine-metadata copy) '((:kind :copied)))
    (setf (transition-metadata (first (state-machine-transitions copy)))
          '((:labels "mutated"))))
  (is (equal (state-machine-state machine) "idle"))
  (is (equal (state-machine-metadata machine) '((:kind :original))))
  (is (equal (transition-metadata (first (state-machine-transitions machine)))
              '((:labels "alpha")))))

(define-snapshot-isolation-test state-machine-constructor-copies-transition-objects
  ((transition (make-transition "idle" "start" "running"
                                  :metadata '((:labels "alpha"))))
    (machine (make-state-machine
              :state "idle"
              :transitions (list transition))))
  (stored (first (state-machine-transitions machine)))
  (is (not (eq stored transition)))
  (setf (transition-metadata stored) '((:labels "mutated")))
  (is (equal (transition-metadata transition) '((:labels "alpha")))))

(define-snapshot-isolation-test state-machine-setter-copies-transition-objects
  ((transition (make-transition "idle" "start" "running"
                                  :metadata '((:labels "alpha"))))
    (machine (make-state-machine :state "idle")))
  (stored
    (progn
      (setf (state-machine-transitions machine) (list transition))
      (first (state-machine-transitions machine))))
  (is (not (eq stored transition)))
  (setf (transition-metadata stored) '((:labels "mutated")))
  (is (equal (transition-metadata transition) '((:labels "alpha")))))

(deftest state-machine-rejects-malformed-transition-lists-at-runtime
  (let ((machine (make-state-machine :state "idle")))
    (signals invalid-input-error
      (setf (state-machine-transitions machine)
            (list (list :from "idle" :event "start"))))))

(deftest state-machine-history-captures-transition-trace
  (let* ((machine (make-state-machine
                    :state "idle"
                    :transitions (list (make-transition "idle" "start" "running"
                                                        :action (lambda (machine event context)
                                                                  (declare (ignore machine event context))
                                                                  (values nil :done)))))))
    (multiple-value-bind (updated-machine transition-record)
        (step-state-machine machine "start")
      (is (equal (state-machine-state updated-machine) "running"))
      (assert-transition-record transition-record
        (:from "idle")
        (:event-type "start")
        (:to "running")
        (:state-before "idle")
        (:guard-passed t)
        (:action-result :done))
      (is (equal (state-machine-history updated-machine)
                  (list transition-record))))))

(deftest state-machine-history-limit-retains-zero-one-and-thirty-two-records
  (dolist (history-limit '(0 1 32))
    (let ((machine (make-state-machine
                    :state "idle"
                    :history-limit history-limit
                    :transitions (list (make-transition "idle" "tick" "running")
                                       (make-transition "running" "tick" "idle")))))
      (dotimes (index 33)
        (step-state-machine machine "tick"))
      (is (= (length (state-machine-history machine))
             (min history-limit 33))))))

(deftest state-machine-history-limit-zero-disables-history-retention
  (let ((machine (make-state-machine
                  :state "idle"
                  :history-limit 0
                  :transitions (list (make-transition "idle" "start" "running")))))
    (step-state-machine machine "start")
    (is (null (state-machine-history machine)))))

(deftest state-machine-history-limit-validates-and-trims-history-setters
  (let ((machine (make-state-machine
                  :state "idle"
                  :transitions (list (make-transition "idle" "tick" "running")
                                     (make-transition "running" "tick" "idle")))))
    (signals invalid-input-error
      (make-state-machine :state "idle" :history-limit -1))
    ;; A non-integer limit fails the INTEGERP half of the check rather than
    ;; the MINUSP half -1 exercises above.
    (signals invalid-input-error
      (make-state-machine :state "idle" :history-limit "2"))
    (step-state-machine machine "tick")
    (step-state-machine machine "tick")
    (setf (state-machine-history-limit machine) 1)
    (is (= (state-machine-history-limit machine) 1))
    (is (= (length (state-machine-history machine)) 1))
    (setf (state-machine-history machine)
          (list '(:from "manual-1") '(:from "manual-2")))
    (is (equal (state-machine-history machine)
               '((:from "manual-1"))))))

(deftest state-machine-copy-preserves-history-limit
  (let ((copy (copy-state-machine
               (make-state-machine :state "idle" :history-limit 3))))
    (is (= (state-machine-history-limit copy) 3))))

(deftest state-machine-step-defaults-guard-and-action-to-pass-through
  (let ((machine (make-state-machine
                  :state "idle"
                  :transitions (list (make-transition "idle" "start" "running")))))
    (multiple-value-bind (updated-machine transition-record)
        (step-state-machine machine "start")
      (is (equal (state-machine-state updated-machine) "running"))
      (assert-transition-record transition-record
        (:from "idle")
        (:event-type "start")
        (:to "running")
        (:guard-passed t)
        (:action-result nil)))))

(deftest state-machine-transition-record-history-trace-and-return-are-independent
  (let* ((payload (vector (list :nested "ok")))
         (context (make-context :state "idle"))
         (machine (make-state-machine
                   :state "idle"
                   :history-limit 32
                   :transitions (list (make-transition
                                       "idle" "start" "running"
                                       :action (lambda (machine event context)
                                                 (declare (ignore machine event context))
                                                 (values nil payload)))))))
    (multiple-value-bind (updated-machine returned-record)
        (step-state-machine machine "start" :context context)
      (let* ((history-record
               (first (cl-dataflow::%state-machine-history-list updated-machine)))
             (trace-record
               (first (cl-dataflow::%context-trace-list context)))
             (returned-result (getf returned-record :action-result))
             (history-result (getf history-record :action-result))
             (trace-result (getf trace-record :action-result)))
        (is (not (eq returned-record history-record)))
        (is (not (eq returned-record trace-record)))
        (is (not (eq history-record trace-record)))
        (is (not (eq returned-result history-result)))
        (is (not (eq returned-result trace-result)))
        (is (not (eq history-result trace-result)))
        (setf (second (aref returned-result 0)) "mutated-return")
        (is (equalp history-result #((:nested "ok"))))
        (is (equalp trace-result #((:nested "ok"))))))))

(deftest state-machine-history-copies-hash-table-action-results
  (let* ((payload (make-hash-table :test #'equal))
         (nested (vector (list :nested "ok")))
         (machine (make-state-machine
                   :state "idle"
                   :transitions (list (make-transition
                                       "idle" "start" "running"
                                       :action (lambda (machine event context)
                                                 (declare (ignore machine event context))
                                                 (values nil payload)))))))
    (setf (gethash "payload" payload) nested)
    (multiple-value-bind (updated-machine transition-record)
        (step-state-machine machine "start")
      (let ((returned-result (getf transition-record :action-result))
            (history-result (getf (first (state-machine-history updated-machine))
                                  :action-result)))
        (is (hash-table-p returned-result))
        (is (hash-table-p history-result))
        (is (not (eq returned-result payload)))
        (is (not (eq history-result payload)))
        (is (not (eq (gethash "payload" returned-result) nested)))
        (is (not (eq (gethash "payload" history-result) nested)))
        (is (equalp (gethash "payload" returned-result)
                    #((:nested "ok"))))
        (is (equalp (gethash "payload" history-result)
                    #((:nested "ok"))))
        (setf (second (aref (gethash "payload" returned-result) 0))
              "mutated-return")
        (setf (second (aref (gethash "payload" history-result) 0))
              "mutated-history")
        (let ((fresh-result (getf (first (state-machine-history updated-machine))
                                  :action-result)))
          (is (equalp (gethash "payload" fresh-result)
                      #((:nested "ok")))))))))

(deftest state-machine-reset-keeps-history
  (let ((machine (make-state-machine
                  :state "idle"
                  :initial-state "idle"
                  :transitions (list (make-transition "idle" "start" "running")))))
    (step-state-machine machine "start")
    (let ((history-before (copy-list (state-machine-history machine))))
      (reset-state-machine machine)
      (is (equal (state-machine-state machine) "idle"))
      (is (equal (state-machine-history machine) history-before)))))
