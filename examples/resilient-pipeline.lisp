;;; Resilient node handlers and pipeline sequencing.
;;;
;;; Run with:
;;;   sbcl --script examples/resilient-pipeline.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

;; A flaky handler that fails on its first two invocations, then succeeds.
(defparameter *attempts* 0)
(defparameter *flaky*
  (cl-dataflow-kit:make-node "fetch"
    :handler (lambda (input context)
               (declare (ignore context))
               (incf *attempts*)
               (if (< *attempts* 3)
                   (error "transient failure")
                   (* input 10)))))

;; node-with-retry keeps calling the handler until it succeeds.
(defparameter *retry-graph* (cl-dataflow-kit:make-graph))
(cl-dataflow-kit:add-node *retry-graph*
                      (cl-dataflow-kit:node-with-retry *flaky* :attempts 5))
(format t "~&Retry result: ~D (after ~D attempts)~%"
        (cl-dataflow-kit:run-pipeline (cl-dataflow-kit:make-pipeline :graph *retry-graph*)
                                  :input 7)
        *attempts*)

;; node-with-fallback turns an error into a safe default value.
(defparameter *risky*
  (cl-dataflow-kit:make-node "risky"
    :handler (lambda (input context)
               (declare (ignore context))
               (if (evenp input) (* input 100) (error "odd input")))))
(defparameter *fallback-graph* (cl-dataflow-kit:make-graph))
(cl-dataflow-kit:add-node *fallback-graph*
                      (cl-dataflow-kit:node-with-fallback *risky* -1))
(let ((pipeline (cl-dataflow-kit:make-pipeline :graph *fallback-graph*)))
  (format t "~&Fallback on even 4: ~D~%" (cl-dataflow-kit:run-pipeline pipeline :input 4))
  (format t "~&Fallback on odd 3: ~D~%" (cl-dataflow-kit:run-pipeline pipeline :input 3)))

;; run-pipeline-sequence threads one pipeline's result into the next.
(defun single-node-pipeline (name function)
  (let ((graph (cl-dataflow-kit:make-graph)))
    (cl-dataflow-kit:add-node graph
                          (cl-dataflow-kit:make-node name
                            :handler (cl-dataflow-kit:mapping-handler function)))
    (cl-dataflow-kit:make-pipeline :graph graph)))

(let ((double (single-node-pipeline "double" (lambda (x) (* x 2))))
      (increment (single-node-pipeline "increment" (lambda (x) (+ x 1)))))
  (format t "~&Sequenced (double then increment) of 20: ~D~%"
          (cl-dataflow-kit:run-pipeline-sequence (list double increment) :input 20)))
