(in-package #:cl-dataflow.test)

(deftest make-context-copies-trace-entries
  (let* ((trace (list (list :event "boot"
                            :payload (list :id 1))
                      (list :effect "audit"
                            :result (list :ok t))))
         (context (make-context :trace trace)))
    (set-plist-entry (first trace) :payload (list :mutated 1))
    (set-plist-entry (second trace) :result (list :changed t))
    (is (equal (context-trace context)
               (list (list :event "boot"
                           :payload '(:id 1))
                     (list :effect "audit"
                           :result '(:ok t)))))
    (assert-context-trace-entries context
      (0 (:payload '(:id 1)))
      (1 (:result '(:ok t))))))

(deftest scalar-and-designator-setters-normalize-values
  (let ((node (make-node "source"))
        (edge (make-edge "source" "sink"))
        (transition (make-transition "idle" "start" "running"))
        (machine (make-state-machine :state "idle")))
    (assert-setter-roundtrips
      ((node-name node) 'renamed-source "RENAMED-SOURCE")
      ((edge-from edge) (make-node "new-source") "new-source")
      ((edge-from-port edge) nil "value")
      ((edge-to edge) 'new-sink "NEW-SINK")
      ((edge-to-port edge) 'input-port "INPUT-PORT")
      ((transition-from transition) 'waiting "WAITING")
      ((transition-event-type transition) 'resume "RESUME")
      ((state-machine-initial-state machine) 'boot "BOOT"))))

(deftest collection-setters-copy-public-structures
  (let* ((node (make-node "source"))
         (transition (make-transition "idle" "start" "running"))
         (machine (make-state-machine :state "idle"))
         (node-inputs (list 'left 'right))
         (node-metadata (list (list :labels "alpha")))
         (history (list (list :event "boot")))
         (transition-metadata (list (list :labels "start")))
         (machine-metadata (list (list :kind "workflow"))))
    (assert-setter-copy-isolated (node-inputs node)
        node-inputs
        '("LEFT" "RIGHT")
      (setf (car node-inputs) 'mutated))
    (assert-setter-copy-isolated (node-metadata node)
        node-metadata
        '((:labels "alpha"))
      (setf (cadar node-metadata) "beta"))
    (assert-setter-copy-isolated (transition-metadata transition)
        transition-metadata
        '((:labels "start"))
      (setf (cadar transition-metadata) "changed"))
    (assert-setter-copy-isolated (state-machine-history machine)
        history
        '((:event "boot"))
      (setf (cadar history) "mutated"))
    (assert-setter-copy-isolated (state-machine-metadata machine)
        machine-metadata
        '((:kind "workflow"))
      (setf (cadar machine-metadata) "updated"))))

(deftest graph-node-setter-copies-node-tables
  (let* ((graph (make-graph))
         (graph-node (make-node "graph-source" :metadata '((:kind :original))))
         (graph-nodes (make-test-table "graph-source" graph-node)))
    (setf (graph-nodes graph) graph-nodes)
    (setf (node-name graph-node) "mutated-graph-source")
    (is (equal (mapcar #'node-name
                       (loop for value being the hash-values of (graph-nodes graph)
                             collect value))
               '("graph-source")))
    (is (equal (node-metadata (gethash "graph-source" (graph-nodes graph)))
               '((:kind :original))))))

(deftest runtime-state-setters-copy-context-values-and-keep-actions
  (let* ((context (make-context))
         (transition (make-transition "idle" "start" "running"))
         (values (make-test-table "count" 1))
         (action (lambda (state event runtime-context)
                   (declare (ignore state event runtime-context))
                   :ok)))
    (setf (context-values context) values
          (transition-action transition) action)
    (setf (gethash "count" values) 2)
    (unless (eq (transition-action transition) action)
      (error "Transition action was not preserved"))
    (unless (= (gethash "count" (context-values context)) 1)
      (error "Context values were not copied"))))

(deftest core-model-default-constructors-fill-empty-structures
  (let ((node (make-node :n1))
        (edge (make-edge :a :b))
        (context (make-context)))
    (is (equal (node-inputs node) '("value")))
    (is (equal (node-outputs node) '("value")))
    (is (equal (node-metadata node) '()))
    (is (equal (edge-metadata edge) '()))
    (is (= (hash-table-count (context-values context)) 0))
    (is (equal (context-events context) '()))
    (is (equal (context-effects context) '()))
    (is (equal (context-trace context) '()))))
