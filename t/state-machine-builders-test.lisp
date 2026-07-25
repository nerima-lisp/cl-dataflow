(in-package #:cl-dataflow.test)

(deftest state-machine-to-plist-round-trips-structure
  (with-state-machine-fixture (machine
                                :state "idle"
                                :metadata '((:kind :demo))
                                :transitions ((start "idle" "start" "running")
                                              (finish "running" "finish" "done")))
    (let* ((plist (state-machine-to-plist machine))
            (rebuilt (plist-to-state-machine plist)))
      (is (equal (getf plist :state) "idle"))
      (is (equal (getf plist :initial-state) "idle"))
      (is (equal (state-machine-state rebuilt) "idle"))
      (is (equal (state-machine-states rebuilt) '("done" "idle" "running")))
      ;; The rebuilt machine serialises identically.
      (is (equal (state-machine-to-plist rebuilt) plist)))))

(deftest state-machine-complete-p-checks-totality
  ;; Every (state, event) is defined: a/go->b and b/go->a.
  (with-state-machine-fixture (machine
                                :state "a"
                                :transitions ((ab "a" "go" "b") (ba "b" "go" "a")))
    (is (state-machine-complete-p machine)))
  ;; (b, go) is missing, so it is not complete.
  (with-state-machine-fixture (machine
                                :state "a"
                                :transitions ((ab "a" "go" "b")))
    (is (not (state-machine-complete-p machine)))))

(deftest state-machine-transition-for-looks-up-by-state-and-event
  (with-state-machine-fixture (machine
                                :state "a"
                                :transitions ((go "a" "go" "b") (stop "a" "stop" "c")))
    (let ((found (state-machine-transition-for machine "a" "stop")))
      (is (equal (transition-to found) "c")))
    ;; No transition from b at all.
    (is (null (state-machine-transition-for machine "b" "go")))
    ;; Right state, wrong event.
    (is (null (state-machine-transition-for machine "a" "pause")))))

(deftest
  state-machine-transition-for-returns-independent-copy
  (let* ((machine
        (make-state-machine
          :state
          "a"
          :transitions
          (list (make-transition "a" "go" "b" :metadata '((:label "original"))))))
          (found (state-machine-transition-for machine "a" "go")))
    (setf (transition-metadata found) '((:label "mutated")))
    (is
      (equal
        (transition-metadata (state-machine-transition-for machine "a" "go"))
        '((:label "original"))))))

(deftest
  add-and-remove-transition-mutate-in-place
  (with-state-machine-fixture
    (machine :state "a" :transitions ((ab "a" "go" "b")))
    (step-state-machine machine "go")
    (add-transition machine "b" "back" "a")
    (is (= (length (state-machine-transitions machine)) 2))
    (is (state-machine-transition-for machine "b" "back"))
    (step-state-machine machine "back")
    (is (equal (state-machine-state machine) "a"))
    (remove-transition machine "a" "go" "b")
    (is (= (length (state-machine-transitions machine)) 1))
    (is (null (state-machine-transition-for machine "a" "go")))
    (signals invalid-transition-error (step-state-machine machine "go"))))

(deftest state-machine-relabel-state-renames-everywhere
  (with-state-machine-fixture (machine
                                :state "idle"
                                :transitions ((start "idle" "start" "running")
                                              (finish "running" "finish" "idle")))
    (let ((relabeled (state-machine-relabel-state machine "idle" "ready")))
      (is (equal (state-machine-state relabeled) "ready"))
      (is (equal (state-machine-initial-state relabeled) "ready"))
      (is (equal (state-machine-states relabeled) '("ready" "running")))
      ;; The original is unchanged.
      (is (equal (state-machine-state machine) "idle")))))

(deftest state-machine->graph-enables-graph-analysis
  ;; A cyclic lifecycle a -> b -> c -> a.
  (with-state-machine-fixture (machine
                                :state "a"
                                :transitions ((ab "a" "go" "b")
                                              (bc "b" "go" "c")
                                              (ca "c" "reset" "a")))
    (let ((graph (state-machine->graph machine)))
      (is (equal (graph-node-names graph) '("a" "b" "c")))
      (is (= (graph-size graph) 3))
      ;; The whole graph toolkit now applies to the state machine.
      (is (graph-strongly-connected-p graph))
      (is (graph-find-cycle graph))
      ;; Each edge records its transition's event type in metadata.
      (let ((ab (find-if (lambda (edge)
                            (and (equal (edge-from edge) "a")
                                (equal (edge-to edge) "b")))
                          (graph-edges graph))))
        (is (equal (getf (edge-metadata ab) :event) "go")))))
  ;; Parallel transitions between the same states collapse to one edge.
  (with-state-machine-fixture (machine
                                :state "a"
                                :transitions ((go "a" "go" "b") (jump "a" "jump" "b")))
    (is (= (graph-size (state-machine->graph machine)) 1))))
