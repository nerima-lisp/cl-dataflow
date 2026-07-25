(in-package #:cl-dataflow.test)

(deftest graph-connected-p-checks-weak-connectivity
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c)))
    (is (graph-connected-p graph)))
  (with-graph-fixture (graph ((a "a") (b "b")))
    (is (not (graph-connected-p graph))))
  (is (graph-connected-p (make-graph))))

(deftest graph-strongly-connected-p-checks-mutual-reachability
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c) (c a)))
    (is (graph-strongly-connected-p graph)))
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b)))
    (is (not (graph-strongly-connected-p graph)))))

(deftest graph-self-loop-nodes-lists-self-loops
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a a) (a b) (c c)))
    (is (equal (graph-self-loop-nodes graph) '("a" "c"))))
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b)))
    (is (null (graph-self-loop-nodes graph)))))

(deftest graph-condensation-collapses-components
  ;; a<->b form a cycle; both a->c and b->c cross into c.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b a) (a c) (b c)))
    (let ((condensed (graph-condensation graph)))
      (is (equal (graph-node-names condensed) '("a" "c")))
      ;; The cross edges a->c and b->c collapse to a single a->c edge.
      (is (= (graph-size condensed) 1))
      (is (graph-acyclic-p condensed))
      (is (equal (getf (node-metadata (find-node condensed "a")) :members)
                 '("a" "b"))))))

(deftest graph-distances-from-gives-single-source-hops
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    ;; d is reached via b and via c; BFS records the shorter (equal) hop of 2.
    (is (equal (graph-distances-from graph "a")
               '(("b" . 1) ("c" . 1) ("d" . 2))))
    ;; A sink reaches nothing.
    (is (null (graph-distances-from graph "d")))))

(deftest graph-eccentricity-and-diameter
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (c d)))
    (is (= (graph-eccentricity graph "a") 3))
    (is (= (graph-eccentricity graph "d") 0))
    (is (= (graph-diameter graph) 3)))
  (is (= (graph-diameter (make-graph)) 0)))

(deftest graph-radius-center-and-periphery
  ;; Path a -> b -> c -> d: eccentricities are 3, 2, 1, 0. The sink d gives the
  ;; radius of 0 and is the sole center; the source a stretches the full diameter
  ;; of 3 and is the sole periphery.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (c d)))
    (is (= (graph-radius graph) 0))
    (is (equal (graph-center graph) '("d")))
    (is (equal (graph-periphery graph) '("a"))))
  ;; Two sources feeding one sink: both sources sit at eccentricity 1 (the
  ;; diameter), so the periphery holds both, ordered lexicographically.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a c) (b c)))
    (is (= (graph-radius graph) 0))
    (is (equal (graph-center graph) '("c")))
    (is (equal (graph-periphery graph) '("a" "b"))))
  ;; An empty graph has radius 0 and no center or periphery.
  (is (= (graph-radius (make-graph)) 0))
  (is (null (graph-center (make-graph))))
  (is (null (graph-periphery (make-graph)))))

(deftest graph-bfs-and-dfs-order-traverse-from-a-source
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    ;; BFS visits level by level; DFS descends the name-least branch first.
    (is (equal (graph-bfs-order graph "a") '("a" "b" "c" "d")))
    (is (equal (graph-dfs-order graph "a") '("a" "b" "d" "c"))))
  ;; c is a successor of both a and b, so DFS pushes it onto the stack twice and
  ;; must skip the already-visited second pop.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (a c) (b c)))
    (is (equal (graph-dfs-order graph "a") '("a" "b" "c"))))
  ;; A sink yields just itself.
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b)))
    (is (equal (graph-bfs-order graph "b") '("b")))
    (is (equal (graph-dfs-order graph "b") '("b")))
    (signals node-not-found-error (graph-bfs-order graph "missing"))
    (signals node-not-found-error (graph-dfs-order graph "missing"))))

(deftest graph-closeness-centrality-measures-reach
  (with-graph-fixture (graph ((a "a") (b "b") (c "c") (d "d")) :edges ((a b) (b c) (c d)))
    ;; From a: distances 1,2,3 to b,c,d; 3 nodes / total 6 = 1/2.
    (is (= (graph-closeness-centrality graph "a") 1/2))
    ;; b reaches c,d at 1,2; 2 / 3.
    (is (= (graph-closeness-centrality graph "b") 2/3))
    ;; A sink reaches nothing.
    (is (= (graph-closeness-centrality graph "d") 0))))

(deftest graph-betweenness-centrality-scores-brokers
  ;; On the path a->b->c, only the a->c shortest path has an intermediate: b.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c)))
    (is (equal (graph-betweenness-centrality graph)
               '(("a" . 0) ("b" . 1) ("c" . 0)))))
  ;; A diamond splits a->d's two shortest paths, so b and c each carry a half.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (a c) (b d) (c d)))
    (is (equal (graph-betweenness-centrality graph)
               '(("a" . 0) ("b" . 1/2) ("c" . 1/2) ("d" . 0)))))
  ;; a->b, a->c, b->c: b->c is not a shortest path (a->c is direct), exercising the
  ;; non-shortest-edge branch. No node is ever a broker.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (a c) (b c)))
    (is (equal (graph-betweenness-centrality graph)
               '(("a" . 0) ("b" . 0) ("c" . 0))))))

(deftest graph-betweenness-centrality-runs-brandes-bfs-once-per-node
  ;; A cl-weave spy verifies the INTERACTION shape of Brandes' algorithm (one
  ;; BFS phase per node) rather than just its output, guarding the phase split
  ;; into %BETWEENNESS-BFS/%BETWEENNESS-ACCUMULATE against an accidental
  ;; double run or a skipped source.
  (let ((spy (spy-on 'cl-dataflow::%betweenness-bfs)))
    (unwind-protect
        (with-graph-fixture (graph
                             ((a "a") (b "b") (c "c") (d "d"))
                             :edges ((a b) (a c) (b d) (c d)))
          (graph-betweenness-centrality graph)
          (expect spy :to-have-been-called-times 4))
      (mock-restore spy))))

(deftest graph-wiener-index-and-average-path-length
  ;; Path a -> b -> c: distances are a->b 1, a->c 2, b->c 1, summing to 4 over 3
  ;; reachable pairs, so the average path length is 4/3.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (= (graph-wiener-index graph) 4))
    (is (= (graph-average-path-length graph) 4/3)))
  ;; A 2-cycle a <-> b: each reaches the other in one hop; the cycle's return to
  ;; the source is not counted as a pair, so the index is 2 and the average 1.
  (with-graph-fixture (graph
                       ((a "a") (b "b"))
                       :edges ((a b) (b a)))
    (is (= (graph-wiener-index graph) 2))
    (is (= (graph-average-path-length graph) 1)))
  ;; With no reachable pairs both are 0 (and the average never divides by zero).
  (is (= (graph-wiener-index (make-graph)) 0))
  (is (= (graph-average-path-length (make-graph)) 0)))
