(in-package #:cl-dataflow.test)

(defun %tiny-pipeline (metadata)
  (let ((graph (make-graph)))
    (add-node graph (make-node "a"))
    (add-node graph (make-node "b"))
    (add-edge graph "a" "b")
    (make-pipeline :graph graph :metadata metadata)))

(deftest pipeline-equal-p-compares-structure
  (is (pipeline-equal-p (%tiny-pipeline '((:k :v))) (%tiny-pipeline '((:k :v)))))
  (is (not (pipeline-equal-p (%tiny-pipeline '((:k :v))) (%tiny-pipeline '((:k :other)))))))

(deftest state-machine-equal-p-compares-structure
  (with-state-machine-fixture (left
                               :state "idle"
                               :transitions ((s "idle" "go" "run")))
    (with-state-machine-fixture (right
                                 :state "idle"
                                 :transitions ((s "idle" "go" "run")))
      (is (state-machine-equal-p left right)))
    (with-state-machine-fixture (different
                                 :state "idle"
                                 :transitions ((s "idle" "go" "stop")))
      (is (not (state-machine-equal-p left different))))))

(deftest context-equal-p-compares-observable-state
  (let ((left (make-context :state :done))
        (right (make-context :state :done))
        (other (make-context :state :pending)))
    (emit-event left :a)
    (emit-event right :a)
    (is (context-equal-p left right))
    (is (not (context-equal-p left other)))))

(deftest state-machine-reachable-p-answers-reachability
  (with-state-machine-fixture (machine
                               :state "a"
                               :transitions ((ab "a" "go" "b") (bc "b" "go" "c")))
    (is (state-machine-reachable-p machine "a" "c"))
    (is (state-machine-reachable-p machine "a" "a"))
    (is (not (state-machine-reachable-p machine "c" "a")))
    (is (not (state-machine-reachable-p machine "missing" "missing")))))
