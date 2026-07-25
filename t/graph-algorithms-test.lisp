(in-package #:cl-dataflow.test)

(defun %node-name-list (nodes)
  (mapcar #'node-name nodes))

(defun %generation-names (generations)
  (mapcar #'%node-name-list generations))

(deftest graph-order-size-and-emptiness
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (= (graph-order graph) 3))
    (is (= (graph-size graph) 2))
    (is (not (graph-empty-p graph))))
  (is (graph-empty-p (make-graph)))
  (is (= (graph-order (make-graph)) 0))
  (is (= (graph-size (make-graph)) 0)))

(deftest graph-node-names-are-sorted
  (with-graph-fixture (graph
                       ((c "c") (a "a") (b "b")))
    (is (equal (graph-node-names graph) '("a" "b" "c")))))

(deftest graph-neighbors-and-degrees
  (with-graph-fixture (graph
                       ((s "s") (a "a") (b "b") (z "t"))
                       :edges ((s a) (s b) (a z) (b z)))
    (is (equal (%node-name-list (graph-successors graph "s")) '("a" "b")))
    (is (equal (%node-name-list (graph-predecessors graph "t")) '("a" "b")))
    (is (= (graph-out-degree graph "s") 2))
    (is (= (graph-in-degree graph "t") 2))
    (is (= (graph-out-degree graph "t") 0))
    (is (= (graph-in-degree graph "s") 0))
    (is (null (graph-successors graph "t")))))

(deftest graph-neighbors-deduplicate-parallel-edges
  (with-graph-fixture (graph
                       ((s "s" :outputs '("left" "right"))
                        (a "a" :inputs '("left" "right")))
                       :edges ((s a :from-port "left" :to-port "left")
                               (s a :from-port "right" :to-port "right")))
    (is (equal (%node-name-list (graph-successors graph "s")) '("a")))
    (is (equal (%node-name-list (graph-predecessors graph "a")) '("s")))
    (is (= (graph-out-degree graph "s") 1))
    (is (= (graph-in-degree graph "a") 1))))

(deftest graph-neighbors-reject-unknown-nodes
  (with-graph-fixture (graph ((a "a")))
    (signals node-not-found-error (graph-successors graph "missing"))
    (signals node-not-found-error (graph-predecessors graph "missing"))))

(deftest graph-transpose-reverses-reachability
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (let ((transposed (graph-transpose graph)))
      (is (equal (graph-node-names transposed) '("a" "b" "c")))
      (is (= (graph-size transposed) 2))
      ;; a ->..-> c in the original becomes c ->..-> a in the transpose.
      (is (graph-reachable-p transposed "c" "a"))
      (is (not (graph-reachable-p transposed "a" "c")))
      (is (equal (%node-name-list (graph-successors transposed "c")) '("b")))
      ;; The original is untouched.
      (is (graph-reachable-p graph "a" "c")))))

(deftest graph-acyclic-p-detects-cycles
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (graph-acyclic-p graph)))
  (with-graph-fixture (graph
                       ((a "a") (b "b"))
                       :edges ((a b) (b a)))
    (is (not (graph-acyclic-p graph)))))

(deftest strongly-connected-components-of-a-dag-are-singletons
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (equal (graph-strongly-connected-components graph)
               '(("a") ("b") ("c"))))))

(deftest strongly-connected-components-group-cycles
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (c a) (c d)))
    ;; a, b, c form one cycle; d stands alone.
    (is (equal (graph-strongly-connected-components graph)
               '(("a" "b" "c") ("d"))))))

(deftest strongly-connected-components-cover-isolated-nodes
  (with-graph-fixture (graph ((a "a") (b "b")))
    (is (equal (graph-strongly-connected-components graph)
               '(("a") ("b"))))))

(deftest connected-components-follow-undirected-links
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (x "x") (y "y"))
                       :edges ((a b) (c b) (x y)))
    ;; a-b-c are weakly connected even though c only points into b; x-y are separate.
    (is (equal (graph-connected-components graph)
               '(("a" "b" "c") ("x" "y"))))))

(deftest connected-components-cover-isolated-nodes
  (with-graph-fixture (graph ((a "a") (b "b")))
    (is (equal (graph-connected-components graph)
               '(("a") ("b"))))))

(deftest connected-components-handle-bidirectional-edges
  ;; a and b point at each other, so each is both a successor and a predecessor of
  ;; the other -- the undirected neighbour set must deduplicate them.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b a)))
    (is (equal (graph-connected-components graph)
               '(("a" "b") ("c"))))))

(deftest topological-generations-layer-a-dag
  (with-graph-fixture (graph
                       ((s "s") (a "a") (b "b") (z "t"))
                       :edges ((s a) (s b) (a z) (b z)))
    (is (equal (%generation-names (graph-topological-generations graph))
               '(("s") ("a" "b") ("t"))))))

(deftest topological-generations-reject-cycles
  (with-graph-fixture (graph
                       ((a "a") (b "b"))
                       :edges ((a b) (b a)))
    (signals graph-cycle-error
      (graph-topological-generations graph))))

(deftest graph-distance-counts-shortest-hops
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (c d) (a d)))
    (is (= (graph-distance graph "a" "b") 1))
    (is (= (graph-distance graph "a" "c") 2))
    ;; a -> d directly is shorter than a -> b -> c -> d.
    (is (= (graph-distance graph "a" "d") 1))
    (is (null (graph-distance graph "d" "a")))))

(deftest graph-distance-of-a-node-to-itself-needs-a-cycle
  (with-graph-fixture (graph
                       ((a "a") (b "b"))
                       :edges ((a b) (b a)))
    (is (= (graph-distance graph "a" "a") 2)))
  (with-graph-fixture (graph
                       ((a "a") (b "b"))
                       :edges ((a b)))
    (is (null (graph-distance graph "a" "a")))))

(deftest graph-distance-over-a-diamond-converges
  ;; d is reachable from a through both b and c; BFS must reach it via one and
  ;; then skip the already-discovered node on the other path.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    (is (= (graph-distance graph "a" "d") 2))))

(deftest graph-distance-on-an-edgeless-graph-is-nil
  (with-graph-fixture (graph ((a "a") (b "b")))
    (is (null (graph-distance graph "a" "b")))))
