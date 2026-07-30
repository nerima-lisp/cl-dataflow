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

(deftest map-pipeline-parallel-matches-sequential-result
  (let ((pipeline (%double-pipeline)))
    (is (equal (map-pipeline pipeline '(1 2 3) :parallel t) '(2 4 6)))))

(deftest map-pipeline-parallel-runs-independent-runs-concurrently
  (let* ((lock (cl-concurrent-kit:make-lock :name "test"))
         (start-times '())
         (sleep-seconds 0.2)
         (graph (make-graph))
         (pipeline
           (progn
             (add-node graph
                       (make-node "slow"
                                  :handler (lambda (input context)
                                             (declare (ignore context))
                                             (cl-concurrent-kit:with-lock-held (lock)
                                               (push (get-internal-real-time) start-times))
                                             (sleep sleep-seconds)
                                             input)))
             (make-pipeline :graph graph))))
    (map-pipeline pipeline '(1 2) :parallel t)
    (is (= (length start-times) 2))
    (let ((gap-seconds
            (/ (abs (- (first start-times) (second start-times)))
               internal-time-units-per-second)))
      (is (< gap-seconds sleep-seconds)))))

(deftest map-pipeline-rejects-parallel-with-a-shared-context
  (let ((pipeline (%double-pipeline)))
    (signals invalid-input-error
      (map-pipeline pipeline '(1 2) :context (make-context) :parallel t))))

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
