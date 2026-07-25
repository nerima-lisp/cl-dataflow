(in-package #:cl-dataflow.test)

(deftest graph-eulerian-path-traces-every-edge-once
  ;; A directed triangle is an Eulerian circuit: starting at the name-least node
  ;; with an outgoing edge, the trail returns to its start.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c) (c a)))
    (is (equal (graph-eulerian-path graph) '("a" "b" "c" "a"))))
  ;; The path a -> b -> c has one surplus (a) and one deficit (c), so the trail is
  ;; the open walk a, b, c.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (equal (graph-eulerian-path graph) '("a" "b" "c"))))
  ;; A node with two more out- than in-edges (a) is too unbalanced: no trail.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (a c)))
    (is (null (graph-eulerian-path graph))))
  ;; Two separate surplus/deficit pairs (a,b out; c,d in) also admit no single
  ;; trail even though no node is wildly unbalanced.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a c) (b d)))
    (is (null (graph-eulerian-path graph))))
  ;; Two disjoint 2-cycles are each balanced, but their edges are disconnected, so
  ;; Hierholzer from one cannot reach the other -- no Eulerian trail.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b a) (c d) (d c)))
    (is (null (graph-eulerian-path graph)))))
