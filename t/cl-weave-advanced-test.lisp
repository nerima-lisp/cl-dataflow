(in-package #:cl-dataflow-kit.test)

(defun %cyclic-reference-step (state event)
  (if (string= event "fwd")
      (cond ((string= state "a") "b")
            ((string= state "b") "c")
            (t "a"))
      (cond ((string= state "a") "c")
            ((string= state "c") "b")
            (t "a"))))

(defun %build-cyclic-machine ()
  (make-state-machine
   :state "a"
   :transitions (list (make-transition "a" "fwd" "b")
                      (make-transition "b" "fwd" "c")
                      (make-transition "c" "fwd" "a")
                      (make-transition "a" "back" "c")
                      (make-transition "b" "back" "a")
                      (make-transition "c" "back" "b"))))

(defun %expected-prefix-states (events)
  (let ((state "a")
        (states '()))
    (dolist (event events (nreverse states))
      (setf state (%cyclic-reference-step state event))
      (push state states))))

(it-property "generated chain graphs preserve their topological invariant"
    ((weights (gen-list (gen-integer :min -1000 :max 1000)
                        :min-length 1
                        :max-length 30)))
  (let ((graph (make-graph))
        (nodes '()))
    (loop for weight in weights
          for index from 0
          for node = (make-node (format nil "node-~D-~D" index weight))
          do (add-node graph node)
              (push node nodes))
    (setf nodes (nreverse nodes))
    (loop for (source sink) on nodes
          while sink
          do (add-edge graph source sink))
    (cl-weave:expect graph :to-have-valid-topological-order)))
(it-property "CPS state-machine batches preserve state, records, and context traces"
    ((trace (gen-state-machine "a"
                               #'%cyclic-reference-step
                               (gen-member (list "fwd" "back"))
                               :min-length 0
                               :max-length 40)))
  (let* ((events (getf trace :events))
         (expected-final (getf trace :final))
         (machine (%build-cyclic-machine))
         (context (make-context :state "a")))
    (multiple-value-bind (updated-machine records returned-context)
        (run-state-machine-with-context machine events :context context)
      (is (eq returned-context context))
      (is (equal (state-machine-state updated-machine) expected-final))
      (is (equal (mapcar (lambda (record) (getf record :event-type)) records)
                 events))
      (is (equal (mapcar (lambda (record) (getf record :event-type))
                         (context-trace context))
                 (reverse events)))
      (loop for prefix-length from 0 to (length events)
            for prefix-events = (subseq events 0 prefix-length)
            for expected-prefix-state = (if (zerop prefix-length)
                                            "a"
                                            (nth (1- prefix-length)
                                                 (%expected-prefix-states events)))
            do (let ((prefix-machine (%build-cyclic-machine))
                     (prefix-context (make-context :state "a")))
                 (multiple-value-bind (prefix-updated-machine prefix-records returned-prefix-context)
                     (run-state-machine-with-context prefix-machine
                                                    prefix-events
                                                    :context prefix-context)
                   (is (eq returned-prefix-context prefix-context))
                   (is (equal (state-machine-state prefix-updated-machine)
                              expected-prefix-state))
                   (is (equal (mapcar (lambda (record) (getf record :event-type))
                                      prefix-records)
                              prefix-events))
                   (is (equal (mapcar (lambda (record) (getf record :event-type))
                                      (state-machine-history prefix-updated-machine))
                              (reverse prefix-events)))
                   (is (equal (mapcar (lambda (record) (getf record :event-type))
                                      (context-trace prefix-context))
                              (reverse prefix-events)))))))))
