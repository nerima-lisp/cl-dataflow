(in-package #:cl-dataflow.test)

;;; --- Handler adapters ----------------------------------------------------

(deftest mapping-handler-adapts-a-unary-function
  (is (= (funcall (mapping-handler (lambda (x) (* x x))) 6 nil) 36)))

(deftest compose-handlers-threads-left-to-right
  (let ((wrapped (compose-handlers (lambda (i c) (declare (ignore c)) (+ i 1))
                                   (lambda (i c) (declare (ignore c)) (* i 10)))))
    (is (= (funcall wrapped 4 nil) 50)))
  ;; No handlers is the identity.
  (is (= (funcall (compose-handlers) 9 nil) 9)))

;;; --- Handler wrappers ----------------------------------------------------

(deftest retrying-handler-retries-until-success
  (let* ((calls 0)
         (handler (lambda (input context)
                    (declare (ignore context))
                    (incf calls)
                    (if (< calls 3) (error "boom") (* input 2))))
         (wrapped (retrying-handler handler :attempts 3)))
    (is (= (funcall wrapped 5 nil) 10))
    (is (= calls 3))))

(deftest retrying-handler-resignals-after-exhaustion
  (let* ((calls 0)
         (handler (lambda (input context)
                    (declare (ignore input context))
                    (incf calls)
                    (error "always")))
         (wrapped (retrying-handler handler :attempts 2)))
    (signals error (funcall wrapped 1 nil))
    (is (= calls 2))))

(deftest retrying-handler-does-not-retry-unmatched-conditions
  (let* ((calls 0)
         (handler (lambda (input context)
                    (declare (ignore input context))
                    (incf calls)
                    (error "plain")))
         ;; Only invalid-input-error is retryable; a simple error is not.
         (wrapped (retrying-handler handler
                                    :attempts 5
                                    :condition-type 'invalid-input-error)))
    (signals error (funcall wrapped 1 nil))
    (is (= calls 1))))

(deftest retrying-handler-rejects-non-positive-attempts
  (signals invalid-input-error
    (retrying-handler (lambda (i c) (declare (ignore c)) i) :attempts 0)))

(deftest fallback-handler-returns-value-on-error
  (let ((wrapped (fallback-handler (lambda (i c) (declare (ignore i c)) (error "x")) 42)))
    (is (= (funcall wrapped 1 nil) 42)))
  ;; No error means the real result flows through.
  (let ((wrapped (fallback-handler (lambda (i c) (declare (ignore c)) (* i 2)) 42)))
    (is (= (funcall wrapped 5 nil) 10))))

(deftest fallback-handler-calls-function-fallback-with-condition
  (let ((wrapped (fallback-handler
                  (lambda (i c) (declare (ignore i c)) (error "boom"))
                  (lambda (input context condition)
                    (declare (ignore context))
                    (list input (typep condition 'error))))))
    (is (equal (funcall wrapped 7 nil) '(7 t)))))

(deftest fallback-handler-propagates-unmatched-conditions
  ;; Only invalid-input-error is caught; a plain error must propagate.
  (let ((wrapped (fallback-handler
                  (lambda (i c) (declare (ignore i c)) (error "plain"))
                  :ignored
                  :condition-type 'invalid-input-error)))
    (signals error (funcall wrapped 1 nil))))

(deftest memoizing-handler-caches-by-key
  (let* ((calls 0)
         (wrapped (memoizing-handler (lambda (i c)
                                       (declare (ignore c))
                                       (incf calls)
                                       (* i i)))))
    (is (= (funcall wrapped 4 nil) 16))
    (is (= (funcall wrapped 4 nil) 16))
    (is (= calls 1))
    (is (= (funcall wrapped 5 nil) 25))
    (is (= calls 2))))

(deftest tapping-handler-observes-without-changing-output
  (let* ((seen nil)
         (wrapped (tapping-handler (lambda (i c) (declare (ignore c)) (* i 2))
                                   (lambda (input output context)
                                     (declare (ignore context))
                                     (setf seen (cons input output))))))
    (is (= (funcall wrapped 3 nil) 6))
    (is (equal seen '(3 . 6)))))

;;; --- Node wrappers -------------------------------------------------------

(deftest wrap-node-preserves-node-shape
  (let* ((base (make-node "n" :inputs '("a") :outputs '("b") :metadata '((:k :v))))
         (wrapped (wrap-node base (lambda (handler) handler))))
    (is (equal (node-name wrapped) "n"))
    (is (equal (node-inputs wrapped) '("a")))
    (is (equal (node-outputs wrapped) '("b")))
    (is (equal (node-metadata wrapped) '((:k :v))))
    (is (not (eq wrapped base)))))

(deftest node-with-fallback-recovers-in-a-pipeline
  (let* ((base (make-node "compute"
                          :handler (lambda (input context)
                                     (declare (ignore context))
                                     (if (evenp input) (* input 10) (error "odd")))))
         (pipeline (single-node-pipeline (node-with-fallback base -1))))
    (is (= (run-pipeline pipeline :input 4) 40))
    (is (= (run-pipeline pipeline :input 3) -1))))

(deftest node-with-memoization-avoids-recomputation
  (let* ((calls 0)
         (base (make-node "square"
                          :handler (lambda (input context)
                                     (declare (ignore context))
                                     (incf calls)
                                     (* input input))))
         (pipeline (single-node-pipeline (node-with-memoization base))))
    (is (= (run-pipeline pipeline :input 6) 36))
    (is (= (run-pipeline pipeline :input 6) 36))
    (is (= calls 1))))

(deftest node-with-retry-recovers-in-a-pipeline
  (let* ((calls 0)
         (base (make-node "fetch"
                          :handler (lambda (input context)
                                     (declare (ignore context))
                                     (incf calls)
                                     (if (< calls 2) (error "flaky") (* input 3)))))
         (pipeline (single-node-pipeline (node-with-retry base :attempts 4 :condition-type 'error))))
    (is (= (run-pipeline pipeline :input 5) 15))
    (is (= calls 2))))

(deftest node-with-tap-observes-pipeline-output
  (let* ((seen '())
         (base (make-node "double"
                          :handler (lambda (input context)
                                     (declare (ignore context))
                                     (* input 2))))
         (pipeline (single-node-pipeline
                    (node-with-tap base (lambda (input output context)
                                          (declare (ignore context))
                                          (push (cons input output) seen))))))
    (is (= (run-pipeline pipeline :input 8) 16))
    (is (equal seen '((8 . 16))))))

;;; --- Pipeline composition ------------------------------------------------

(deftest run-pipeline-sequence-threads-results-through-a-shared-context
  (let* ((double-graph (make-graph))
         (offset-graph (make-graph)))
    (add-node double-graph
              (make-node "double"
                         :handler (lambda (input context)
                                    (when (context-p context)
                                      (emit-event context "doubled"))
                                    (* input 2))))
    (add-node offset-graph
              (make-node "offset"
                         :handler (lambda (input context)
                                    (declare (ignore context))
                                    (+ input 100))))
    (let ((p1 (make-pipeline :graph double-graph))
          (p2 (make-pipeline :graph offset-graph)))
      (multiple-value-bind (result context)
          (run-pipeline-sequence (list p1 p2) :input 5)
        ;; (5 * 2) + 100
        (is (= result 110))
        (is (member "doubled" (context-event-types context) :test #'equal))))))

(deftest run-pipeline-sequence-of-nothing-returns-the-input
  (multiple-value-bind (result context) (run-pipeline-sequence '() :input 7)
    (is (= result 7))
    (is (context-p context))))
