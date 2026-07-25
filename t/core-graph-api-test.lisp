(in-package #:cl-dataflow.test)

(deftest graph-print-object-renders-raw-graph-summary
  (let* ((graph (make-graph))
         (source (make-node "source"))
         (sink (make-node "sink")))
    (add-node graph source)
    (add-node graph sink)
    (add-edge graph source sink)
    (is (search "2 nodes 1 edges"
                (with-output-to-string (stream)
                  (prin1 graph stream))))
    (remhash "sink" (slot-value graph 'cl-dataflow::nodes))
    (is (search "1 nodes 1 edges"
                (with-output-to-string (stream)
                  (prin1 graph stream))))))

(deftest protocol-print-object-renders-public-identifiers
  (flet ((render (object)
           (with-output-to-string (stream)
             (print-object object stream))))
    (let* ((node (make-node "source" :outputs '("out")))
           (edge (make-edge "source" "sink" :from-port "out" :to-port "input"))
           (context (make-context :events (list (make-event "boot")
                                                (make-event "tick"))
                                  :effects (list (make-effect "audit")))))
      (is (search "NODE" (render node)))
      (is (search "source" (render node)))
      (is (search "EDGE" (render edge)))
      (is (search "source:out -> sink:input"
                  (render edge)))
      (is (search "CONTEXT" (render context)))
      (is (search "events=2 effects=1"
                   (render context))))))

(deftest protocol-print-object-escapes-control-characters
  (flet ((render (object)
           (with-output-to-string (stream)
             (print-object object stream))))
    (let* ((spoof (format nil "spoof~%tab~Creturn~Cdel~Cend"
                          #\Tab #\Return (code-char 127)))
           (node (make-node (format nil "source-~A" spoof)))
           (edge (make-edge (format nil "source-~A" spoof)
                            (format nil "sink-~A" spoof)
                            :from-port (format nil "out-~A" spoof)
                            :to-port (format nil "input-~A" spoof)))
           (transition (make-transition (format nil "idle-~A" spoof)
                                        (format nil "start-~A" spoof)
                                        (format nil "running-~A" spoof)))
           (machine (make-state-machine :state (format nil "idle-~A" spoof))))
      (dolist (rendered (list (render node)
                              (render edge)
                              (render transition)
                              (render machine)))
        (is (search "\\ntab" rendered))
        (is (search "\\treturn" rendered))
        (is (search "\\rdel" rendered))
        (is (search "\\x7F;end" rendered))
        (is (not (search (format nil "~%tab") rendered)))
        (is (not (search (format nil "~Creturn" #\Tab) rendered)))
        (is (not (search (format nil "~Cdel" #\Return) rendered)))
        (is (not (search (format nil "~Cend" (code-char 127)) rendered)))))))

(deftest constructors-normalize-and-copy-input-data
  (let* ((metadata (list (list :labels "alpha")))
         (node (make-node 'source
                          :inputs '(input)
                          :outputs '(output)
                          :metadata metadata))
         (values (make-test-table "count" (list 1 2)))
         (events (list (make-event "boot" :payload 1)))
         (effects (list (make-effect "audit" :payload 2)))
         (trace (list '(:event "boot")))
         (handlers (make-test-effect-handlers
                    "log" (lambda (effect context)
                            (declare (ignore effect context))
                            :ok)))
         (context (make-context :values values
                                :events events
                                :effects effects
                                :trace trace
                                :effect-handlers handlers
                                :metadata metadata)))
    (setf (cadar metadata) "beta")
    (setf (cadr (gethash "count" values)) 3)
    (setf (car events) (make-event "mutated"))
    (setf (car effects) (make-effect "mutated"))
    (setf (car trace) '(:event "mutated"))
    (setf (gethash "log" handlers) :mutated)
    (is (equal (node-name node) "SOURCE"))
    (is (equal (node-inputs node) '("INPUT")))
    (is (equal (node-outputs node) '("OUTPUT")))
    (is (equal (node-metadata node) '((:labels "alpha"))))
    (is (equal (gethash "count" (context-values context)) '(1 2)))
    (is (equal (event-type (first (context-events context))) "boot"))
    (is (equal (effect-type (first (context-effects context))) "audit"))
    (is (equal (first (context-trace context)) '(:event "boot")))
    (is (functionp (gethash "log" (context-effect-handlers context))))
    (is (equal (context-metadata context) '((:labels "alpha"))))))

(defun %metadata-payload-value (metadata)
  (second (aref (second (first metadata)) 0)))

(defun %assert-nested-metadata-isolated (object reader writer)
  (let ((input-vector (vector (list :value "original"))))
    (funcall writer (list (list :payload input-vector)) object)
    (setf (second (aref input-vector 0)) "input-mutated")
    (is (string= (%metadata-payload-value (funcall reader object)) "original"))
    (let ((snapshot (funcall reader object)))
      (setf (second (aref (second (first snapshot)) 0)) "snapshot-mutated"))
    (is (string= (%metadata-payload-value (funcall reader object)) "original"))))

(deftest metadata-accessors-copy-nested-mutable-values
  (let ((node (make-node "node"))
        (edge (make-edge "node" "sink"))
        (graph (make-graph))
        (context (make-context))
        (event (make-event "event"))
        (effect (make-effect "effect"))
        (transition (make-transition "idle" "go" "running"))
        (machine (make-state-machine :state "idle"))
        (pipeline (make-pipeline)))
    (%assert-nested-metadata-isolated
     node #'node-metadata (lambda (metadata object)
                            (setf (node-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     edge #'edge-metadata (lambda (metadata object)
                            (setf (edge-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     graph #'graph-metadata (lambda (metadata object)
                              (setf (graph-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     context #'context-metadata (lambda (metadata object)
                                  (setf (context-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     event #'event-metadata (lambda (metadata object)
                              (setf (event-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     effect #'effect-metadata (lambda (metadata object)
                                (setf (effect-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     transition #'transition-metadata (lambda (metadata object)
                                        (setf (transition-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     machine #'state-machine-metadata (lambda (metadata object)
                                        (setf (state-machine-metadata object) metadata)))
    (%assert-nested-metadata-isolated
     pipeline #'pipeline-metadata (lambda (metadata object)
                                    (setf (pipeline-metadata object) metadata)))))

(deftest public-predicate-helpers-recognize-core-types
  (let* ((node (make-node "source"))
         (edge (make-edge "source" "sink"))
         (graph (make-graph))
         (context (make-context))
         (event (make-event "boot"))
         (effect (make-effect "audit"))
         (transition (make-transition "idle" "start" "running"))
         (machine (make-state-machine :state "idle"))
         (pipeline (make-pipeline :stages (list node))))
    (is (node-p node))
    (is (edge-p edge))
    (is (graph-p graph))
    (is (context-p context))
    (is (event-p event))
    (is (effect-p effect))
    (is (state-transition-p transition))
    (is (state-machine-p machine))
    (is (pipeline-p pipeline))
    (is (functionp (node-handler node)))))
