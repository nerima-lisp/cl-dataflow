(in-package #:cl-dataflow.test)

(defun %names (nodes)
  (mapcar #'node-name nodes))

(deftest graph-transitive-closure-connects-all-reachable-pairs
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (let ((closure (graph-transitive-closure graph)))
      (is (equal (%names (graph-successors closure "a")) '("b" "c")))
      (is (= (graph-size closure) 3))))
  ;; A cycle gives every member a self-edge.
  (with-graph-fixture (graph
                       ((a "a") (b "b"))
                       :edges ((a b) (b a)))
    (let ((closure (graph-transitive-closure graph)))
      (is (equal (%names (graph-successors closure "a")) '("a" "b")))
      (is (= (graph-size closure) 4)))))

(deftest graph-transitive-reduction-drops-redundant-edges
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (a c)))
    (let ((reduced (graph-transitive-reduction graph)))
      ;; a -> c is implied by a -> b -> c and is removed.
      (is (= (graph-size reduced) 2))
      (is (equal (%names (graph-successors reduced "a")) '("b")))
      ;; Reachability is preserved.
      (is (graph-reachable-p reduced "a" "c"))))
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (a d) (b d) (c d)))
    (let ((reduced (graph-transitive-reduction graph)))
      (is (= (graph-size reduced) 4))
      (is (equal (%names (graph-successors reduced "a")) '("b" "c")))
      (is (graph-reachable-p reduced "a" "d"))))
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b) (b a)))
    (signals graph-cycle-error (graph-transitive-reduction graph))))

(deftest graph-topological-rank-measures-longest-source-distance
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    (is (equal (graph-topological-rank graph)
               '(("a" . 0) ("b" . 1) ("c" . 1) ("d" . 2)))))
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b) (b a)))
    (signals graph-cycle-error (graph-topological-rank graph))))

(deftest graph-longest-path-finds-the-critical-path
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    ;; Both a-b-d and a-c-d have length 2; b sorts first, so b is chosen.
    (is (equal (graph-longest-path graph) '("a" "b" "d"))))
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c)))
    (is (equal (graph-longest-path graph) '("a" "b" "c"))))
  (is (null (graph-longest-path (make-graph))))
  (with-graph-fixture (graph ((solo "solo")))
    (is (equal (graph-longest-path graph) '("solo"))))
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b) (b a)))
    (signals graph-cycle-error (graph-longest-path graph))))
