(in-package #:cl-dataflow.test)

(deftest define-state-machine-builds-a-machine-from-declarative-clauses
  (let* ((machine (define-state-machine (:initial-state "idle"
                                        :history-limit 2
                                        :metadata '((:kind :workflow)))
                    ("idle" "start" "running"
                     :metadata '((:transition :start)))
                    ("running" "finish" "done")))
         (transitions (state-machine-transitions machine)))
    (is (equal (state-machine-state machine) "idle"))
    (is (= (state-machine-history-limit machine) 2))
    (is (equal (state-machine-metadata machine) '((:kind :workflow))))
    (is (= (length transitions) 2))
    (is (equal (transition-metadata (first transitions))
               '((:transition :start))))))

(define-invalid-dsl-test define-state-machine-rejects-invalid-options-at-macroexpand-time
  (define-state-machine (:state "idle" :transitions '())
    ("idle" "start" "running"))
  :transitions
  "Unsupported DEFINE-STATE-MACHINE option")

(define-invalid-dsl-test define-state-machine-rejects-non-plist-top-level-options
  (define-state-machine (:initial-state "idle" :metadata)
    ("idle" "start" "running"))
  '(:initial-state "idle" :metadata)
  "DEFINE-STATE-MACHINE options must be a property list")

(define-invalid-dsl-test define-state-machine-rejects-non-list-clauses-at-macroexpand-time
  (define-state-machine (:initial-state "idle")
    :transition)
  :transition
  "DEFINE-STATE-MACHINE clauses require FROM EVENT TO")

(define-invalid-dsl-test define-state-machine-rejects-short-clauses-at-macroexpand-time
  (define-state-machine (:initial-state "idle")
    ("idle" "start"))
  '("idle" "start")
  "DEFINE-STATE-MACHINE clauses require FROM EVENT TO")

(define-invalid-dsl-test define-state-machine-rejects-non-plist-transition-options
  (define-state-machine (:initial-state "idle")
    ("idle" "start" "running" :metadata))
  '(:metadata)
  "DEFINE-STATE-MACHINE transition options must be a property list")

(define-invalid-dsl-option-test define-state-machine-rejects-invalid-transition-options-at-macroexpand-time
  (define-state-machine (:initial-state "idle")
    ("idle" "start" "running" :handler #'identity))
  :handler
  "Unsupported DEFINE-STATE-MACHINE transition option")
