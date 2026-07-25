(in-package #:cl-dataflow.test)

(defun %double-pipeline ()
  (let ((graph (make-graph)))
    (add-node graph
              (make-node "double"
                         :handler (mapping-handler (lambda (x) (* x 2)))))
    (make-pipeline :graph graph :metadata '((:kind :doubler)))))

(deftest pipeline-to-plist-and-back-preserves-structure
  (with-graph-fixture (graph
                       ((a "a" :outputs '("out")) (b "b" :inputs '("in")))
                       :edges ((a b :from-port "out" :to-port "in")))
    (let* ((pipeline (make-pipeline :graph graph :metadata '((:kind :flow))))
           (plist (pipeline-to-plist pipeline))
           (rebuilt (plist-to-pipeline plist)))
      (is (equal (getf plist :stages) '("a" "b")))
      (is (equal (pipeline-metadata rebuilt) '((:kind :flow))))
      (is (equal (mapcar #'node-name (pipeline-stages rebuilt)) '("a" "b")))
      ;; The rebuilt pipeline serialises back identically.
      (is (equal (pipeline-to-plist rebuilt) plist)))))

(deftest pipeline-validate-and-stage-count
  (let ((pipeline (%double-pipeline)))
    (is (pipeline-validate pipeline))
    (is (= (pipeline-stage-count pipeline) 1))))

(deftest map-pipeline-runs-over-each-input
  (let ((pipeline (%double-pipeline)))
    (is (equal (map-pipeline pipeline '(1 2 3)) '(2 4 6)))
    ;; A shared context accumulates across runs.
    (let ((context (make-context)))
      (map-pipeline pipeline '(5 6) :context context)
      (is (context-p context)))))

(deftest pipeline->node-embeds-a-pipeline-as-a-stage
  (let* ((inner (%double-pipeline))
         (outer-graph (make-graph)))
    (add-node outer-graph (pipeline->node inner "inner"))
    (add-node outer-graph
              (make-node "increment"
                         :handler (mapping-handler (lambda (x) (+ x 1)))))
    (add-edge outer-graph "inner" "increment")
    (let ((outer (make-pipeline :graph outer-graph)))
      ;; (4 * 2) + 1
      (is (= (run-pipeline outer :input 4) 9)))))
