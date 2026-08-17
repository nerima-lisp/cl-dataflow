;;; Run with:
;;;   sbcl --script examples/simple-pipeline.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

(let* ((parse
      (cl-dataflow-kit:make-node
        "parse"
        :handler
        (lambda (input context)
          (declare (ignore context))
          (parse-integer input))))
       (validate
      (cl-dataflow-kit:make-node
        "validate"
        :handler
        (lambda (input context)
          (declare (ignore context))
          (unless (plusp input)
            (error "Input must be positive"))
          input)))
       (transform
      (cl-dataflow-kit:make-node
        "transform"
        :handler
        (lambda (input context)
          (declare (ignore context))
          (* input 10))))
       (render
      (cl-dataflow-kit:make-node
        "render"
        :handler
        (lambda (input context)
          (declare (ignore context))
          (format nil "rendered: ~A" input))))
       (pipeline
      (cl-dataflow-kit:make-pipeline :stages (list parse validate transform render))))
  (format
    t
    "~&Simple pipeline result: ~A~%"
    (cl-dataflow-kit:run-pipeline pipeline :input "7")))
