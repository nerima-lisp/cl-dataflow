(in-package #:cl-dataflow.test)

(defun %simple-graph (node-names edges &key metadata)
  (let ((graph (make-graph :metadata metadata)))
    (dolist (name node-names) (add-node graph (make-node name)))
    (dolist (edge edges) (add-edge graph (first edge) (second edge)))
    graph))

(deftest graph-union-combines-nodes-and-edges
  (let* ((left (%simple-graph '("a" "b") '(("a" "b")) :metadata '((:name :left))))
         (right (%simple-graph '("b" "c") '(("b" "c"))))
         (union (graph-union left right)))
    (is (equal (graph-node-names union) '("a" "b" "c")))
    (is (= (graph-size union) 2))
    (is (graph-reachable-p union "a" "c"))
    ;; Default metadata comes from the first graph.
    (is (equal (graph-metadata union) '((:name :left))))
    ;; Shared a->b edge is not duplicated.
    (let ((again (graph-union left left)))
      (is (= (graph-size again) 1)))))

(deftest graph-intersection-keeps-common-nodes-and-edges
  (let* ((left (%simple-graph '("a" "b" "c") '(("a" "b") ("b" "c"))))
         (right (%simple-graph '("b" "c" "d") '(("b" "c") ("c" "d"))))
         (common (graph-intersection left right)))
    ;; Nodes b and c are shared; only the b->c edge is in both.
    (is (equal (graph-node-names common) '("b" "c")))
    (is (= (graph-size common) 1))
    (is (graph-reachable-p common "b" "c"))))

(deftest graph-difference-subtracts-edges
  (let* ((left (%simple-graph '("a" "b" "c") '(("a" "b") ("b" "c"))))
         (right (%simple-graph '("a" "b") '(("a" "b"))))
         (diff (graph-difference left right)))
    ;; All of left's nodes remain, but the shared a->b edge is removed.
    (is (equal (graph-node-names diff) '("a" "b" "c")))
    (is (= (graph-size diff) 1))
    (is (not (graph-reachable-p diff "a" "b")))
    (is (graph-reachable-p diff "b" "c"))))

(deftest graph-filter-nodes-induces-on-a-predicate
  (with-graph-fixture (graph
                       ((keep-1 "keep-a" :metadata '((:keep t)))
                        (drop "drop-b")
                        (keep-2 "keep-c" :metadata '((:keep t))))
                       :edges ((keep-1 keep-2) (keep-1 drop)))
    (let ((filtered (graph-filter-nodes graph
                                        (lambda (node)
                                          (assoc :keep (node-metadata node))))))
      (is (equal (graph-node-names filtered) '("keep-a" "keep-c")))
      ;; keep-a -> drop-b is dropped; keep-a -> keep-c survives.
      (is (= (graph-size filtered) 1)))))

(deftest graph-map-nodes-relabels-and-rewrites-edges
  (let* ((graph (%simple-graph '("a" "b") '(("a" "b"))))
         (mapped (graph-map-nodes graph (lambda (name)
                                          (concatenate 'string "n-" name)))))
    (is (equal (graph-node-names mapped) '("n-a" "n-b")))
    (is (graph-reachable-p mapped "n-a" "n-b"))
    ;; The original is unchanged.
    (is (equal (graph-node-names graph) '("a" "b")))))

(deftest graph-diff-reports-added-and-removed
  (let ((before (%simple-graph '("a" "b" "c") '(("a" "b") ("b" "c"))))
        (after (%simple-graph '("b" "c" "d") '(("b" "c") ("c" "d")))))
    (let ((diff (graph-diff before after)))
      ;; d is added, a is removed; c->d added, a->b removed; b->c unchanged.
      (is (equal (getf diff :added-nodes) '("d")))
      (is (equal (getf diff :removed-nodes) '("a")))
      (is (equal (getf diff :added-edges) '(("c" "value" "d" "value"))))
      (is (equal (getf diff :removed-edges) '(("a" "value" "b" "value"))))))
  ;; Identical graphs diff to nothing.
  (let ((g (%simple-graph '("a" "b") '(("a" "b")))))
    (let ((diff (graph-diff g g)))
      (is (null (getf diff :added-nodes)))
      (is (null (getf diff :added-edges)))
      (is (null (getf diff :removed-edges))))))
