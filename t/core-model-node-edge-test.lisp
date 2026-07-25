(in-package #:cl-dataflow.test)

(deftest make-node-rejects-duplicate-port-names
  (signals invalid-input-error
    (make-node "source" :inputs '(input input)))
  (signals invalid-input-error
    (make-node "source" :outputs '(output output))))

(deftest node-port-setters-reject-duplicate-port-names
  (let ((node (make-node "source")))
    (signals invalid-input-error
      (setf (node-inputs node) '(input input)))
    (signals invalid-input-error
      (setf (node-outputs node) '(output output)))
    (is (equal (node-inputs node) '("value")))
    (is (equal (node-outputs node) '("value")))))
