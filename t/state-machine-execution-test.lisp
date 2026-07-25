(in-package #:cl-dataflow.test)

(defmacro with-lifecycle-machine ((machine) &body body)
  "draft -> review -> approved, with review -> rejected as an alternate branch."
  `(with-state-machine-fixture (,machine
                                :state "draft"
                                :transitions ((submit "draft" "submit" "review")
                                              (approve "review" "approve" "approved")
                                              (reject "review" "reject" "rejected")))
     ,@body))

(deftest state-machine-run-states-tracks-visited-states
  (with-lifecycle-machine (machine)
    ;; A fully valid sequence records the initial state plus one per step.
    (is (equal (state-machine-run-states machine '("submit" "approve"))
               '("draft" "review" "approved")))
    ;; The machine is not mutated by the interpretation.
    (is (equal (state-machine-state machine) "draft"))))

(deftest state-machine-run-states-stops-at-an-invalid-event
  (with-lifecycle-machine (machine)
    ;; "approve" is not available from "draft", so it stops after the initial state.
    (is (equal (state-machine-run-states machine '("approve" "submit"))
               '("draft")))
    ;; A valid prefix followed by an invalid event stops after the prefix.
    (is (equal (state-machine-run-states machine '("submit" "submit"))
               '("draft" "review")))))

(deftest state-machine-accepts-p-checks-final-state
  (with-lifecycle-machine (machine)
    (is (state-machine-accepts-p machine '("submit" "approve") '("approved" "rejected")))
    ;; Lands in review, which is not accepting.
    (is (not (state-machine-accepts-p machine '("submit") '("approved" "rejected"))))
    ;; A failed transition is never accepting.
    (is (not (state-machine-accepts-p machine '("approve") '("approved"))))))

(deftest state-machine-event-path-finds-driving-events
  (with-lifecycle-machine (machine)
    (is (equal (state-machine-event-path machine "draft" "approved")
               '("submit" "approve")))
    (is (equal (state-machine-event-path machine "review" "rejected")
               '("reject")))
    ;; Same state needs no events.
    (is (equal (state-machine-event-path machine "draft" "draft") '()))
    (is (null (state-machine-event-path machine "missing" "missing")))
    (is (null (state-machine-event-path machine "draft" "missing")))
    ;; approved is terminal, so nothing leads out of it.
    (is (null (state-machine-event-path machine "approved" "draft")))))

(deftest state-machine-event-path-prefers-shorter-paths-through-diamonds
  ;; a reaches d through b (e1,e3) and through c (e2,e4); BFS must skip the
  ;; second discovery of d and return one shortest two-event path.
  (with-state-machine-fixture (machine
                               :state "a"
                               :transitions ((e1 "a" "e1" "b")
                                             (e2 "a" "e2" "c")
                                             (e3 "b" "e3" "d")
                                             (e4 "c" "e4" "d")))
    (let ((path (state-machine-event-path machine "a" "d")))
      (is (= (length path) 2))
      (is (member (first path) '("e1" "e2") :test #'string=))))
  ;; A self-cycle must not loop forever when the target is unreachable.
  (with-state-machine-fixture (machine
                               :state "x"
                               :transitions ((loop-x "x" "spin" "x")))
    (is (null (state-machine-event-path machine "x" "y")))))
