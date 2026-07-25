(in-package #:cl-dataflow.test)

(deftest
  internal-output-binding-helpers-normalize-node-results
  (let ((silent (make-node "silent" :outputs '()))
        (disconnected (make-node "disconnected"))
        (single (make-node "single" :outputs '("value")))
        (multi (make-node "multi" :outputs '("left" "right"))))
    (setf (slot-value disconnected 'cl-dataflow::outputs) nil)
    (is (equal (cl-dataflow::%node-output-bindings disconnected 42) '()))
    (is (equal (cl-dataflow::%node-output-bindings silent 42) '(("value" . 42))))
    (is (equal (cl-dataflow::%node-output-bindings single 42) '(("value" . 42))))
    (is
      (equal
        (cl-dataflow::%node-output-bindings single '(("value" . 42)))
        '(("value" . 42))))
    (is
      (equal
        (cl-dataflow::%node-output-bindings multi '(:left 1 :right 2))
        '(("LEFT" . 1) ("RIGHT" . 2))))))

(deftest
  internal-collect-node-inputs-prefers-edges-and-falls-back-to-structured-input
  (let* ((graph (make-graph))
          (source (make-node "source" :outputs '("left" "right")))
          (single-sink (make-node "single-sink"))
          (join (make-node "join" :inputs '("left" "right")))
          (context (make-context)))
    (dolist (node (list source single-sink join))
      (add-node graph node))
    (add-edge graph source single-sink :from-port "left")
    (add-edge graph source join :from-port "left" :to-port "left")
    (add-edge graph source join :from-port "right" :to-port "right")
    (cl-dataflow::%store-value context (node-name source) "left" 10)
    (cl-dataflow::%store-value context (node-name source) "right" 20)
    (is
      (= (cl-dataflow::%collect-node-inputs context graph single-sink :ignored) 10))
    (is
      (equal
        (cl-dataflow::%collect-node-inputs context graph join :ignored)
        (list (cons "left" 10) (cons "right" 20)))))
  (let ((standalone-graph (make-graph))
        (standalone (make-node "standalone" :inputs '("left" "right"))))
    (add-node standalone-graph standalone)
    (is
      (equal
        (cl-dataflow::%collect-node-inputs
          (make-context)
          standalone-graph
          standalone
          (list :left 1 :right 2))
        (list (cons "LEFT" 1) (cons "RIGHT" 2))))))

(deftest internal-collect-node-inputs-resolves-multiple-producers-on-one-port-to-the-newest-edge
  ;; The graph layer allows more than one edge into the same (node . port) --
  ;; it is also used standalone for reachability/topology, where fan-in is
  ;; ordinary in-degree, not a pipeline binding conflict (see add-edge). When
  ;; such a graph is actually run as a pipeline, %edge-binding-table must
  ;; resolve the ambiguity deterministically: the most recently added edge
  ;; wins. This must hold both when %collect-node-inputs derives incoming
  ;; edges itself and when run-pipeline's precomputed index is passed in.
  (let* ((graph (make-graph))
          (a (make-node "a" :outputs '("value")))
          (b (make-node "b" :outputs '("value")))
          (sink (make-node "sink" :inputs '("value")))
          (context (make-context)))
    (dolist (node (list a b sink))
      (add-node graph node))
    (add-edge graph a sink)
    (add-edge graph b sink)
    (cl-dataflow::%store-value context (node-name a) "value" 1)
    (cl-dataflow::%store-value context (node-name b) "value" 2)
    (is (= (cl-dataflow::%collect-node-inputs context graph sink :ignored)
            2))
    (is (= (cl-dataflow::%collect-node-inputs
            context graph sink :ignored
            (cl-dataflow::%incoming-edges-index graph))
            2))))

(deftest
  internal-collect-sink-results-collapses-single-and-branching-sinks
  (let* ((graph (make-graph))
          (source (make-node "source" :outputs '("left" "right")))
          (left (make-node "left"))
          (right (make-node "right"))
          (context (make-context)))
    (dolist (node (list source left right))
      (add-node graph node))
    (add-edge graph source left :from-port "left")
    (add-edge graph source right :from-port "right")
    (cl-dataflow::%store-value context (node-name left) "value" 16)
    (cl-dataflow::%store-value context (node-name right) "value" 30)
    (is
      (equal
        (cl-dataflow::%collect-sink-results graph context (topological-sort graph))
        '(("left" ("value" . 16)) ("right" ("value" . 30))))))
  (let* ((graph (make-graph))
          (sink (make-node "sink" :outputs '("left" "right")))
          (context (make-context)))
    (add-node graph sink)
    (cl-dataflow::%store-value context (node-name sink) "left" 6)
    (cl-dataflow::%store-value context (node-name sink) "right" 10)
    (is
      (equal
        (cl-dataflow::%collect-sink-results graph context (topological-sort graph))
        '(("left" . 6) ("right" . 10)))))
  (let* ((graph (make-graph))
          (sink (make-node "sink"))
          (context (make-context)))
    (add-node graph sink)
    (cl-dataflow::%store-value context (node-name sink) "value" 16)
    (is
      (=
        (cl-dataflow::%collect-sink-results graph context (topological-sort graph))
        16))))

(deftest
  internal-collect-sink-results-return-nil-without-execution-order
  (let* ((graph (make-graph))
          (context (make-context)))
    (is (null (cl-dataflow::%collect-sink-results graph context '())))))

(deftest
  internal-normalization-helpers-cover-scalar-plist-and-table-paths
  (with-test-table
    (table "value" 10 "other" 20)
    (let ((public-copy (cl-dataflow::%copy-structured-value table)))
      (setf (gethash "value" public-copy) 99)
      (is (= (gethash "value" table) 10)))
    (is (equal (cl-dataflow::%normalize-name :state) "STATE"))
    (is (equal (cl-dataflow::%normalize-name 42) "42"))
    (let ((circular (list "loop")))
      (setf (cdr circular) circular)
      (is (search "#1=" (cl-dataflow::%normalize-name circular))))
    (is (equal (cl-dataflow::%normalize-port-list :value) '("VALUE")))
    (is (= (cl-dataflow::%plist-value '("value" 1 "other" 2) "other") 2))
    (is (null (cl-dataflow::%plist-value '("value" 1) "missing")))
    (is (= (cl-dataflow::%normalize-structured-input table '("value")) 10))
    (is
      (= (cl-dataflow::%normalize-structured-input '(("value" . 11)) '("value")) 11))
    (is
      (equal
        (cl-dataflow::%normalize-structured-input '("value" 1 "other" 2) '("value"))
        1))
    (is (equal (cl-dataflow::%normalize-output-structure 7 nil) 7))
    (is (equal (cl-dataflow::%normalize-output-structure 7 '("value"))
               '(("value" . 7))))
    (is (equal (cl-dataflow::%hash-table-keys table)
               '("value" "other")))
    ;; An odd-length, non-alist list is neither a plist nor an alist, so
    ;; %CLASSIFY-STRUCTURED-VALUE falls through to :SCALAR -- exercising
    ;; EVENP's false outcome, which every other structured-value fixture here
    ;; is even-length and so never reaches.
    (is (not (cl-dataflow::%structured-value-p '(:odd-length))))))

(it-fuzz "%normalize-name never errors and always returns a string on arbitrary input"
    ((value (gen-sexp :max-depth 4 :max-list-length 6)))
    ()
  ;; The example test above hand-picks a keyword, a number, and a circular
  ;; list -- %NORMALIZE-NAME's TYPECASE catch-all is built to handle any Lisp
  ;; value (see its own comment on binding *PRINT-CIRCLE*), so this fuzzes
  ;; broader, unanticipated shapes GEN-SEXP produces rather than re-checking
  ;; those three known cases.
  (is (stringp (cl-dataflow::%normalize-name value))))

(deftest
  internal-copy-structured-value-preserves-circular-structures
  (dolist (value (list 42 #\x :keyword #'car))
    (is (eql (cl-dataflow::%copy-structured-value value) value)))
  (let ((function #'identity))
    (is (eq (cl-dataflow::%copy-structured-value function) function)))
  (let ((value (list "loop")))
    (setf (cdr value) value)
    (let ((copy (cl-dataflow::%copy-structured-value value)))
      (is (not (eq copy value)))
      (is (not (eq (car copy) (car value))))
      (is (equal (car copy) "loop"))
      (is (eq (cdr copy) copy))))
  (let ((value (make-array 1)))
    (setf (aref value 0) value)
    (let ((copy (cl-dataflow::%copy-structured-value value)))
      (is (not (eq copy value)))
      (is (eq (aref copy 0) copy))))
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "self" table) table
          (gethash "value" table) 7)
    (let ((copy (cl-dataflow::%copy-structured-value table)))
      (is (not (eq copy table)))
      (is (= (gethash (copy-seq "value") copy) 7))
      (is (eq (gethash "self" copy) copy))))
  (let* ((shared (list :shared))
          (value (list shared shared))
          (copy (cl-dataflow::%copy-structured-value value)))
    (is (not (eq copy value)))
    (is (not (eq (first copy) shared)))
    (is (eq (first copy) (second copy)))))

(deftest internal-copy-structured-value-trampolines-a-long-cons-chain
  ;; %COPY-STRUCTURED-VALUE/CPS bounces its cons-chain traversal through
  ;; %RUN-COPY-TRAMPOLINE instead of recursing, so a list far longer than
  ;; SBCL's default control-stack depth still copies without a stack
  ;; exhaustion error.
  (let* ((length 500000)
         (value (loop for i below length collect i))
         (copy (cl-dataflow::%copy-structured-value value)))
    (is (equal copy value))
    (is (not (eq copy value)))
    (is (= (length copy) length))))

(deftest internal-error-copy-helpers-copy-nested-model-structures
  (let* ((node (make-node "source"
                          :inputs '("in")
                          :outputs '("out")
                          :metadata '((:kind :stage))))
         (edge (make-edge "source" "sink"
                          :from-port "out"
                          :to-port "in"
                          :metadata '((:kind :edge))))
         (graph (make-graph :metadata '((:kind :graph)))))
    (add-node graph node)
    (setf (graph-edges graph) (list edge))
    (let* ((graph-copy (cl-dataflow::%copy-error-value graph))
            (copied-node (gethash "source" (slot-value graph-copy 'cl-dataflow::nodes)))
            (copied-edge (first (slot-value graph-copy 'cl-dataflow::edges))))
      (is (not (eq graph-copy graph)))
      (is (not (eq copied-node node)))
      (is (not (eq copied-edge edge)))
      (setf (node-inputs copied-node) '("mutated")
            (node-metadata copied-node) '((:kind :mutated))
            (edge-metadata copied-edge) '((:kind :mutated)))
      (is (equal (node-inputs node) '("in")))
      (is (equal (node-metadata node) '((:kind :stage))))
      (is (equal (edge-metadata edge) '((:kind :edge))))
      (is (equal (graph-metadata graph) '((:kind :graph)))))
    (let* ((event (make-event "started" :payload '(:n 1)))
           (event-copy (cl-dataflow::%copy-error-value event)))
      (is (not (eq event-copy event)))
      (is (equal (event-payload event-copy) (event-payload event))))
    (let* ((effect (make-effect "log" :payload '(:msg "hi")))
           (effect-copy (cl-dataflow::%copy-error-value effect)))
      (is (not (eq effect-copy effect)))
      (is (equal (effect-payload effect-copy) (effect-payload effect))))))

(deftest internal-node-error-snapshot-defaults-unbound-slots
  ;; %COPY-NODE-ERROR-SNAPSHOT exists to snapshot a node for error reporting
  ;; even when construction left a slot unbound; %SLOT-VALUE-OR must fall back
  ;; to its default rather than signalling UNBOUND-SLOT in that case.
  (let ((node (make-node "partial" :inputs '("in"))))
    (slot-makunbound node 'cl-dataflow::outputs)
    (let ((snapshot (cl-dataflow::%copy-node-error-snapshot node)))
      (is (equal (node-name snapshot) "partial"))
      (is (equal (node-inputs snapshot) '("in")))
      ;; NODE-OUTPUTS normalizes NIL back to the default ("value") port on
      ;; read, so check the raw slot to confirm %SLOT-VALUE-OR's fallback.
      (is (null (slot-value snapshot 'cl-dataflow::outputs))))))
