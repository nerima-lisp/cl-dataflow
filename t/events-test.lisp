(in-package #:cl-dataflow.test)

(deftest event-emission-updates-context
  (let ((context (make-context)))
    (with-runtime-artifacts (event history trace
                                  (first (context-events context))
                                  (first (context-trace context)))
        (emit-event context "user.created" :payload '(:id 1))
      (is (equal (event-type event) "user.created"))
      (is (equal (event-payload event) '(:id 1)))
      (is (= (event-trace-index event) 0))
      (is (= (length (context-events context)) 1))
      (is (equal (event-type history) "user.created"))
      (assert-context-first-trace-entry context
        (:event "user.created")
        (:payload '(:id 1))
        (:trace-index 0)))))

(deftest event-construction-and-setter-copy-payload
  (let* ((payload (list :id 1))
         (event (make-event "user.created" :payload payload))
         (replacement (list :id 2)))
    (setf (car payload) :mutated)
    (is (equal (event-payload event) '(:id 1)))
    (setf (event-payload event) replacement)
    (setf (car replacement) :changed)
    (is (equal (event-payload event) '(:id 2)))))

(deftest emitted-event-is-copied-into-context-history
  (let ((context (make-context)))
    (let* ((payload (list :id 1))
           (event (emit-event context "user.created" :payload payload)))
      (setf (car payload) :mutated)
      (setf (event-payload event) (list :id 2))
      (is (equal (event-payload (first (context-events context))) '(:id 1)))
      (is (equal (event-payload event) '(:id 2)))
      (is (equal (event-payload (first (context-events context))) '(:id 1))))))

(deftest event-metadata-and-trace-entries-are-copied-on-emission
  (let* ((context (make-context))
         (payload (list :id 1))
         (metadata (list (list :source "api"))))
    (with-runtime-artifacts (event history trace
                                  (first (context-events context))
                                  (first (context-trace context)))
        (emit-event context "user.created"
                    :payload payload
                    :metadata metadata)
      (setf (cadr payload) 2
            (cadar metadata) "worker"
            (event-payload event) '(:id 3)
            (event-metadata event) '((:source "cli")))
      (is (equal (event-payload history) '(:id 1)))
      (is (equal (event-metadata history) '((:source "api"))))
      (assert-context-first-trace-entry context
        (:event "user.created")
        (:payload '(:id 1))
        (:trace-index 0))
      (is (equal (event-payload event) '(:id 3)))
      (is (equal (event-metadata event) '((:source "cli"))))
      (is (equal (event-payload (first (context-events context))) '(:id 1)))
      (is (equal (event-metadata (first (context-events context)))
                 '((:source "api")))))))

(deftest event-constructor-and-emitter-support-empty-payload-and-existing-trace
  (let* ((event (make-event "user.created"))
         (context (make-context :trace (list '(:effect "seed"))))
         (emitted (emit-event context "user.created")))
    (is (null (event-payload event)))
    (is (null (event-metadata event)))
    (is (= (event-trace-index emitted) 1))
    (is (= (event-trace-index (first (context-events context))) 1))
    (assert-context-first-trace-entry context
      (:event "user.created")
      (:payload nil)
      (:trace-index 1))))
