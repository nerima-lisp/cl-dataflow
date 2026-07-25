(in-package #:cl-dataflow.test)

(deftest node-construction-and-graph-sort
  (with-graph-fixture (graph ((source "source")
                              (middle "middle")
                              (sink "sink"))
                        :edges ((source middle)
                                (middle sink)))
    (assert-node-order (topological-sort graph)
                        '("source" "middle" "sink"))
    (is (validate-graph graph))))

(deftest topological-sort-is-stable-for-independent-sources
  (with-graph-fixture (graph ((beta "beta")
                              (alpha "alpha")
                              (sink "sink"))
                        :edges ((beta sink)
                                (alpha sink)))
    (assert-node-order (topological-sort graph)
                        '("alpha" "beta" "sink"))
    (assert-node-order (graph-source-nodes graph)
                        '("alpha" "beta"))
    (assert-node-order (graph-sink-nodes graph)
                        '("sink"))))

(deftest graph-sink-nodes-are-stable-for-independent-sinks
  (with-graph-fixture (graph ((source "source")
                              (beta "beta")
                              (alpha "alpha"))
                        :edges ((source beta)
                                (source alpha)))
    (assert-node-order (graph-sink-nodes graph)
                        '("alpha" "beta"))
    (assert-node-order (topological-sort graph)
                        '("source" "alpha" "beta"))))

(deftest graph-reachability-uses-prolog-successor-queries-for-transitive-search
  (with-graph-fixture (graph ((source "source")
                              (middle "middle")
                              (sink "sink")
                              (isolated "isolated"))
                        :edges ((source middle)
                                (middle sink)))
    (is (graph-reachable-p graph source sink))
    (is (graph-reachable-p graph source middle))
    (is (not (graph-reachable-p graph sink source)))
    (is (not (graph-reachable-p graph source isolated)))))

(deftest graph-source-and-sink-nodes-return-copy-snapshots
  (with-graph-fixture (graph ((source "source" :metadata '((:kind :source)))
                              (sink "sink" :metadata '((:kind :sink))))
                        :edges ((source sink)))
    (let ((sources (graph-source-nodes graph))
          (sinks (graph-sink-nodes graph)))
      (is (not (eq (first sources) (find-node graph "source"))))
      (is (not (eq (first sinks) (find-node graph "sink"))))
      (setf (node-metadata (first sources)) '((:kind :mutated-source))
            (node-metadata (first sinks)) '((:kind :mutated-sink)))
      (is (equal (node-metadata (find-node graph "source"))
                  '((:kind :source))))
      (is (equal (node-metadata (find-node graph "sink"))
                  '((:kind :sink)))))))

(deftest graph-cycle-detection
  (with-graph-fixture (graph ((a "a")
                              (b "b"))
                        :edges ((a b)
                                (b a)))
    (signals graph-cycle-error
      (topological-sort graph))))

(deftest graph-source-and-sink-nodes-stay-inspectable-on-a-cyclic-graph
  ;; graph-source-nodes/sink-nodes only need indegree/successor membership, not
  ;; topological order, so a legally constructed cycle must not make them raise
  ;; graph-cycle-error -- the same inspectability GRAPH-NODES/GRAPH-EDGES keep
  ;; on cyclic graphs.
  (with-graph-fixture (graph ((head "head")
                              (a "a")
                              (b "b")
                              (tail "tail"))
                        :edges ((head a)
                                (a b)
                                (b a)
                                (b tail)))
    (assert-node-order (graph-source-nodes graph) '("head"))
    (assert-node-order (graph-sink-nodes graph) '("tail"))
    (signals graph-cycle-error
      (topological-sort graph))))

(deftest graph-cycle-error-exposes-cyclic-nodes
  (with-graph-fixture (graph ((a "a")
                              (b "b"))
                        :edges ((a b)
                                (b a)))
    (let ((captured
            (capture-condition (condition graph-cycle-error)
              (topological-sort graph))))
      (is captured)
      (assert-node-order (graph-cycle-nodes captured)
                          '("a" "b"))
      (assert-graph-condition captured
                              graph
                              "Graph contains a cycle or disconnected cycle component."
                              :type 'graph-cycle-error)
      (assert-condition-report captured "Cyclic nodes: a, b"))))

(deftest graph-cycle-error-report-omits-node-list-when-empty
  (let* ((graph (make-graph))
          (captured (make-condition 'graph-cycle-error
                                    :graph graph
                                    :nodes '()
                                    :detail "Graph contains a cycle or disconnected cycle component.")))
    (assert-condition-report captured
                              "Graph contains a cycle or disconnected cycle component.")))

(deftest missing-node-rejected-on-edge-addition
  (with-graph-fixture (graph ((node "only")))
    (handler-case
        (add-edge graph node "missing")
      (node-not-found-error (condition)
        (assert-graph-condition condition
                                graph
                                "Node not found: missing"
                                :type 'node-not-found-error
                                :designator "missing")
        (assert-condition-report condition "Node not found: missing")))))

(deftest add-node-rejects-non-node-designators-with-condition-data
  (let* ((graph (make-graph))
          (captured
            (capture-condition (condition invalid-input-error)
              (add-node graph "missing-node"))))
    (is captured)
    (is (equal (invalid-input-expected captured) 'node))
    (is (equal (invalid-input-value captured) "missing-node"))
    (is (equal (invalid-input-detail captured)
                "Expected NODE, got \"missing-node\""))
    (is (typep captured 'cl-dataflow-error))))

(deftest add-node-rejects-duplicate-node-names
  (with-graph-fixture (graph ((source "source")))
    (let ((captured
            (capture-condition (condition graph-error)
              (add-node graph (make-node "source")))))
      (is captured)
      (assert-graph-condition captured
                              graph
                              "Node already exists: source"
                              :type 'graph-error))))

(deftest add-edge-rejects-duplicate-edge-definitions
  (with-graph-fixture (graph ((source "source" :outputs '("left"))
                              (sink "sink" :inputs '("right")))
                        :edges ((source sink :from-port "left" :to-port "right")))
    (let ((captured
            (handler-case
                (add-edge graph source sink :from-port "left" :to-port "right")
              (graph-error (condition)
                condition))))
      (is captured)
      (assert-graph-condition captured
                              graph
                              "Edge already exists: source:left -> sink:right"
                              :type 'graph-error))))

(deftest add-edge-rejects-unknown-ports-immediately
  (with-graph-fixture (graph ((source "source" :outputs '("left"))
                              (sink "sink" :inputs '("right"))))
    (signals graph-error
      (add-edge graph source sink :from-port "missing" :to-port "right"))
    (signals graph-error
      (add-edge graph source sink :from-port "left" :to-port "missing"))))

(deftest edge-construction-normalizes-designators
  (let ((edge (make-edge 'source 'sink :from-port 'left :to-port 'right)))
    (is (equal (edge-from edge) "SOURCE"))
    (is (equal (edge-to edge) "SINK"))
    (is (equal (edge-from-port edge) "LEFT"))
    (is (equal (edge-to-port edge) "RIGHT"))))

(deftest graph-validation-rejects-unknown-ports
  (with-graph-fixture (graph ((source "source" :outputs '("left"))
                              (sink "sink" :inputs '("right"))))
    (setf (graph-edges graph)
          (list (make-instance 'edge
                                :from (node-name source)
                                :from-port "missing"
                                :to (node-name sink)
                                :to-port "right")))
    (signals graph-error
      (validate-graph graph))))

(deftest add-node-rejects-duplicate-port-names
  (let ((graph (make-graph)))
    (signals graph-error
      (add-node graph (make-instance 'node
                                      :name "source"
                                      :inputs '("dup" "dup")
                                      :outputs '("ok"))))
    (signals graph-error
      (add-node graph (make-instance 'node
                                      :name "source"
                                      :inputs '("ok")
                                      :outputs '("dup" "dup"))))))

(deftest graph-error-accessors-expose-condition-data
  (with-graph-fixture (graph ((source "source" :outputs '("left"))
                              (sink "sink" :inputs '("right"))))
    (setf (graph-edges graph)
          (list (make-edge source sink :from-port "left" :to-port "missing")))
    (let ((captured nil))
      (handler-case
          (validate-graph graph)
        (graph-error (condition)
          (setf captured condition)))
      (is captured)
      (assert-graph-condition captured
                              graph
                              "Edge source -> sink uses unknown input port missing"
                              :type 'graph-error))))

(deftest graph-validation-rejects-malformed-node-port-lists
  (let ((graph (make-graph))
        (node (make-instance 'node
                              :name "source"
                              :inputs '("ok")
                              :outputs '("dup" "dup"))))
    (setf (gethash (node-name node) (slot-value graph 'cl-dataflow::nodes)) node)
    (signals graph-error
      (validate-graph graph))))

(deftest node-not-found-exposes-designator-when-topological-sort-fails
  (with-graph-fixture (graph ((source "source")))
    (setf (graph-edges graph)
          (list (make-instance 'edge
                                :from "source"
                                :from-port "value"
                                :to "missing"
                                :to-port "value")))
    (let ((captured nil))
      (handler-case
          (topological-sort graph)
        (node-not-found-error (condition)
          (setf captured condition)))
      (is captured)
      (assert-graph-condition captured
                              graph
                              "Edge references missing node: source -> missing"
                              :type 'node-not-found-error)
      (is (typep (node-not-found-designator captured) 'edge))
      (is (equal (edge-from (node-not-found-designator captured)) "source"))
      (is (equal (edge-to (node-not-found-designator captured)) "missing")))))

(deftest node-not-found-exposes-designator-when-edge-from-node-is-missing
  ;; The companion to the -TO case above: %GRAPH-RULEBASE validates both the
  ;; FROM and TO node of every edge, and the two checks are independent.
  (with-graph-fixture (graph ((sink "sink")))
    (setf (graph-edges graph)
          (list (make-instance 'edge
                                :from "missing"
                                :from-port "value"
                                :to "sink"
                                :to-port "value")))
    (signals node-not-found-error (topological-sort graph))))

(deftest graph-errors-inherit-from-cl-dataflow-error
  (with-graph-fixture (graph ((source "source" :outputs '("left"))
                              (sink "sink" :inputs '("right"))))
    (setf (graph-edges graph)
          (list (make-edge source sink :from-port "left" :to-port "missing")))
    (let ((captured nil))
      (handler-case
          (validate-graph graph)
        (graph-error (condition)
          (setf captured condition)))
      (is captured)
      (is (typep captured 'cl-dataflow-error)))))

(deftest invalid-input-errors-copy-mutable-designators
  (let* ((designator (list :missing "node"))
          (captured nil))
    (handler-case
        (add-node (make-graph) designator)
      (invalid-input-error (condition)
        (setf captured condition)))
    (is captured)
    (is (not (eq (invalid-input-value captured) designator)))
    (setf (second designator) "changed")
    (is (equal (invalid-input-value captured) '(:missing "node")))
    (is (equal (invalid-input-detail captured)
                "Expected NODE, got (:MISSING \"node\")"))))

(deftest graph-condition-details-escape-control-characters
  (let* ((raw (format nil "spoof~%tab~Creturn~Cdel~Cend"
                       #\Tab
                       #\Return
                       (code-char 127)))
          (port (format nil "out-~A" raw)))
    (with-captured-condition (captured invalid-input-error)
        (make-node "source" :outputs (list port port))
      (let ((detail (invalid-input-detail captured))
            (report (condition-report-string captured)))
        (is (search "\\n" detail))
        (is (search "\\t" detail))
        (is (search "\\r" detail))
        (is (search "\\x7F;" detail))
        (is (search "\\n" report))
        (is (not (search (format nil "~%tab") detail)))
        (is (not (search (format nil "~Creturn" #\Tab) detail)))
        (is (not (search (format nil "~Cdel" #\Return) detail))))))
  (let* ((raw (format nil "missing~%tab~Creturn~Cdel~Cend"
                       #\Tab
                       #\Return
                       (code-char 127)))
          (captured nil))
    (handler-case
        (add-edge (make-graph) raw "sink")
      (node-not-found-error (condition)
        (setf captured condition)))
    (is captured)
    (let ((detail (graph-error-detail captured))
          (report (condition-report-string captured)))
      (is (search "\\n" detail))
      (is (search "\\t" detail))
      (is (search "\\r" detail))
      (is (search "\\x7F;" detail))
      (is (search "\\n" report))
      (is (not (search (format nil "~%tab") detail)))
      (is (not (search (format nil "~Creturn" #\Tab) detail)))
      (is (not (search (format nil "~Cdel" #\Return) detail))))))
