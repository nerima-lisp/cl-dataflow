(in-package #:cl-dataflow.test)

(deftest
 pipeline-copies-mutable-node-results-into-context-and-trace
 (let ((payload (list 1 2)))
   (with-single-node-test-runtime
    (stage
     pipeline
     context
     :outputs
     '("items")
     :handler
     (lambda (input context)
       (declare (ignore input context))
       payload))
    (declare (ignore stage pipeline))
    (setf (cadr payload) 3)
    (is (equal (context-value context "source" "items") '(1 2)))
    (assert-context-first-trace-entry context (:output '(("items" . (1 2))))))))

(deftest
 pipeline-single-scalar-fast-path-preserves-raw-trace-input-identity
 (let* ((pipeline-input (vector :payload))
        (handler-input nil))
   (with-single-node-test-runtime
    (stage
     pipeline
     context
     :input
     pipeline-input
     :inputs
     '("input")
     :outputs
     '("value")
     :handler
     (lambda (input context)
       (declare (ignore context))
       (setf handler-input input)
       :ok))
    (declare (ignore stage pipeline))
    (let ((raw-trace (first (cl-dataflow::%context-trace-list context))))
      (is (eq handler-input pipeline-input))
      (is (eq (getf raw-trace :input) handler-input))))))

(deftest
 pipeline-single-output-binding-list-uses-normalization-fallback
 (let ((payload (list 1 2)))
   (with-single-node-test-runtime
    (stage
     pipeline
     context
     :outputs
     '("items")
     :handler
     (lambda (input context)
       (declare (ignore input context))
       (list (cons "items" payload))))
    (declare (ignore stage pipeline))
    (let ((stored (context-value context "source" "items"))
          (traced (cdar (getf (first (context-trace context)) :output))))
      (is (equal stored '(1 2)))
      (is (equal traced '(1 2)))
      (is (not (eq payload stored)))
      (is (not (eq payload traced)))
      (is (not (eq stored traced)))))))

(deftest
 pipeline-plan-preserves-newest-producer-wins
 (with-graph-fixture
  (graph
   ((older
     "older"
     :outputs
     '("value")
     :handler
     (lambda (input context)
       (declare (ignore input context))
       1))
    (newer
     "newer"
     :outputs
     '("value")
     :handler
     (lambda (input context)
       (declare (ignore input context))
       2))
    (sink
     "sink"
     :inputs
     '("value")
     :outputs
     '("value")
     :handler
     (lambda (input context)
       (declare (ignore context))
       input)))
   :edges
   ((older sink) (newer sink)))
  (is (= (run-pipeline (make-pipeline :graph graph)) 2))))

(deftest
  pipeline-interleaves-node-event-and-effect-trace-indices
  (let (emitted
        performed)
    (with-effect-handlers
      (handlers
        "audit"
        (lambda (effect context)
          (declare (ignore effect context))
          :handled))
      (with-linear-test-pipeline
        (graph pipeline source sink
               :source-outputs '("value")
               :sink-inputs '("value")
               :sink-outputs '("result")
               :source-handler (lambda (input context)
                                 (declare (ignore input context))
                                 :value)
               :sink-handler (lambda (input context)
                               (declare (ignore input))
                               (setf emitted (emit-event context "observed"))
                               (setf performed (perform-effect context "audit"))
                               :done))
        (declare (ignore graph source sink))
        (let ((context (make-context :effect-handlers handlers)))
        (run-pipeline pipeline :context context)
        (let ((trace (context-trace-in-order context)))
          (assert-trace-kinds trace '(:node :event :effect :node))
          (is (= (event-trace-index emitted) 1))
          (is (= (effect-trace-index performed) 2))
          (is (= (getf (second trace) :trace-index) 1))
          (is (= (getf (third trace) :trace-index) 2))
          (assert-context-trace-count context 4))
        (run-pipeline pipeline :context context)
        (is (= (event-trace-index emitted) 5))
        (is (= (effect-trace-index performed) 6))
        (assert-context-trace-count context 8))))))

(deftest
  pipeline-runs-deep-stage-order-without-cps-continuations
  (let* ((stage-count 2000)
         (seen nil)
         (stages
           (loop for index below stage-count
                 collect (let ((captured-index index))
                           (make-node
                             (format nil "stage-~D" captured-index)
                             :handler
                             (lambda (input context)
                               (declare (ignore input context))
                               (push captured-index seen)))))))
    (run-pipeline (make-linear-stage-pipeline stages))
    (is (equal (nreverse seen)
               (loop for index below stage-count
                     collect index)))))

(deftest
  pipeline-error-skips-later-stages-and-finalization
  (let* ((seen nil)
          (context (make-context :result :not-finalized))
          (first
        (make-node
          "first"
          :handler
          (lambda (input context)
            (declare (ignore input context))
            (push :first seen))))
          (failing
        (make-node
          "failing"
          :handler
          (lambda (input context)
            (declare (ignore input context))
            (push :failing seen)
            (error "expected failure"))))
          (later
        (make-node
          "later"
          :handler
          (lambda (input context)
            (declare (ignore input context))
            (push :later seen))))
          (pipeline (make-pipeline :stages (list first failing later))))
    (signals simple-error (run-pipeline pipeline :context context))
    (is (equal (nreverse seen) '(:first :failing)))
    (is (eq (context-result context) :not-finalized))
    (is (= (length (context-trace-in-order context)) 1))))

(deftest
  pipeline-output-name-plan-is-owned-and-invalidated-by-node-output-mutations
  (let ((setter-port (copy-seq "right")))
    (with-single-node-test-runtime
      (stage pipeline context
             :outputs (list "left")
             :handler (lambda (input context)
                        (declare (ignore input context))
                        7))
      (declare (ignore stage context))
      (let* ((live-node (find-node (pipeline-graph pipeline) "source"))
             (original-plan (cl-dataflow::%pipeline-execution-plan pipeline)))
        (setf (node-outputs live-node) (list setter-port))
        (is (= (run-pipeline pipeline) 7))
        (let* ((setter-plan (cl-dataflow::%pipeline-execution-plan pipeline))
               (planned-name
                 (caaar
                   (cl-dataflow::%pipeline-execution-plan-output-key-plans
                     setter-plan)))
               (live-name (first (cl-dataflow::%node-outputs-list live-node))))
          (is (not (eq original-plan setter-plan)))
          (is (string= planned-name "right"))
          (is (not (eq planned-name live-name)))
          (setf (char live-name 0) #\l)
          (is (string= planned-name "right"))
          (is (= (run-pipeline pipeline) 7))
          (is
            (not
              (eq setter-plan (cl-dataflow::%pipeline-execution-plan pipeline))))
          (is
            (string=
              (caaar
                (cl-dataflow::%pipeline-execution-plan-output-key-plans
                  (cl-dataflow::%pipeline-execution-plan pipeline)))
              "light")))))))

(deftest pipeline-fan-in-node-resolves-multiple-cached-input-bindings
  ;; A node fed by two incoming edges resolves more than one binding, which is
  ;; the cached execution plan's multi-binding path (%RESOLVE-INPUT-KEY-PLAN +
  ;; the T branch of %RUN-NODE's input cond); single-source pipelines never
  ;; reach it.
  (with-graph-fixture
    (graph ((source "source"
                    :outputs '("left" "right")
                    :handler (lambda (input context)
                               (declare (ignore context))
                               (list (cons "left" (1+ input))
                                     (cons "right" (* input 2)))))
            (join "join"
                  :inputs '("a" "b")
                  :outputs '("sum")
                  :handler (lambda (input context)
                             (declare (ignore context))
                             (reduce #'+ input :key #'cdr))))
           :edges ((source join :from-port "left" :to-port "a")
                   (source join :from-port "right" :to-port "b")))
    (is (= (run-pipeline (make-pipeline :graph graph) :input 5) 16))))

(deftest pipeline-cached-input-plan-drops-undeclared-incoming-port-bindings
  ;; Reach the cached plan path with a valid edge first, then mutate the live
  ;; edge so the rebuilt plan sees incoming edges but no declared bindings.
  (let* ((seen-input :not-run)
         (graph (make-graph))
         (source
           (make-node
            "source"
            :outputs '("value")
            :handler (lambda (input context)
                       (declare (ignore input context))
                       42)))
         (sink
           (make-node
            "sink"
            :inputs '("declared")
            :handler (lambda (input context)
                       (declare (ignore context))
                       (setf seen-input input)
                       :done))))
    (add-node graph source)
    (add-node graph sink)
    (add-edge graph source sink :from-port "value" :to-port "declared")
    (let* ((pipeline (make-pipeline :graph graph :stages (list source sink)))
           (live-edge (first (cl-dataflow::%graph-edges-list (pipeline-graph pipeline)))))
      (is (eq (run-pipeline pipeline :input :pipeline-input) :done))
      (is (= seen-input 42))
      (setf (edge-to-port live-edge) "undeclared"
            seen-input :not-run)
      (is (eq (run-pipeline pipeline :input :pipeline-input) :done))
      (is (null seen-input)))))

(deftest pipeline-cached-sink-results-empty-plan-list-yields-nil
  ;; The runtime normally reaches this through finalized execution, but the
  ;; empty sink-plan branch itself is easiest to pin down directly.
  (is
   (null
    (cl-dataflow::%collect-cached-sink-results (make-context) '()))))

(deftest pipeline-empty-pipeline-run-yields-no-sink-result
  ;; With no stages the plan has no sink-result plans, exercising the empty-sinks
  ;; branch of the cached sink collector.
  (is (null (run-pipeline (make-pipeline)))))

(deftest pipeline-stage-setter-allows-clearing-stages
  ;; Clearing stages must take the NIL branch in (SETF PIPELINE-STAGES), drop
  ;; the cached plan, and leave the pipeline runnable as empty.
  (let* ((stage
           (make-node
            "source"
            :handler
            (lambda (input context)
              (declare (ignore input context))
              :ok)))
         (pipeline (single-node-pipeline stage)))
    (is (cl-dataflow::%pipeline-execution-plan pipeline))
    (setf (pipeline-stages pipeline) nil)
    (is (null (pipeline-stages pipeline)))
    (is (null (cl-dataflow::%pipeline-execution-plan pipeline)))
    (is (null (run-pipeline pipeline)))))

(deftest pipeline-signature-currency-checks-detect-length-mismatch
  ;; A plan's own stage and signature lists are always equal length in normal
  ;; use, so the currency checks' unequal-length outcome (they return NIL) is
  ;; reached here by calling them directly, matching the internal-test pattern.
  (let* ((graph (make-graph))
         (node (make-node "n"))
         (edge (make-edge "a" "b" :from-port "out" :to-port "in"))
         (stage-signature
          (make-instance 'cl-dataflow::pipeline-stage-signature
                         :node node
                         :name "n"
                         :inputs '()
                         :outputs '()))
         (edge-signature
          (make-instance 'cl-dataflow::pipeline-edge-signature
                         :edge edge
                         :from (edge-from edge)
                         :from-port (edge-from-port edge)
                         :to (edge-to edge)
                         :to-port (edge-to-port edge))))
    (add-node graph node)
    (is (cl-dataflow::%pipeline-stage-signatures-current-p graph '() '()))
    (is (not (cl-dataflow::%pipeline-stage-signatures-current-p graph (list node) '())))
    (is (not (cl-dataflow::%pipeline-stage-signatures-current-p graph '() (list stage-signature))))
    (is (not (cl-dataflow::%pipeline-stage-signatures-current-p
              graph
              (list node node)
              (list stage-signature))))
    (is (not (cl-dataflow::%pipeline-stage-signatures-current-p
              graph
              (list node)
              (list stage-signature stage-signature))))
    (is (cl-dataflow::%pipeline-edge-signatures-current-p '() '()))
    (is (not (cl-dataflow::%pipeline-edge-signatures-current-p (list :edge) '())))
    (is (not (cl-dataflow::%pipeline-edge-signatures-current-p '() (list edge-signature))))
    (is (not (cl-dataflow::%pipeline-edge-signatures-current-p
              (list edge edge)
              (list edge-signature))))
    (is (not (cl-dataflow::%pipeline-edge-signatures-current-p
              (list edge)
              (list edge-signature edge-signature))))))

(deftest pipeline-run-cost-is-measurable-with-benchmark
  ;; cl-weave:benchmark measures wall-clock directly; per its own docstring
  ;; the result is "observational only" (unlike the hard-gating
  ;; :TO-RUN-UNDER-MS matcher used elsewhere in this suite), so this only
  ;; asserts the mechanism itself produces real samples, not a specific
  ;; millisecond threshold that would vary by machine.
  (with-linear-test-pipeline (graph pipeline source sink)
    (declare (ignore graph source sink))
    (let ((result (benchmark (:warmup 5 :samples 20)
                    (run-pipeline pipeline))))
      (assert-benchmark-samples result 20)
      (format t "~&  pipeline-run mean: ~,4Fms~%" (mean-ms result)))))

(it-property "linear offset pipelines produce the accumulated final value"
    ((initial (gen-integer :min -1000 :max 1000))
     (deltas (gen-list (gen-integer :min -50 :max 50)
                       :min-length 1
                       :max-length 25)))
  (with-linear-offset-pipeline (pipeline stages deltas)
    (let* ((context (run-pipeline-with-test-context pipeline :input initial))
           (last-stage (car (last stages)))
           (expected (reduce #'+ deltas :initial-value initial)))
      (is (= (context-result context) expected))
       (is (= (context-value context (node-name last-stage) "value") expected))
       (is (= (length (context-trace-in-order context)) (length deltas))))))
