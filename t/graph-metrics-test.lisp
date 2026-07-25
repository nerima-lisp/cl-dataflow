(in-package #:cl-dataflow.test)

(deftest graph-density-is-edges-over-possible
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (a c)))
    ;; 3 edges out of a possible 3*2 = 6.
    (is (= (graph-density graph) 1/2)))
  ;; Fewer than two nodes has zero density.
  (with-graph-fixture (graph ((solo "solo")))
    (is (= (graph-density graph) 0)))
  (is (= (graph-density (make-graph)) 0)))

(deftest graph-degree-histogram-counts-total-degree
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    ;; a: out1 in0 = 1; b: out1 in1 = 2; c: out0 in1 = 1.
    (is (equal (graph-degree-histogram graph) '((1 . 2) (2 . 1))))))

(deftest graph-bipartite-p-detects-two-colourability
  ;; A path is bipartite; two disjoint components are still handled.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (x "x") (y "y"))
                       :edges ((a b) (b c) (x y)))
    (is (graph-bipartite-p graph)))
  ;; An odd cycle is not bipartite.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (c a)))
    (is (not (graph-bipartite-p graph))))
  ;; A self-loop is not bipartite.
  (with-graph-fixture (graph ((x "x")) :edges ((x x)))
    (is (not (graph-bipartite-p graph)))))

(deftest graph-equal-p-compares-structure-order-independently
  (let ((left (make-graph))
        (right (make-graph)))
    ;; Build the same graph in different insertion orders.
    (dolist (name '("a" "b")) (add-node left (make-node name)))
    (add-edge left "a" "b")
    (dolist (name '("b" "a")) (add-node right (make-node name)))
    (add-edge right "a" "b")
    (is (graph-equal-p left right))
    ;; A structural difference is detected.
    (add-node right (make-node "c"))
    (is (not (graph-equal-p left right)))))

(deftest graph-undirected-reachable-p-follows-weak-connectivity
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b)))
    ;; a and b are weakly connected even though the edge is directed a -> b.
    (is (graph-undirected-reachable-p graph "b" "a"))
    (is (graph-undirected-reachable-p graph "a" "a"))
    ;; c is isolated.
    (is (not (graph-undirected-reachable-p graph "a" "c")))
    (signals node-not-found-error (graph-undirected-reachable-p graph "a" "missing"))))

(deftest graph-greedy-coloring-produces-a-valid-colouring
  ;; A path 2-colours: a=0, b=1, c=0.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c)))
    (is (equal (graph-greedy-coloring graph) '(("a" . 0) ("b" . 1) ("c" . 0)))))
  ;; A triangle needs three colours.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c) (c a)))
    (is (equal (graph-greedy-coloring graph) '(("a" . 0) ("b" . 1) ("c" . 2)))))
  ;; An isolated node takes colour 0.
  (with-graph-fixture (graph ((solo "solo")))
    (is (equal (graph-greedy-coloring graph) '(("solo" . 0))))))

(deftest graph-clustering-coefficient-measures-neighbourhood-density
  ;; In a triangle every node's two neighbours are adjacent, so each local
  ;; coefficient -- and the average -- is 1.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c) (c a)))
    (is (= (graph-clustering-coefficient graph "a") 1))
    (is (= (graph-average-clustering graph) 1)))
  ;; In the path a -> b -> c, b's neighbours a and c are not adjacent (coefficient
  ;; 0), and the endpoints have a single neighbour (the fewer-than-two case).
  (with-graph-fixture (graph ((a "a") (b "b") (c "c")) :edges ((a b) (b c)))
    (is (= (graph-clustering-coefficient graph "b") 0))
    (is (= (graph-clustering-coefficient graph "a") 0))
    (is (= (graph-average-clustering graph) 0)))
  ;; A square with one diagonal: the diagonal's endpoints see a fully-connected
  ;; pair (coefficient 1), the off-diagonal corners only two of three pairs (2/3).
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (c d) (d a) (a c)))
    (is (= (graph-clustering-coefficient graph "b") 1))
    (is (= (graph-clustering-coefficient graph "a") 2/3))
    (is (= (graph-average-clustering graph) 5/6)))
  ;; A self-loop on a triangle node is ignored: its coefficient stays 1.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (c a) (a a)))
    (is (= (graph-clustering-coefficient graph "a") 1)))
  ;; An empty graph has an average clustering of 0.
  (is (= (graph-average-clustering (make-graph)) 0)))

(deftest graph-reciprocity-measures-mutual-edges
  ;; a <-> b are mutual; a -> c has no reverse. Two of the three directed edges are
  ;; reciprocated, and the self-loop a -> a is ignored, so reciprocity is 2/3.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b a) (a c) (a a)))
    (is (= (graph-reciprocity graph) 2/3)))
  ;; A graph whose only edge is a self-loop has no non-loop edges: reciprocity 0.
  (with-graph-fixture (graph ((a "a")) :edges ((a a)))
    (is (= (graph-reciprocity graph) 0))))
