(in-package #:cl-dataflow.test)

(defun %weighted-graph (node-names edges)
  "EDGES: list of (from to weight &optional from-port to-port)."
  (let ((graph (make-graph)))
    (dolist (name node-names)
      (add-node graph (make-node name)))
    (dolist (spec edges)
      (destructuring-bind (from to weight &optional (from-port "value") (to-port "value"))
          spec
        (let ((edge (add-edge graph from to :from-port from-port :to-port to-port)))
          (setf (edge-metadata edge) (list :weight weight)))))
    graph))

(deftest graph-weighted-distance-runs-dijkstra
  (let ((graph (%weighted-graph '("a" "b" "c" "d")
                                '(("a" "b" 2) ("a" "c" 5) ("a" "d" 1)
                                  ("b" "c" 1) ("b" "d" 10) ("c" "d" 1)))))
    ;; a -> b -> c costs 3, cheaper than the direct a -> c of 5.
    (is (= (graph-weighted-distance graph "a" "c") 3))
    ;; The direct a -> d of 1 beats every longer route.
    (is (= (graph-weighted-distance graph "a" "d") 1))
    ;; d is a sink, so nothing is reachable from it.
    (is (null (graph-weighted-distance graph "d" "a"))))
  ;; b (cost 1) settles before c (cost 2), so when c later relaxes d it offers a
  ;; longer route that must be rejected -- exercising the not-shorter relaxation.
  (let ((graph (%weighted-graph '("a" "b" "c" "d")
                                '(("a" "b" 1) ("a" "c" 2) ("b" "d" 1) ("c" "d" 1)))))
    (is (= (graph-weighted-distance graph "a" "d") 2))))

(deftest graph-weighted-distance-defaults-and-parallel-edges
  ;; With no weights every edge costs the default, so distance is hop count.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c)))
    (is (= (graph-weighted-distance graph "a" "c") 2)))
  ;; Parallel edges collapse to the cheapest. Three of them (added dear, cheap,
  ;; mid) drive both the "cheaper than existing" and "not cheaper" comparisons as
  ;; the newest-first edge list is folded.
  (let ((graph (make-graph)))
    (add-node graph (make-node "a" :outputs '("p1" "p2" "p3")))
    (add-node graph (make-node "b"))
    (let ((dear (add-edge graph "a" "b" :from-port "p1"))
          (cheap (add-edge graph "a" "b" :from-port "p2"))
          (mid (add-edge graph "a" "b" :from-port "p3")))
      (setf (edge-metadata dear) '(:weight 5)
            (edge-metadata cheap) '(:weight 2)
            (edge-metadata mid) '(:weight 8)))
    (is (= (graph-weighted-distance graph "a" "b") 2)))
  ;; FROM = TO resolves only through a cycle.
  (let ((graph (%weighted-graph '("a" "b") '(("a" "b" 1) ("b" "a" 1)))))
    (is (= (graph-weighted-distance graph "a" "a") 2))))

(deftest graph-weighted-path-returns-the-cheapest-route
  (let ((graph (%weighted-graph '("a" "b" "c" "d")
                                '(("a" "b" 2) ("a" "c" 5) ("b" "c" 1) ("c" "d" 1)))))
    ;; a -> b -> c -> d (2+1+1=4) beats a -> c -> d (5+1=6).
    (is (equal (graph-weighted-path graph "a" "d") '("a" "b" "c" "d")))
    (is (null (graph-weighted-path graph "d" "a"))))
  ;; FROM = TO returns the cycle.
  (let ((graph (%weighted-graph '("a" "b") '(("a" "b" 1) ("b" "a" 1)))))
    (is (equal (graph-weighted-path graph "a" "a") '("a" "b" "a"))))
  ;; A custom weight key with a default for unlabelled edges.
  (let ((graph (make-graph)))
    (dolist (name '("a" "b" "c")) (add-node graph (make-node name)))
    (add-edge graph "b" "c")
    (setf (edge-metadata (add-edge graph "a" "b")) '(:cost 3))
    (is (equal (graph-weighted-path graph "a" "c" :weight-key :cost :default-weight 10)
               '("a" "b" "c"))))
  ;; b (cost 1) settles before c (cost 2); c's later relaxation of d is longer and
  ;; must be rejected, exercising the not-shorter relaxation with previous tracking.
  (let ((graph (%weighted-graph '("a" "b" "c" "d")
                                '(("a" "b" 1) ("a" "c" 2) ("b" "d" 1) ("c" "d" 1)))))
    (is (equal (graph-weighted-path graph "a" "d") '("a" "b" "d")))))

(deftest graph-weighted-distance-honours-custom-weight-key-and-default
  (let ((graph (make-graph)))
    (dolist (name '("a" "b" "c"))
      (add-node graph (make-node name)))
    ;; a -> b carries an explicit :cost of 7; b -> c has no :cost and falls back
    ;; to the supplied default of 10.
    (add-edge graph "b" "c")
    (setf (edge-metadata (add-edge graph "a" "b")) '(:cost 7))
    (is (= (graph-weighted-distance graph "a" "b" :weight-key :cost :default-weight 10) 7))
    (is (= (graph-weighted-distance graph "a" "c" :weight-key :cost :default-weight 10) 17))))

(deftest graph-weighted-rejects-invalid-weights
  (let ((graph (%weighted-graph '("a" "b") '(("a" "b" -1)))))
    (signals invalid-input-error
      (graph-weighted-distance graph "a" "b"))
    (signals invalid-input-error
      (graph-weighted-path graph "a" "b"))
    (signals invalid-input-error
      (graph-weighted-distances-from graph "a")))
  (let ((graph (%weighted-graph '("a" "b") '(("a" "b" :heavy)))))
    (signals invalid-input-error
      (graph-weighted-distance graph "a" "b")))
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b)))
    (signals invalid-input-error
      (graph-weighted-distance graph "a" "b" :default-weight -1))))

(deftest graph-weighted-distances-from-runs-dijkstra-to-all
  ;; From a: b costs 2 directly; c is cheaper via b (2+3=5) than the direct a->c
  ;; edge of 10, so Dijkstra must relax it down. Ordered by name; a itself is
  ;; absent because no path returns to it. Uses the default :weight key.
  (let ((graph (%weighted-graph '("a" "b" "c")
                                '(("a" "b" 2) ("b" "c" 3) ("a" "c" 10)))))
    (is (equal (graph-weighted-distances-from graph "a") '(("b" . 2) ("c" . 5))))
    ;; A sink reaches nothing, so the alist is empty.
    (is (null (graph-weighted-distances-from graph "c"))))
  ;; A custom weight key with an explicit default exercises the supplied-argument
  ;; branches: a->b carries :cost 7, b->c has none and falls back to 10.
  (let ((graph (make-graph)))
    (dolist (name '("a" "b" "c"))
      (add-node graph (make-node name)))
    (add-edge graph "b" "c")
    (setf (edge-metadata (add-edge graph "a" "b")) '(:cost 7))
    (is (equal (graph-weighted-distances-from graph "a" :weight-key :cost :default-weight 10)
               '(("b" . 7) ("c" . 17))))))
