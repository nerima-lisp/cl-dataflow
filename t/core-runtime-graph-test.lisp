(in-package #:cl-dataflow.test)

(deftest graph-nodes-reject-malformed-graphs-at-runtime
  (let* ((graph (make-graph))
         (node (make-node "source")))
    (setf (slot-value node 'cl-dataflow::inputs) '("in" "in")
          (slot-value graph 'cl-dataflow::nodes)
          (make-test-table "source" node))
    (signals graph-error
      (graph-nodes graph))))

(deftest graph-edges-reject-orphan-edges-at-runtime
  (let* ((graph (make-graph))
         (edge (make-edge "source" "sink")))
    (setf (slot-value graph 'cl-dataflow::edges) (list edge))
    (signals node-not-found-error
      (graph-edges graph))))

(deftest copy-graph-produces-independent-graph
  (let* ((graph (make-graph))
         (node (make-node "source"
                          :inputs '("in")
                          :outputs '("out")
                          :metadata '((:kind :stage))))
         (sink (make-node "sink"
                          :inputs '("in")
                          :metadata '((:kind :stage))))
         (edge (make-edge "source" "sink"
                          :from-port "out"
                          :to-port "in"
                          :metadata '((:kind :edge)))))
    (add-node graph node)
    (add-node graph sink)
    (setf (graph-edges graph) (list edge))
    (let* ((copy (copy-graph graph))
           (copied-node (gethash "source" (graph-nodes copy)))
           (copied-edge (first (graph-edges copy))))
      (is (not (eq copy graph)))
      (is (not (eq copied-node (find-node graph "source"))))
      (is (not (eq copied-edge (first (graph-edges graph)))))
      (setf (node-inputs copied-node) '("changed")
            (node-metadata copied-node) '((:kind :mutated))
            (edge-metadata copied-edge) '((:kind :mutated)))
      (add-node copy (make-node "mutated"))
      (is (equal (node-inputs (find-node graph "source")) '("in")))
      (is (equal (node-metadata (find-node graph "source")) '((:kind :stage))))
      (is (equal (edge-metadata (first (graph-edges graph))) '((:kind :edge))))
      (is (= (hash-table-count (graph-nodes graph)) 2))
      (is (= (hash-table-count (graph-nodes copy)) 3))
      (is (= (length (graph-edges graph)) 1))
      (is (= (length (graph-edges copy)) 1)))))
