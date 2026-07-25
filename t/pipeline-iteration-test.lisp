(in-package #:cl-dataflow.test)

(defun %single-node-pipeline (function)
  (let ((graph (make-graph)))
    (add-node graph (make-node "step" :handler (mapping-handler function)))
    (make-pipeline :graph graph)))

(deftest run-pipeline-times-iterates-a-fixed-count
  (let ((double (%single-node-pipeline (lambda (x) (* x 2)))))
    ;; 1 -> 2 -> 4 -> 8
    (is (= (run-pipeline-times double 3 :input 1) 8))
    ;; Zero iterations returns the input unchanged.
    (is (= (run-pipeline-times double 0 :input 42) 42))))

(deftest run-pipeline-until-fixpoint-settles
  (let ((halve (%single-node-pipeline (lambda (x) (floor x 2)))))
    ;; 10 -> 5 -> 2 -> 1 -> 0 -> 0 (fixpoint at 0).
    (multiple-value-bind (result iterations fixpoint-p)
        (run-pipeline-until-fixpoint halve :input 10)
      (is (= result 0))
      (is fixpoint-p)
      (is (> iterations 1))))
  ;; A non-convergent pipeline hits the iteration cap. The explicit :test and
  ;; :max-iterations exercise the supplied-argument paths.
  (let ((increment (%single-node-pipeline #'1+)))
    (multiple-value-bind (result iterations fixpoint-p)
        (run-pipeline-until-fixpoint increment :input 0 :test #'eql :max-iterations 3)
      (is (= result 3))
      (is (= iterations 3))
      (is (not fixpoint-p)))))

(deftest run-pipeline-while-iterates-under-a-predicate
  (let ((double (%single-node-pipeline (lambda (x) (* x 2)))))
    ;; Keep doubling while below 100: 1,2,4,8,16,32,64 -> 128 (stops, 128 >= 100).
    (multiple-value-bind (result iterations)
        (run-pipeline-while double (lambda (x) (< x 100)) :input 1)
      (is (= result 128))
      (is (= iterations 7)))
    ;; A predicate false from the start runs nothing.
    (multiple-value-bind (result iterations)
        (run-pipeline-while double (constantly nil) :input 5)
      (is (= result 5))
      (is (= iterations 0)))
    ;; The iteration cap bounds a would-be-infinite run.
    (multiple-value-bind (result iterations)
        (run-pipeline-while double (constantly t) :input 1 :max-iterations 4)
      (is (= result 16))
      (is (= iterations 4)))))
