;;; Run with:
;;;   sbcl --script examples/event-workflow.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

(let* ((machine
      (cl-dataflow-kit:make-state-machine
        :state
        "idle"
        :transitions
        (list
          (cl-dataflow-kit:make-transition "idle" "order-created" "order-created")
          (cl-dataflow-kit:make-transition
            "order-created"
            "reserve-inventory"
            "inventory-reserved")
          (cl-dataflow-kit:make-transition
            "inventory-reserved"
            "payment-requested"
            "payment-requested")
          (cl-dataflow-kit:make-transition
            "payment-requested"
            "order-confirmed"
            "order-confirmed"))))
       (stage
      (lambda (name event)
        (cl-dataflow-kit:make-node
          name
          :handler
          (lambda (input context)
            (cl-dataflow-kit:emit-event context event :payload input)
            (cl-dataflow-kit:step-state-machine machine event :context context)
            input))))
       (pipeline
      (cl-dataflow-kit:make-pipeline
        :stages
        (list
          (funcall stage "create-order" "order-created")
          (funcall stage "reserve-inventory" "reserve-inventory")
          (funcall stage "request-payment" "payment-requested")
          (funcall stage "confirm-order" "order-confirmed"))))
       (context
      (cl-dataflow-kit:run-pipeline-with-test-context
        pipeline
        :input
        '(:order-id "A-100")
        :state
        (cl-dataflow-kit:state-machine-state machine))))
  (format t "~&Workflow state: ~A~%" (cl-dataflow-kit:context-state context))
  (format
    t
    "~&Workflow events: ~S~%"
    (mapcar
      #'cl-dataflow-kit:event-type
      (nreverse (cl-dataflow-kit:context-events context)))))
