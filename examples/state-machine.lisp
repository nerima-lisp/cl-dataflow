;;; Run with:
;;;   sbcl --script examples/state-machine.lisp
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
          (cl-dataflow-kit:make-transition
            "idle"
            "start"
            "running"
            :action
            (lambda (machine event context)
              (declare (ignore machine event context))
              (values "running" '(:note "entered running"))))
          (cl-dataflow-kit:make-transition "running" "complete" "completed"))))
       (context
      (cl-dataflow-kit:make-context :state (cl-dataflow-kit:state-machine-state machine))))
  ;; RUN-STATE-MACHINE-WITH-CONTEXT mutates MACHINE in place and also returns
  ;; it as UPDATED-MACHINE, so the STATE-MACHINE-LAST-TRANSITION call below
  ;; against the original MACHINE binding already reflects the run.
  (multiple-value-bind (updated-machine transition-records updated-context) (cl-dataflow-kit:run-state-machine-with-context
      machine
      '("start" "complete")
      :context
      context)
    (declare (ignore updated-machine))
    (format t "~&Final state: ~A~%" (cl-dataflow-kit:context-state updated-context))
    (format t "~&Transition count: ~D~%" (length transition-records))
    (format
      t
      "~&Last transition: ~S~%"
      (cl-dataflow-kit:state-machine-last-transition machine))))
