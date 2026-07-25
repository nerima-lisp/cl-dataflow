(in-package #:cl-dataflow.test)

(deftest graph-max-flow-computes-edmonds-karp
  ;; The classic CLRS max-flow network: the maximum s->t flow is 23. Capacities
  ;; live under :weight here, exercising the supplied capacity-key argument and
  ;; the anti-parallel v1<->v2 edges (distinct directed capacities).
  (let ((graph (%weighted-graph
                '("s" "v1" "v2" "v3" "v4" "t")
                '(("s" "v1" 16) ("s" "v2" 13) ("v1" "v2" 10) ("v2" "v1" 4)
                  ("v1" "v3" 12) ("v3" "v2" 9) ("v2" "v4" 14) ("v4" "v3" 7)
                  ("v3" "t" 20) ("v4" "t" 4)))))
    (is (= (graph-max-flow graph "s" "t" :capacity-key :weight) 23))
    ;; A node can send no flow to itself.
    (is (= (graph-max-flow graph "s" "s" :capacity-key :weight) 0)))
  ;; Diamond s->{a,b}->c->t with unit side edges and a width-2 sink edge: the
  ;; first augmentation saturates one side, so a later search must skip the now
  ;; zero-residual edge to an as-yet-unvisited node. Maximum flow is 2.
  (let ((graph (%weighted-graph '("s" "a" "b" "c" "t")
                                '(("s" "a" 1) ("s" "b" 1)
                                  ("a" "c" 1) ("b" "c" 1) ("c" "t" 2)))))
    (is (= (graph-max-flow graph "s" "t" :capacity-key :weight) 2)))
  ;; An unreachable sink yields zero flow.
  (let ((graph (%weighted-graph '("s" "a" "t") '(("s" "a" 5)))))
    (is (= (graph-max-flow graph "s" "t" :capacity-key :weight) 0))))

(deftest graph-max-flow-capacity-defaults-and-parallel-edges
  ;; With no :capacity metadata every edge falls back to the default capacity;
  ;; left at its own default of 1, the s->a->t path carries a single unit.
  (let ((graph (make-graph)))
    (dolist (name '("s" "a" "t"))
      (add-node graph (make-node name)))
    (add-edge graph "s" "a")
    (add-edge graph "a" "t")
    (is (= (graph-max-flow graph "s" "t") 1))
    ;; A supplied default lifts every capacity uniformly.
    (is (= (graph-max-flow graph "s" "t" :default-capacity 5) 5)))
  ;; Parallel edges' capacities add: two s->a edges of capacity 3 push 6 units
  ;; into a, matched by a width-6 a->t edge. Distinct ports keep the two s->a
  ;; edges from collapsing under add-edge's port-level de-duplication.
  (let ((graph (make-graph)))
    (add-node graph (make-node "s" :outputs '("p1" "p2")))
    (add-node graph (make-node "a" :inputs '("q1" "q2")))
    (add-node graph (make-node "t"))
    (setf (edge-metadata (add-edge graph "s" "a" :from-port "p1" :to-port "q1"))
          '(:capacity 3))
    (setf (edge-metadata (add-edge graph "s" "a" :from-port "p2" :to-port "q2"))
          '(:capacity 3))
    (setf (edge-metadata (add-edge graph "a" "t")) '(:capacity 6))
    (is (= (graph-max-flow graph "s" "t") 6))))

(deftest graph-flow-rejects-invalid-capacities
  (let ((graph (make-graph)))
    (dolist (name '("s" "t"))
      (add-node graph (make-node name)))
    (setf (edge-metadata (add-edge graph "s" "t")) '(:capacity -1))
    (signals invalid-input-error
      (graph-max-flow graph "s" "t"))
    (signals invalid-input-error
      (graph-min-cut graph "s" "t")))
  (let ((graph (make-graph)))
    (dolist (name '("s" "t"))
      (add-node graph (make-node name)))
    (setf (edge-metadata (add-edge graph "s" "t")) '(:capacity :many))
    (signals invalid-input-error
      (graph-max-flow graph "s" "t")))
  (with-graph-fixture (graph ((s "s") (target "t")) :edges ((s target)))
    (signals invalid-input-error
      (graph-max-flow graph "s" "t" :default-capacity -1))))

(deftest graph-min-cut-finds-the-bottleneck-edges
  ;; s->a->b->t with a unit middle edge: the max-flow min-cut theorem places
  ;; a and s on the source side (s->a still has slack) but leaves b and t on the
  ;; sink side, so the single cut edge is a->b, matching the max flow of 1. This
  ;; graph exercises every cut-scan case: an interior edge (s->a), the crossing
  ;; edge (a->b), and a sink-side edge (b->t).
  (let ((graph (%weighted-graph '("s" "a" "b" "t")
                                '(("s" "a" 5) ("a" "b" 1) ("b" "t" 5)))))
    (is (equal (graph-min-cut graph "s" "t" :capacity-key :weight) '(("a" "b"))))
    (is (= (graph-max-flow graph "s" "t" :capacity-key :weight) 1))
    ;; A node has no cut to itself.
    (is (null (graph-min-cut graph "s" "s" :capacity-key :weight))))
  ;; An unreachable sink leaves nothing crossing to the sink side.
  (let ((graph (%weighted-graph '("s" "a" "t") '(("s" "a" 5)))))
    (is (null (graph-min-cut graph "s" "t" :capacity-key :weight))))
  ;; The default :capacity key with a supplied default: s->a saturates at
  ;; capacity 1 while the capacity-less a->t rides the default of 5, so the cut
  ;; is the saturated s->a edge.
  (let ((graph (make-graph)))
    (dolist (name '("s" "a" "t"))
      (add-node graph (make-node name)))
    (setf (edge-metadata (add-edge graph "s" "a")) '(:capacity 1))
    (add-edge graph "a" "t")
    (is (equal (graph-min-cut graph "s" "t" :default-capacity 5) '(("s" "a")))))
  ;; On the CLRS network the cut capacity must equal the max flow of 23.
  (let ((graph (%weighted-graph
                '("s" "v1" "v2" "v3" "v4" "t")
                '(("s" "v1" 16) ("s" "v2" 13) ("v1" "v2" 10) ("v2" "v1" 4)
                  ("v1" "v3" 12) ("v3" "v2" 9) ("v2" "v4" 14) ("v4" "v3" 7)
                  ("v3" "t" 20) ("v4" "t" 4)))))
    (is (= (loop for (from to) in (graph-min-cut graph "s" "t" :capacity-key :weight)
                 sum (loop for edge in (graph-edges graph)
                           when (and (equal (edge-from edge) from)
                                     (equal (edge-to edge) to))
                           sum (getf (edge-metadata edge) :weight)))
           23))))
