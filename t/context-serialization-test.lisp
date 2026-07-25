(in-package #:cl-dataflow.test)

(deftest event-and-effect-plist-round-trip
  (let* ((event (make-event :ready :payload 42 :metadata '((:k :v)) :trace-index 3))
         (event-plist (event-to-plist event))
         (rebuilt (plist-to-event event-plist)))
    (is (equal (getf event-plist :type) "READY"))
    (is (= (getf event-plist :payload) 42))
    (is (= (event-trace-index rebuilt) 3))
    (is (equal (event-to-plist rebuilt) event-plist)))
  (let* ((effect (make-effect :write :payload "x" :result :done :trace-index 1))
         (effect-plist (effect-to-plist effect))
         (rebuilt (plist-to-effect effect-plist)))
    (is (equal (getf effect-plist :result) :done))
    (is (equal (effect-to-plist rebuilt) effect-plist))))

(deftest context-to-plist-captures-observable-state
  (let ((context (make-context :metadata '((:run 1)) :state :final)))
    (register-effect-handler context "log"
                             (lambda (effect ctx) (declare (ignore effect ctx)) :ok))
    (emit-event context :started :payload 7)
    (perform-effect context "log")
    (let ((plist (context-to-plist context)))
      (is (equal (getf plist :state) :final))
      (is (equal (getf plist :metadata) '((:run 1))))
      (is (= (length (getf plist :events)) 1))
      (is (= (length (getf plist :effects)) 1))
      (is (= (length (getf plist :trace)) 2)))))

(deftest plist-to-context-round-trips-a-run
  (let ((context (make-context :state :done)))
    (register-effect-handler context "log"
                             (lambda (effect ctx) (declare (ignore effect ctx)) :logged))
    (emit-event context :a :payload 1)
    (emit-event context :b :payload 2)
    (perform-effect context "log")
    (let ((rebuilt (plist-to-context (context-to-plist context))))
      (is (equal (context-event-types rebuilt) '("A" "B")))
      (is (equal (context-effect-results rebuilt) '(:logged)))
      (is (equal (context-state rebuilt) :done))
      ;; The rebuilt context serialises identically (handlers excluded either way).
      (is (equal (context-to-plist rebuilt) (context-to-plist context))))))

(deftest context-to-plist-serializes-stored-node-values
  (let ((graph (make-graph)))
    (add-node graph (make-node "double"
                               :handler (mapping-handler (lambda (x) (* x 2)))))
    (multiple-value-bind (result context)
        (run-pipeline-with-context (make-pipeline :graph graph) :input 5)
      (declare (ignore result))
      (let ((rebuilt (plist-to-context (context-to-plist context))))
        (is (= (context-value rebuilt "double") 10))))))
