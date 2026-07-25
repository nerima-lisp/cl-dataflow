(in-package #:cl-dataflow.test)

(deftest remove-node-drops-node-and-incident-edges
  ;; b has an incoming edge (a->b), an outgoing edge (b->c), and a->d is unrelated.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (a d)))
    (remove-node graph "b")
    (is (null (find-node graph "b")))
    (is (equal (graph-node-names graph) '("a" "c" "d")))
    (is (= (graph-size graph) 1))
    (is (graph-reachable-p graph "a" "d"))))

(deftest remove-node-rejects-unknown-nodes
  (with-graph-fixture (graph ((a "a")))
    (signals node-not-found-error (remove-node graph "missing"))))

(deftest remove-edge-removes-matching-edge-and-reports
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (is (remove-edge graph "a" "b"))
    (is (= (graph-size graph) 1))
    (is (not (graph-reachable-p graph "a" "c")))
    ;; Removing again finds nothing.
    (is (not (remove-edge graph "a" "b")))
    ;; A wrong port does not match.
    (is (not (remove-edge graph "b" "c" :from-port "nope")))
    (is (remove-edge graph "b" "c" :from-port "value" :to-port "value"))
    (is (= (graph-size graph) 0))))

(deftest graph-subgraph-induces-on-a-node-set
  ;; d->a's source is excluded; b->c's target is excluded; a->b survives.
  (with-graph-fixture (graph
                       ((a "a" :metadata '((:kind :src))) (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (d a)))
    (let ((sub (graph-subgraph graph '("a" "b" "unknown"))))
      (is (equal (graph-node-names sub) '("a" "b")))
      (is (= (graph-size sub) 1))
      (is (graph-reachable-p sub "a" "b"))
      (is (equal (node-metadata (find-node sub "a")) '((:kind :src))))
      ;; The original graph is untouched.
      (is (= (graph-order graph) 4))
      (is (= (graph-size graph) 3)))))

(defun %two-node-graph (name-1 name-2 &key metadata)
  (let ((graph (make-graph :metadata metadata)))
    (add-node graph (make-node name-1))
    (add-node graph (make-node name-2))
    (add-edge graph name-1 name-2)
    graph))

(deftest graph-merge-unions-disjoint-graphs
  (let* ((left (%two-node-graph "a" "b" :metadata '((:name :left))))
         (right (%two-node-graph "c" "d"))
         (merged (graph-merge left right)))
    (is (equal (graph-node-names merged) '("a" "b" "c" "d")))
    (is (= (graph-size merged) 2))
    (is (graph-reachable-p merged "a" "b"))
    (is (graph-reachable-p merged "c" "d"))
    ;; Default metadata comes from the first graph.
    (is (equal (graph-metadata merged) '((:name :left))))
    ;; Inputs are not modified.
    (is (= (graph-order left) 2))))

(deftest graph-merge-overrides-metadata-and-rejects-collisions
  (let ((left (%two-node-graph "a" "b"))
        (right (%two-node-graph "c" "d"))
        (clash (%two-node-graph "a" "z")))
    (is (equal (graph-metadata (graph-merge left right :metadata '((:merged t))))
               '((:merged t))))
    (signals graph-error (graph-merge left clash))))

(deftest graph-relabel-node-renames-and-updates-edges
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c"))
                       :edges ((a b) (b c)))
    (let ((relabeled (graph-relabel-node graph "b" "x")))
      (is (equal (graph-node-names relabeled) '("a" "c" "x")))
      (is (graph-reachable-p relabeled "a" "x"))
      (is (graph-reachable-p relabeled "x" "c"))
      ;; The original graph still has b.
      (is (find-node graph "b")))
    (signals node-not-found-error (graph-relabel-node graph "missing" "z"))
    (signals graph-error (graph-relabel-node graph "a" "b"))))

(deftest graph-contract-edge-merges-nodes
  ;; Merge b into a: a->b becomes a self-loop (dropped); b->c becomes a->c which
  ;; dedups with the existing a->c; d->b becomes d->a.
  (with-graph-fixture (graph
                       ((a "a") (b "b") (c "c") (d "d"))
                       :edges ((a b) (b c) (d b) (a c)))
    (let ((contracted (graph-contract-edge graph "a" "b")))
      (is (equal (graph-node-names contracted) '("a" "c" "d")))
      (is (= (graph-size contracted) 2))
      (is (graph-reachable-p contracted "d" "a"))
      (is (graph-reachable-p contracted "a" "c"))
      ;; The original is unchanged.
      (is (= (graph-order graph) 4)))
    (signals invalid-input-error (graph-contract-edge graph "a" "a"))))
