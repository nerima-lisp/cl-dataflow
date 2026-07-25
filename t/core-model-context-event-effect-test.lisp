(in-package #:cl-dataflow.test)

(defmacro define-copy-rejects-non-value-test (name call expected-type invalid-value)
  `(deftest ,name
     (let ((captured
             (capture-condition (condition invalid-input-error)
               ,call)))
       (is captured)
       (is (equal (invalid-input-expected captured) ,expected-type))
       (is (equal (invalid-input-value captured) ,invalid-value)))))

(deftest context-result-setter-copies-mutable-values
  (let* ((context (make-context))
         (result (list (list :sink 1))))
    (setf (context-result context) result)
    (setf (cadar result) 2)
    (is (equal (context-result context) '((:sink 1))))))

(deftest context-result-accessor-returns-independent-copy
  (let* ((context (make-context :result '((:sink 1))))
         (result (context-result context)))
    (setf (cadar result) 2)
    (is (equal (context-result context) '((:sink 1))))))

(deftest copy-context-produces-independent-context
  (let* ((values (make-test-table "count" (list 1 2)))
         (events (list (make-event "boot" :payload '(:id 1))))
         (effects (list (make-effect "audit" :payload '(:message "ok")
                                     :result '(:handled (:message "ok")))))
         (trace (list (list :event "boot" :payload (list :id 1))))
         (handlers (make-test-effect-handlers
                    "log" (lambda (effect context)
                            (declare (ignore effect context))
                            :ok)))
         (context (make-context :values values
                                :events events
                                :effects effects
                                :trace trace
                                :effect-handlers handlers
                                 :metadata '((:kind :original))
                                 :result '((:status :ok))
                                 :state "idle")))
    (with-copy-isolation (copy context (copy-context context))
      (is (= (hash-table-count (context-values copy)) 1))
      (is (equal (gethash "count" (context-values copy)) '(1 2)))
      (is (= (length (context-events copy)) 1))
      (is (= (length (context-effects copy)) 1))
      (is (equal (event-type (first (context-events copy))) "boot"))
      (is (equal (effect-type (first (context-effects copy))) "audit"))
      (is (equal (context-trace copy) (context-trace context)))
      (is (equal (context-metadata copy) (context-metadata context)))
      (is (equal (context-result copy) (context-result context)))
      (is (string= (context-state copy) "idle"))
      (is (not (eq (first (context-events copy))
                   (first (context-events context)))))
      (is (not (eq (first (context-effects copy))
                   (first (context-effects context)))))
      (is (not (eq (first (context-trace copy))
                   (first (context-trace context)))))
      (let ((updated-values (context-values copy)))
        (setf (gethash "count" updated-values) '(:changed)
              (context-values copy) updated-values))
      (setf (context-events copy) (list (make-event "changed"))
            (context-effects copy) (list (make-effect "changed"))
            (context-trace copy) (list '(:event "changed"))
            (context-metadata copy) '((:kind :copy))
            (context-result copy) '((:status :changed))
            (context-state copy) "running")
      (setf (gethash "log" (context-effect-handlers copy))
            (lambda (effect context)
              (declare (ignore effect context))
              :changed))
      (is (equal (gethash "count" (context-values context)) '(1 2)))
      (is (equal (event-type (first (context-events context))) "boot"))
      (is (equal (effect-type (first (context-effects context))) "audit"))
      (is (equal (first (context-trace context))
                 '(:event "boot" :payload (:id 1))))
      (is (equal (context-metadata context) '((:kind :original))))
      (is (equal (context-result context) '((:status :ok))))
      (is (string= (context-state context) "idle"))
      (is (equal (funcall (gethash "log" (context-effect-handlers context))
                          (make-effect "log")
                          context)
                 :ok)))))

(deftest copy-event-produces-independent-event
  (let* ((event (make-event "boot" :payload (list :id 1)
                            :metadata '((:kind :event))))
         (replacement (list :id 2)))
    (with-copy-isolation (copy event (copy-event event))
      (is (equal (event-payload copy) '(:id 1)))
      (is (equal (event-metadata copy) '((:kind :event))))
      (setf (event-payload copy) replacement
            (event-metadata copy) '((:kind :copy)))
      (setf (car replacement) :changed)
      (is (equal (event-payload event) '(:id 1)))
      (is (equal (event-metadata event) '((:kind :event)))))))

(deftest event-accessors-return-independent-snapshots
  (let* ((event (make-event "boot"
                            :payload (list :id 1)
                            :metadata '((:kind :event))))
         (payload-snapshot (event-payload event))
         (metadata-snapshot (event-metadata event)))
    (setf (cadr payload-snapshot) "mutated"
          (cadr (first metadata-snapshot)) :changed)
    (is (equal (event-payload event) '(:id 1)))
    (is (equal (event-metadata event) '((:kind :event))))))

(define-copy-rejects-non-value-test copy-event-rejects-non-event-values (copy-event 'not-an-event) 'event 'not-an-event)

(deftest copy-effect-produces-independent-effect
  (let* ((effect (make-effect "audit"
                              :payload (list :message "ok")
                              :metadata '((:kind :effect))
                              :result (list :handled (list :message "ok"))))
         (replacement-payload (list :message "next"))
         (replacement-result (list :handled (list :message "next"))))
    (with-copy-isolation (copy effect (copy-effect effect))
      (is (equal (effect-payload copy) '(:message "ok")))
      (is (equal (effect-metadata copy) '((:kind :effect))))
      (is (equal (effect-result copy) '(:handled (:message "ok"))))
      (setf (effect-payload copy) replacement-payload
            (effect-result copy) replacement-result
            (effect-metadata copy) '((:kind :copy)))
      (setf (car replacement-payload) :changed
            (car (cadr replacement-result)) :changed)
      (is (equal (effect-payload effect) '(:message "ok")))
      (is (equal (effect-result effect) '(:handled (:message "ok"))))
      (is (equal (effect-metadata effect) '((:kind :effect)))))))

(deftest effect-accessors-return-independent-snapshots
  (let* ((effect (make-effect "audit"
                              :payload (list :message "ok")
                              :metadata '((:kind :effect))
                              :result (list :handled (list :message "ok"))))
         (payload-snapshot (effect-payload effect))
         (metadata-snapshot (effect-metadata effect))
         (result-snapshot (effect-result effect)))
    (setf (cadr payload-snapshot) "mutated"
          (cadr (first metadata-snapshot)) :changed
          (cadr (second result-snapshot)) "mutated")
    (is (equal (effect-payload effect) '(:message "ok")))
    (is (equal (effect-metadata effect) '((:kind :effect))))
    (is (equal (effect-result effect) '(:handled (:message "ok"))))))

(define-copy-rejects-non-value-test copy-effect-rejects-non-effect-values (copy-effect 'not-an-effect) 'effect 'not-an-effect)
