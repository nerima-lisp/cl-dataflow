(in-package #:cl-dataflow.test)

(deftest pipeline-node-levels-groups-a-diamond-graph-by-dependency-depth
  ;; A -> B, A -> C, B -> D, C -> D: B and C share no dependency path, so they
  ;; must land in the same level; D depends on both, so it must land strictly
  ;; after them.
  (with-graph-fixture (graph ((a "a") (b "b") (c "c") (d "d"))
                        :edges ((a b) (a c) (b d) (c d)))
    (let* ((stages (topological-sort graph))
           (incoming-index (cl-dataflow::%incoming-edges-index graph))
           (levels (cl-dataflow::%pipeline-node-levels stages incoming-index)))
      (is (equal (mapcar (lambda (level) (mapcar #'node-name level)) levels)
                 '(("a") ("b" "c") ("d")))))))

(deftest pipeline-node-levels-of-an-empty-stage-list-is-empty
  (is (null (cl-dataflow::%pipeline-node-levels '() (cl-dataflow::%make-result-table)))))

(deftest pipeline-parallel-matches-sequential-result-for-a-fan-out-level
  ;; LEFT and RIGHT are both sinks (neither has an outgoing edge), so
  ;; RUN-PIPELINE returns a list of (name . outputs) entries, not a scalar --
  ;; hence EQUAL, not =.
  (with-branching-test-pipeline (graph pipeline source left right)
    (let ((sequential (run-pipeline pipeline :input 5))
          (parallel (run-pipeline pipeline :input 5 :parallel t)))
      (is (equal sequential parallel)))))

(deftest pipeline-parallel-matches-sequential-context-values-for-a-fan-out-level
  (with-branching-test-pipeline (graph pipeline source left right)
    (let ((sequential-context (run-pipeline-with-test-context pipeline :input 5)))
      (multiple-value-bind (result parallel-context)
          (run-pipeline-with-context pipeline :input 5 :parallel t)
        (declare (ignore result))
        (is (= (context-value sequential-context left) (context-value parallel-context left)))
        (is (= (context-value sequential-context right) (context-value parallel-context right)))))))

(deftest pipeline-parallel-single-node-levels-match-sequential-linear-run
  (with-linear-test-pipeline (graph pipeline source sink
                               :sink-handler (lambda (input context)
                                               (declare (ignore context))
                                               (1+ input))
                               :source-handler (lambda (input context)
                                                 (declare (ignore input context))
                                                 41))
    (is (= (run-pipeline pipeline) 42))
    (is (= (run-pipeline pipeline :parallel t) 42))))

(deftest pipeline-parallel-runs-independent-handlers-concurrently
  ;; Each of LEFT/RIGHT records its own start time under a lock (protecting the
  ;; shared list, not the claim under test) before sleeping; if they really ran
  ;; concurrently, both start times land within a fraction of the sleep
  ;; duration of each other instead of one waiting for the other to finish.
  (let ((lock (cl-concurrent-kit:make-lock :name "test"))
        (start-times '())
        (sleep-seconds 0.2))
    (flet ((record-start-and-sleep (input context)
             (declare (ignore context))
             (cl-concurrent-kit:with-lock-held (lock)
               (push (get-internal-real-time) start-times))
             (sleep sleep-seconds)
             input))
      (with-branching-test-pipeline
          (graph pipeline source left right
           :left-handler #'record-start-and-sleep
           :right-handler #'record-start-and-sleep)
        (run-pipeline pipeline :input 1 :parallel t)
        (is (= (length start-times) 2))
        (let ((gap-seconds
              (/ (abs (- (first start-times) (second start-times)))
                 internal-time-units-per-second)))
          (is (< gap-seconds sleep-seconds)))))))

(deftest pipeline-parallel-benchmarked-fan-out-is-faster-than-sequential
  ;; cl-weave:benchmark measures wall-clock directly; per its own docstring the
  ;; result is "observational only", so this only asserts the relative
  ;; comparison (parallel faster than sequential for the SAME slow, genuinely
  ;; independent fan-out pipeline, measured in the same run/process so both
  ;; share ambient machine noise) rather than an absolute millisecond
  ;; threshold that would vary by machine.
  (flet ((slow-offset (offset)
           (lambda (input context)
             (declare (ignore context))
             (sleep 0.05)
             (+ input offset))))
    (with-branching-test-pipeline
        (graph pipeline source left right
         :left-handler (slow-offset 1)
         :right-handler (slow-offset 2))
      (let ((sequential (benchmark (:warmup 1 :samples 5)
                          (run-pipeline pipeline :input 1)))
            (parallel (benchmark (:warmup 1 :samples 5)
                        (run-pipeline pipeline :input 1 :parallel t))))
        (is (< (mean-ms parallel) (mean-ms sequential)))))))

(deftest pipeline-parallel-serializes-concurrent-emit-event-and-perform-effect
  (with-effect-handlers (handlers "audit" (lambda (effect context)
                                             (declare (ignore effect context))
                                             :handled))
    (flet ((emit-and-perform (input context)
             (declare (ignore input))
             (emit-event context "observed")
             (perform-effect context "audit")
             :done))
      (with-branching-test-pipeline
          (graph pipeline source left right
           :left-handler #'emit-and-perform
           :right-handler #'emit-and-perform)
        (let ((context (make-context :effect-handlers handlers)))
          (run-pipeline pipeline :input 1 :context context :parallel t)
          (is (= (length (context-events context)) 2))
          (is (= (length (context-effects context)) 2))
          (is (every (lambda (effect) (eq (effect-result effect) :handled))
                     (context-effects context))))))))

(deftest pipeline-parallel-reuses-an-already-installed-context-lock
  ;; A second :PARALLEL run against the same context must not replace its
  ;; already-installed lock -- exercises %ENSURE-CONTEXT-LOCK's idempotent
  ;; branch directly, not just its first-install branch.
  (with-branching-test-pipeline (graph pipeline source left right)
    (let ((context (make-context)))
      (run-pipeline pipeline :input 1 :context context :parallel t)
      (let ((installed-lock (slot-value context 'cl-dataflow::lock)))
        (is (not (null installed-lock)))
        (run-pipeline pipeline :input 2 :context context :parallel t)
        (is (eq installed-lock (slot-value context 'cl-dataflow::lock)))))))

(deftest pipeline-parallel-propagates-a-handler-error-like-sequential-does
  (with-branching-test-pipeline
      (graph pipeline source left right
       :left-handler (lambda (input context)
                       (declare (ignore input context))
                       (error "expected failure")))
    (signals simple-error (run-pipeline pipeline :input 1 :parallel t))))

(deftest pipeline-run-pipeline-times-and-until-fixpoint-thread-parallel-through
  (with-linear-test-pipeline (graph pipeline source sink
                               :sink-handler (lambda (input context)
                                               (declare (ignore context))
                                               (1+ input)))
    (is (= (run-pipeline-times pipeline 3 :input 0 :parallel t) 3))
    (is (= (run-pipeline-until-fixpoint pipeline :input 0 :max-iterations 5 :parallel t)
           5))))
