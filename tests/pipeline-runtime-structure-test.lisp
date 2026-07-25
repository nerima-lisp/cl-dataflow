(in-package #:cl-dataflow.test)

(defmacro assert-plan-rebuilds (pipeline &body mutation)
  "Capture PIPELINE's current execution plan, run MUTATION, force a rebuild,
and assert the rebuilt plan is a distinct object from the one captured
before MUTATION ran."
  (let ((plan (gensym "PLAN-")))
    `(let ((,plan (cl-dataflow::%pipeline-execution-plan ,pipeline)))
        ,@mutation
        (cl-dataflow::%ensure-pipeline-execution-plan ,pipeline)
        (is (not (eq ,plan (cl-dataflow::%pipeline-execution-plan ,pipeline)))))))

(deftest
  pipeline-constructor-and-setter-copy-stage-lists
  (let* ((stage-one (make-node "stage-one"))
          (stage-two (make-node "stage-two"))
          (stages (list stage-one stage-two))
          (pipeline (make-pipeline :stages stages)))
    (setf (car stages) (make-node "mutated"))
    (is
      (equal
        (mapcar #'node-name (pipeline-stages pipeline))
        '("stage-one" "stage-two")))
    (let* ((replacement (list stage-two stage-one))
            (replacement-copy (copy-list replacement)))
      (setf (pipeline-stages pipeline) replacement)
      (setf (car replacement) (make-node "changed"))
      (is
        (equal
          (mapcar #'node-name (pipeline-stages pipeline))
          '("stage-two" "stage-one")))
      (is (not (eq (pipeline-stages pipeline) replacement)))
      (is (equal replacement-copy (list stage-two stage-one))))))

(deftest
  pipeline-constructor-and-setter-copy-graphs
  (with-linear-test-pipeline
    (graph pipeline source sink :source-metadata '((:kind :stage)))
    (add-node graph (make-node "mutated"))
    (setf (node-metadata (find-node graph "source")) '((:kind :mutated)))
    (is (not (eq (pipeline-graph pipeline) graph)))
    (is (= (hash-table-count (graph-nodes (pipeline-graph pipeline))) 2))
    (is (= (length (graph-edges (pipeline-graph pipeline))) 1))
    (is
      (equal
        (node-metadata (find-node (pipeline-graph pipeline) "source"))
        '((:kind :stage))))
    (let* ((replacement (make-graph :metadata '((:kind :replacement))))
            (replacement-source (make-node "source"))
            (replacement-sink (make-node "sink")))
      (add-node replacement replacement-source)
      (add-node replacement replacement-sink)
      (add-edge replacement replacement-source replacement-sink)
      (setf (pipeline-graph pipeline) replacement)
      (is (not (eq (pipeline-graph pipeline) replacement)))
      (is (= (hash-table-count (graph-nodes (pipeline-graph pipeline))) 2))
      (is
        (eq
          (first (pipeline-stages pipeline))
          (find-node (pipeline-graph pipeline) "source")))
      (is
        (eq
          (second (pipeline-stages pipeline))
          (find-node (pipeline-graph pipeline) "sink")))
      (is (equal (graph-metadata (pipeline-graph pipeline)) '((:kind :replacement)))))))

(deftest
  pipeline-graph-setter-preserves-empty-stage-cache
  (let ((pipeline (make-pipeline)))
    (with-linear-test-pipeline
      (graph initialized-pipeline source sink)
      (setf (pipeline-graph pipeline) graph)
      (is (not (eq (pipeline-graph pipeline) graph)))
      (is (null (pipeline-stages pipeline)))
      (is (= (hash-table-count (graph-nodes (pipeline-graph pipeline))) 2))
      (is (not (eq initialized-pipeline pipeline))))))

(deftest
  pipeline-constructor-supports-empty-graph-and-stage-input
  (let ((pipeline (make-pipeline)))
    (is (null (pipeline-stages pipeline)))
    (is (= (hash-table-count (graph-nodes (pipeline-graph pipeline))) 0))
    (is (equal (graph-edges (pipeline-graph pipeline)) '()))))

(deftest
  pipeline-stages-setter-remaps-onto-live-graph
  (with-linear-test-pipeline
    (graph pipeline source sink)
    (let ((replacement (list (make-node "source") (make-node "sink"))))
      (setf (pipeline-stages pipeline) replacement)
      (setf (car replacement) (make-node "mutated"))
      (is
        (eq
          (first (pipeline-stages pipeline))
          (find-node (pipeline-graph pipeline) "source")))
      (is
        (eq
          (second (pipeline-stages pipeline))
          (find-node (pipeline-graph pipeline) "sink")))
      (is (equal (mapcar #'node-name (pipeline-stages pipeline)) '("source" "sink"))))))

(deftest
  pipeline-rejects-stale-stages-when-graph-cannot-resolve-them
  (with-linear-test-pipeline
    (graph pipeline source sink)
    (let ((orphan (make-node "orphan")))
      (with-captured-condition
        (condition node-not-found-error)
        (make-pipeline :graph graph :stages (list orphan))
        (is (not (eq (node-not-found-designator condition) orphan))))
      (with-captured-condition
        (condition node-not-found-error)
        (setf (pipeline-stages pipeline) (list orphan))
        (is (not (eq (node-not-found-designator condition) orphan)))))))

(deftest
  pipeline-constructor-remaps-stages-onto-copied-graph
  (with-linear-test-pipeline
    (graph pipeline source sink)
    (is (not (eq (pipeline-graph pipeline) graph)))
    (is (not (eq (first (pipeline-stages pipeline)) source)))
    (is (not (eq (second (pipeline-stages pipeline)) sink)))
    (is
      (eq
        (first (pipeline-stages pipeline))
        (find-node (pipeline-graph pipeline) "source")))
    (is
      (eq
        (second (pipeline-stages pipeline))
        (find-node (pipeline-graph pipeline) "sink")))))

(deftest
  pipeline-stages-return-independent-snapshots
  (let* ((stage-one (make-node "stage-one"))
          (stage-two (make-node "stage-two"))
          (pipeline (make-pipeline :stages (list stage-one stage-two)))
          (stages-snapshot (pipeline-stages pipeline)))
    (is (not (eq stages-snapshot (pipeline-stages pipeline))))
    (setf (car stages-snapshot) (make-node "mutated"))
    (is
      (equal
        (mapcar #'node-name (pipeline-stages pipeline))
        '("stage-one" "stage-two")))))

(deftest pipeline-sequential-graph-accepts-plist-stage-specs
  ;; %BUILD-SEQUENTIAL-GRAPH normalizes each stage through
  ;; %NORMALIZE-STAGE-SPEC, which accepts a NODE object as-is or builds one
  ;; from a plist; mixing both in one :STAGES list exercises both branches.
  (let* ((source (make-node "source"
                            :outputs '("value")
                            :handler (lambda (input context)
                                       (declare (ignore context))
                                       input)))
         (pipeline (make-pipeline
                    :stages (list source
                                  (list :name "sink"
                                        :inputs '("value")
                                        :handler (lambda (input context)
                                                   (declare (ignore context))
                                                   (1+ input)))))))
    (is (equal (mapcar #'node-name (pipeline-stages pipeline))
               '("source" "sink")))
    (is (= (length (graph-edges (pipeline-graph pipeline))) 1))))

(deftest copy-pipeline-produces-independent-pipeline
  (with-linear-test-pipeline (graph pipeline source sink
                                    :source-metadata '((:kind :source))
                                    :sink-metadata '((:kind :sink))
                                    :pipeline-metadata '((:pipeline :original)))
    (setf (graph-metadata (pipeline-graph pipeline)) '((:kind :original)))
    (let ((copy (copy-pipeline pipeline)))
      (is (not (eq copy pipeline)))
      (is (not (eq (pipeline-graph copy) (pipeline-graph pipeline))))
      (is
        (not (eq (first (pipeline-stages copy)) (first (pipeline-stages pipeline)))))
      (is
        (eq (first (pipeline-stages copy)) (find-node (pipeline-graph copy) "source")))
      (is
        (equal
          (mapcar #'node-name (pipeline-stages copy))
          (mapcar #'node-name (pipeline-stages pipeline))))
      (is (equal (pipeline-metadata copy) (pipeline-metadata pipeline)))
      (is (equal (graph-metadata (pipeline-graph copy)) '((:kind :original))))
      (is
        (equal
          (node-metadata (find-node (pipeline-graph copy) "source"))
          '((:kind :source))))
      (setf (pipeline-metadata copy) '((:pipeline :copy))
            (node-metadata (find-node (pipeline-graph copy) "source")) '((:kind :copy-source)))
      (add-node (pipeline-graph pipeline) (make-node "mutated"))
      (setf (node-metadata (find-node (pipeline-graph pipeline) "source")) '((:kind :mutated)))
      (is (equal (pipeline-metadata pipeline) '((:pipeline :original))))
      (is (equal (graph-metadata (pipeline-graph pipeline)) '((:kind :original))))
      (is
        (equal
          (node-metadata (find-node (pipeline-graph pipeline) "source"))
          '((:kind :mutated))))
      (is (= (hash-table-count (graph-nodes (pipeline-graph copy))) 2))
      (is (equal (graph-metadata (pipeline-graph copy)) '((:kind :original))))
      (is
        (equal
          (node-metadata (find-node (pipeline-graph copy) "source"))
          '((:kind :copy-source))))
      (is (equal (pipeline-metadata copy) '((:pipeline :copy)))))))

(deftest
  pipeline-rebuilds-plan-after-edge-collection-changes
  (with-linear-test-pipeline
    (graph pipeline source sink)
    (let* ((live-graph (pipeline-graph pipeline))
            (extra (make-node "extra")))
      (add-node live-graph extra)
      (assert-plan-rebuilds pipeline
        (add-edge live-graph sink extra))
      (assert-plan-rebuilds pipeline
        (remove-edge live-graph sink extra))
      (assert-plan-rebuilds pipeline
        (setf (graph-edges live-graph) (graph-edges live-graph))))))

(deftest
  pipeline-reuses-current-execution-plan
  (with-linear-test-pipeline
    (graph pipeline source sink)
    (let ((plan (cl-dataflow::%pipeline-execution-plan pipeline)))
      (run-pipeline pipeline)
      (is (eq plan (cl-dataflow::%pipeline-execution-plan pipeline)))
      (run-pipeline pipeline)
      (is (eq plan (cl-dataflow::%pipeline-execution-plan pipeline))))))

(deftest
  pipeline-plan-caches-sinks-in-stage-order-using-full-graph-edges
  (let* ((graph (make-graph))
          (first (make-node "first"))
          (second (make-node "second"))
          (outside (make-node "outside")))
    (dolist (node (list first second outside))
      (add-node graph node))
    (add-edge graph first outside)
    (let* ((pipeline (make-pipeline :graph graph :stages (list second first)))
            (plan (cl-dataflow::%pipeline-execution-plan pipeline))
            (stages (cl-dataflow::%pipeline-execution-plan-stages plan))
            (sinks (cl-dataflow::%pipeline-execution-plan-sinks plan)))
      (is (equal (mapcar #'node-name sinks) '("second")))
      (is (eq (first sinks) (first stages))))))

(deftest
  pipeline-plan-preserves-multiple-sink-result-order
  (let* ((graph (make-graph))
          (first
        (make-node
          "first"
          :handler
          (lambda (input context)
            (declare (ignore input context))
            1)))
          (second
        (make-node
          "second"
          :handler
          (lambda (input context)
            (declare (ignore input context))
            2))))
    (dolist (node (list first second))
      (add-node graph node))
    (let ((pipeline (make-pipeline :graph graph :stages (list second first))))
      (is
        (equal
          (run-pipeline pipeline)
          '(("second" ("value" . 2)) ("first" ("value" . 1))))))))

(deftest
  pipeline-rebuilds-cached-sinks-after-direct-edge-endpoint-mutation
  (let* ((graph (make-graph))
          (a
        (make-node
          "a"
          :handler
          (lambda (input context)
            (declare (ignore input context))
            1)))
          (c
        (make-node
          "c"
          :handler
          (lambda (input context)
            (declare (ignore input context))
            3)))
          (b
        (make-node
          "b"
          :handler
          (lambda (input context)
            (declare (ignore context))
            input))))
    (dolist (node (list a c b))
      (add-node graph node))
    (add-edge graph a b)
    (let* ((pipeline (make-pipeline :graph graph :stages (list a c b)))
            (live-graph (pipeline-graph pipeline))
            (edge (first (cl-dataflow::%graph-edges-list live-graph)))
            (old-plan (cl-dataflow::%pipeline-execution-plan pipeline)))
      (is (equal (run-pipeline pipeline) '(("c" ("value" . 3)) ("b" ("value" . 1)))))
      (setf (edge-from edge) "c")
      (is (equal (run-pipeline pipeline) '(("a" ("value" . 1)) ("b" ("value" . 3)))))
      (is (not (eq old-plan (cl-dataflow::%pipeline-execution-plan pipeline)))))))

(deftest
  pipeline-rebuilds-plan-after-live-edge-mutation
  (with-linear-test-pipeline
    (graph pipeline source sink)
    (let* ((live-graph (pipeline-graph pipeline))
            (extra (make-node "extra"))
            (alternate-source (make-node "Source")))
      (add-node live-graph extra)
      (add-node live-graph alternate-source)
      (let ((edge (add-edge live-graph sink extra)))
        (cl-dataflow::%ensure-pipeline-execution-plan pipeline)
        (assert-plan-rebuilds pipeline
          (setf (edge-from edge) "source"))
        (assert-plan-rebuilds pipeline
          (setf (edge-from-port edge) "changed-from-port"))
        (assert-plan-rebuilds pipeline
          (setf (edge-to edge) "source"))
        (assert-plan-rebuilds pipeline
          (setf (edge-to-port edge) "changed-to-port"))
        (setf (edge-from edge) "Source")
        (cl-dataflow::%ensure-pipeline-execution-plan pipeline)
        (assert-plan-rebuilds pipeline
          (setf (char (edge-from edge) 0) #\s))))))

(deftest
  pipeline-detects-renamed-live-stage
  (with-linear-test-pipeline
    (graph pipeline source sink)
    (setf (node-name (first (cl-dataflow::%pipeline-stages-list pipeline))) "renamed")
    (with-captured-condition
      (condition node-not-found-error)
      (cl-dataflow::%ensure-pipeline-execution-plan pipeline)
      (is (string= (node-name (node-not-found-designator condition)) "renamed")))))

(deftest
  pipeline-setter-and-copy-isolate-execution-plans
  (with-linear-test-pipeline
        (graph pipeline source sink)
        (let ((original-plan (cl-dataflow::%pipeline-execution-plan pipeline)))
          (setf (pipeline-stages pipeline) (pipeline-stages pipeline))
          (is (null (cl-dataflow::%pipeline-execution-plan pipeline)))
          (cl-dataflow::%ensure-pipeline-execution-plan pipeline)
          (is (not (eq original-plan (cl-dataflow::%pipeline-execution-plan pipeline))))
          (let ((copy (copy-pipeline pipeline)))
            (is
              (not
                (eq
                  (cl-dataflow::%pipeline-execution-plan pipeline)
                  (cl-dataflow::%pipeline-execution-plan copy))))
            (is
              (not
                (eq
                  (cl-dataflow::%pipeline-execution-plan-graph
                    (cl-dataflow::%pipeline-execution-plan pipeline))
                  (cl-dataflow::%pipeline-execution-plan-graph
                    (cl-dataflow::%pipeline-execution-plan copy)))))))))

(deftest
  pipeline-plan-caches-input-bindings-and-resolves-current-values
  (let* ((old-value 1)
          (new-value 2)
          (seen-input nil)
          (graph (make-graph))
          (old-source
        (make-node
          "old"
          :outputs
          '("right")
          :handler
          (lambda (input context)
            (declare (ignore input context))
            old-value)))
          (new-source
        (make-node
          "new"
          :outputs
          '("left")
          :handler
          (lambda (input context)
            (declare (ignore input context))
            new-value)))
          (sink
        (make-node
          "sink"
          :inputs
          '("right" "left")
          :handler
          (lambda (input context)
            (declare (ignore context))
            (setf seen-input input)
            input))))
    (dolist (node (list old-source new-source sink))
      (add-node graph node))
    (add-edge graph old-source sink :from-port "right" :to-port "left")
    (add-edge graph new-source sink :from-port "left" :to-port "left")
    (add-edge graph old-source sink :from-port "right" :to-port "right")
    (let* ((pipeline
          (make-pipeline :graph graph :stages (list old-source new-source sink)))
            (plan (cl-dataflow::%pipeline-execution-plan pipeline))
            (binding-plans (cl-dataflow::%pipeline-execution-plan-input-binding-plans plan))
            (sink-plan (cdr (third binding-plans)))
            (context (make-context)))
      (is (equal (first binding-plans) '(nil)))
      (is (equal (second binding-plans) '(nil)))
      (is (equal (mapcar #'car sink-plan) '("right" "left")))
      (is
        (equal
          (mapcar
            (lambda (binding)
              (edge-from (cdr binding)))
            sink-plan)
          '("old" "new")))
      (run-pipeline pipeline :input :pipeline-input :context context)
      (is (equal seen-input '(("right" . 1) ("left" . 2))))
      (setf old-value 10
            new-value 20)
      (run-pipeline pipeline :input :pipeline-input :context context)
      (is (eq plan (cl-dataflow::%pipeline-execution-plan pipeline)))
      (is (equal seen-input '(("right" . 10) ("left" . 20))))
      (let ((trace (context-trace-in-order context)))
        (is (eq (getf (fourth trace) :input) :pipeline-input))
        (is (equal (getf (car (last trace)) :input) seen-input)))))
  (let* ((source-value (list (cons "key" 42)))
        (seen-input :not-run)
        (graph (make-graph))
        (source
          (make-node
            "source"
            :handler
            (lambda (input context)
              (declare (ignore input context))
              source-value)))
        (sink
          (make-node
            "sink"
            :inputs
            '("declared")
            :handler
            (lambda (input context)
              (declare (ignore context))
              (setf seen-input input)
              input))))
    (add-node graph source)
    (add-node graph sink)
    (add-edge graph source sink :to-port "declared")
    (let* ((pipeline (make-pipeline :graph graph :stages (list source sink)))
            (original-plan (cl-dataflow::%pipeline-execution-plan pipeline))
            (live-edge (first (cl-dataflow::%graph-edges-list (pipeline-graph pipeline))))
            (context (make-context)))
      (run-pipeline pipeline :input :pipeline-input :context context)
      (is (eq seen-input (cl-dataflow::%read-value context source (edge-from-port live-edge))))
      (is (eq seen-input (getf (first (cl-dataflow::%context-trace-list context)) :input)))
      (setf source-value nil)
      (run-pipeline pipeline :input :pipeline-input :context context)
      (is (null seen-input))
      (setf (edge-to-port live-edge) "undeclared")
      (run-pipeline pipeline :input :pipeline-input)
      (is (not (eq original-plan (cl-dataflow::%pipeline-execution-plan pipeline))))
      (is (null seen-input)))))

(deftest
  pipeline-rebuilds-plan-after-node-inputs-setter
  (let* ((graph (make-graph))
        (seen-input :not-run)
        (source
        (make-node
          "source"
          :outputs
          '("value")
          :handler
          (lambda (input context)
            (declare (ignore input context))
            42)))
        (sink
        (make-node
          "sink"
          :inputs
          '("value")
          :handler
          (lambda (input context)
            (declare (ignore context))
            (setf seen-input input)
            input))))
    (add-node graph source)
    (add-node graph sink)
    (add-edge graph source sink :from-port "value" :to-port "value")
    (let* ((pipeline (make-pipeline :graph graph :stages (list source sink)))
          (old-plan (cl-dataflow::%pipeline-execution-plan pipeline)))
      (is (= (run-pipeline pipeline) 42))
      (is (= seen-input 42))
      (setf seen-input :not-run)
      (setf (node-inputs (find-node (pipeline-graph pipeline) "sink")) '("other"))
      (is (null (run-pipeline pipeline :input :pipeline-input)))
      (is (null seen-input))
      (is (not (eq old-plan (cl-dataflow::%pipeline-execution-plan pipeline)))))))

(deftest
  pipeline-rebuilds-plan-after-node-outputs-setter
  (let* ((graph (make-graph))
        (sink
        (make-node
          "sink"
          :outputs
          '("left")
          :handler
          (lambda (input context)
            (declare (ignore input context))
            '(("left" . 1) ("right" . 2))))))
    (add-node graph sink)
    (let* ((pipeline (make-pipeline :graph graph :stages (list sink)))
          (old-plan (cl-dataflow::%pipeline-execution-plan pipeline)))
      (is (= (run-pipeline pipeline) 1))
      (setf (node-outputs (find-node (pipeline-graph pipeline) "sink")) '("right"))
      (is (= (run-pipeline pipeline) 2))
      (is (not (eq old-plan (cl-dataflow::%pipeline-execution-plan pipeline)))))))

(deftest
  pipeline-rebuilds-plan-after-mutating-setter-port-string
  (let* ((graph (make-graph))
        (seen-input :not-run)
        (source
        (make-node
          "source"
          :outputs
          '("value")
          :handler
          (lambda (input context)
            (declare (ignore input context))
            42)))
        (sink
        (make-node
          "sink"
          :inputs
          '("value")
          :handler
          (lambda (input context)
            (declare (ignore context))
            (setf seen-input input)
            input))))
    (add-node graph source)
    (add-node graph sink)
    (add-edge graph source sink :from-port "value" :to-port "value")
    (let* ((pipeline (make-pipeline :graph graph :stages (list source sink)))
          (live-sink (find-node (pipeline-graph pipeline) "sink"))
          (port (copy-seq "value")))
      (setf (node-inputs live-sink) (list port))
      (let ((old-plan (cl-dataflow::%ensure-pipeline-execution-plan pipeline)))
        (is (= (run-pipeline pipeline) 42))
        (is (= seen-input 42))
        (setf seen-input :not-run)
        (setf (char port 0) #\x)
        (is (null (run-pipeline pipeline :input :pipeline-input)))
        (is (null seen-input))
        (is (not (eq old-plan (cl-dataflow::%pipeline-execution-plan pipeline))))))))
