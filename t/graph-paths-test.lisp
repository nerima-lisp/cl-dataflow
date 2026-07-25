(in-package #:cl-dataflow.test)

;;;; Simple-path enumeration and cycle discovery, mirroring src/graph-paths.lisp.

(deftest graph-all-paths-enumerates-simple-paths
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    (is (equal (graph-all-paths graph "a" "d")
               '(("a" "b" "d") ("a" "c" "d"))))
    (is (equal (graph-all-paths graph "a" "d" :max-depth 1) '()))
    (is (equal (graph-all-paths graph "a" "d" :max-paths 0) '()))
    (is (equal (graph-all-paths graph "a" "d" :max-paths nil)
               '(("a" "b" "d") ("a" "c" "d"))))
    (signals invalid-input-error (graph-all-paths graph "a" "d" :max-paths 1))
    (signals invalid-input-error (graph-all-paths graph "a" "d" :max-paths 1.5))
    (signals invalid-input-error (graph-all-paths graph "a" "d" :max-depth -1)))
  ;; FROM = TO is the trivial path.
  (with-graph-fixture (graph ((a "a")))
    (is (equal (graph-all-paths graph "a" "a") '(("a")))))
  ;; b -> a is a back-edge to an already-visited node; exploring it (while a is on
  ;; the path and is not the target) exercises the visited-node skip.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (a c) (b a)))
    (is (equal (graph-all-paths graph "a" "c") '(("a" "c")))))
  (with-graph-fixture (graph ((a "a")))
    (signals node-not-found-error (graph-all-paths graph "a" "missing"))))

(deftest graph-reachability-helper-skips-duplicate-frontier-nodes
  (let ((successors (make-hash-table :test #'equal)))
    (setf (gethash "start" successors) '("a" "b")
          (gethash "a" successors) '("shared")
          (gethash "b" successors) '("shared")
          (gethash "shared" successors) '("a"))
    (is (not (cl-dataflow::%reachable-through-successors-p
              successors "start" "missing"))))
  (let ((successors (make-hash-table :test #'equal)))
    (setf (gethash "start" successors) '("shared" "shared")
          (gethash "shared" successors) '("start"))
    (is (not (cl-dataflow::%reachable-through-successors-p
              successors "start" "missing")))))

(deftest graph-prolog-traversal-dedups-parallel-edges-and-converging-paths
  ;; Two edges sharing the same (from . to) node pair via different ports
  ;; exercise the SEEN-PAIRS dedup in %GRAPH-ADJACENCY and
  ;; %GRAPH-DIRECTIONAL-ADJACENCY, which otherwise only ever sees each pair once.
  (with-graph-fixture (graph
                       ((a "a" :outputs '("left" "right"))
                        (b "b" :inputs '("left" "right")))
                       :edges ((a b :from-port "left" :to-port "left")
                               (a b :from-port "right" :to-port "right")))
    (is (graph-reachable-p graph "a" "b"))
    (is (equal (graph-path graph "a" "b") '("a" "b")))
    (is (equal (mapcar #'node-name (graph-descendants graph "a")) '("b")))
    (is (equal (mapcar #'node-name (graph-ancestors graph "b")) '("a"))))
  ;; A diamond graph (A -> B, A -> C, B -> D, C -> D) means D is discovered
  ;; through both B and C, exercising the already-ENQUEUED skip in GRAPH-PATH's
  ;; breadth-first search.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    (is (equal (graph-path graph "a" "d") '("a" "b" "d")))))

(deftest graph-find-cycle-returns-a-cycle-or-nil
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (c a)))
    (let ((cycle (graph-find-cycle graph)))
      (is (equal (first cycle) (car (last cycle))))
      (is (>= (length cycle) 4))))
  ;; A self-loop is a length-1 cycle.
  (with-graph-fixture (graph ((x "x")) :edges ((x x)))
    (is (equal (graph-find-cycle graph) '("x" "x"))))
  ;; Acyclic graphs have no cycle.
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b)))
    (is (null (graph-find-cycle graph)))))
