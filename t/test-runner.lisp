(in-package #:cl-dataflow.test)

(defmacro deftest (name &body body)
  `(cl-weave:it ,(string-downcase (substitute #\Space #\- (symbol-name name)))
      (progn ,@body)))

(defun run-tests (&key (start 0) end)
  (let* ((plan (cl-weave:collect-test-plan (cl-weave:root-suite)))
          (count (length plan))
          (effective-end (or end count)))
    (unless (and (<= 0 start effective-end count))
      (error "Invalid test range [~D, ~D) for ~D tests."
              start effective-end count))
    (let ((paths (mapcar #'cl-weave:test-plan-entry-path
                          (subseq plan start effective-end))))
      (unless (cl-weave:run-all :reporter :spec
                                :test-path-filter paths)
        (error "cl-dataflow test suite failed."))
      t)))
