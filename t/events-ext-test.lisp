(in-package #:cl-dataflow.test)

(deftest emit-events-emits-a-batch
  (let ((context (make-context)))
    (emit-events context (list '(:started :payload 1) :ticked))
    (is (equal (context-event-types context) '("STARTED" "TICKED")))
    (is (= (event-payload (first (context-events-of-type context :started))) 1))))

(deftest event-of-type-p-matches-normalized-types
  (let ((event (make-event :ready)))
    (is (event-of-type-p event :ready))
    (is (event-of-type-p event "ready"))
    (is (not (event-of-type-p event :other)))))

(deftest perform-effects-runs-a-batch-and-collects-results
  (let ((context (make-context)))
    (register-effect-handler context "double"
                             (lambda (effect ctx)
                               (declare (ignore ctx))
                               (* 2 (effect-payload effect))))
    (register-effect-handler context "noop"
                             (lambda (effect ctx) (declare (ignore effect ctx)) :ok))
    (perform-effects context (list '(:double :payload 5) :noop))
    (is (equal (context-effect-types context) '("DOUBLE" "NOOP")))
    (is (equal (context-effect-results context) '(10 :ok)))
    (is (equal (context-effect-results-of-type context :double) '(10)))))

(deftest effect-of-type-p-matches-normalized-types
  (let ((effect (make-effect :write)))
    (is (effect-of-type-p effect :write))
    (is (effect-of-type-p effect "write"))
    (is (not (effect-of-type-p effect :read)))))
