(in-package #:cl-dataflow.test)

(deftest branching-pipeline-collects-sink-results
  (with-branching-test-pipeline (graph pipeline source left right)
    (let ((context (run-pipeline-with-test-context pipeline :input 5)))
      (assert-pipeline-result context
                              '(("left" ("value" . 16))
                                ("right" ("value" . 30)))))))

(deftest branching-pipeline-exposes-node-values-and-boundary-nodes
  (with-branching-test-pipeline (graph pipeline source left right)
    (with-workflow-context (context pipeline :input 5)
      (is (equal (mapcar #'node-name (graph-source-nodes (pipeline-graph pipeline)))
                 '("source")))
      (is (equal (sort (mapcar #'node-name (graph-sink-nodes (pipeline-graph pipeline)))
                       #'string<)
                 '("left" "right")))
      (is (equal (context-value context "source" "left") 6))
      (is (equal (context-value context "source" "right") 10))
      (is (equal (context-node-values context source)
                 '(("left" . 6) ("right" . 10))))
      (is (equal (context-value context "left") 16))
      (is (equal (context-value context "right") 30)))))
