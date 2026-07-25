(in-package #:cl-dataflow.test)

(defun %identity-node (name)
  (make-node name :handler (lambda (input context)
                             (declare (ignore context))
                             input)))

(deftest contract-handler-passes-valid-values-through
  ;; No predicates: everything passes.
  (let ((wrapped (contract-handler (lambda (i c) (declare (ignore c)) (* i 2)))))
    (is (= (funcall wrapped 3 nil) 6)))
  ;; Both predicates satisfied.
  (let ((wrapped (contract-handler (lambda (i c) (declare (ignore c)) (* i 2))
                                   :before #'integerp
                                   :after #'evenp)))
    (is (= (funcall wrapped 4 nil) 8))))

(deftest contract-handler-signals-on-input-violation
  (let ((wrapped (contract-handler (lambda (i c) (declare (ignore c)) i)
                                   :before #'integerp)))
    (with-captured-condition (captured invalid-input-error)
        (funcall wrapped "not-an-int" nil)
      (is (equal (invalid-input-value captured) "not-an-int"))
      (is (search "input" (invalid-input-detail captured))))))

(deftest contract-handler-signals-on-output-violation
  (let ((wrapped (contract-handler (lambda (i c) (declare (ignore c)) (1+ i))
                                   :after #'evenp)))
    ;; 2 -> 3 is odd, violating the output contract.
    (with-captured-condition (captured invalid-input-error)
        (funcall wrapped 2 nil)
      (is (= (invalid-input-value captured) 3))
      (is (search "output" (invalid-input-detail captured))))))

(deftest node-with-contract-enforces-in-a-pipeline
  (let* ((base (%identity-node "checked"))
         (pipeline (single-node-pipeline (node-with-contract base :before #'plusp))))
    (is (= (run-pipeline pipeline :input 7) 7))
    (signals invalid-input-error (run-pipeline pipeline :input -1))))
