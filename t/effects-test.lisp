(in-package #:cl-dataflow.test)

(deftest
  effect-performance-uses-handler
  (with-effect-handlers
    (handlers
      "log"
      (lambda (effect context)
        (declare (ignore context))
        (list :handled (effect-payload effect))))
    (let ((context (make-context :effect-handlers handlers)))
      (with-runtime-artifacts
        (effect
          history
          trace
          (first (context-effects context))
          (first (context-trace context)))
        (perform-effect context "log" :payload '(:message "ok"))
        (is (equal (effect-type effect) "log"))
        (is (equal (effect-result effect) '(:handled (:message "ok"))))
        (is (= (length (context-effects context)) 1))
        (is (equal (effect-type history) "log"))
        (assert-context-first-trace-entry
          context
          (:effect "log")
          (:payload '(:message "ok"))
          (:result '(:handled (:message "ok")))
          (:trace-index 0))))))

(deftest
  effect-construction-setter-and-perform-copy-payload-and-result
  (let* ((payload (list :message "ok"))
        (result (list :handled payload))
        (effect (make-effect "log" :payload payload :result result)))
    (setf (car payload) :mutated
          (car (cadr result)) :changed)
    (is (equal (effect-payload effect) '(:message "ok")))
    (is (equal (effect-result effect) '(:handled (:message "ok"))))
    (let ((replacement-payload (list :message "next"))
          (replacement-result (list :handled :next)))
      (setf (effect-payload effect) replacement-payload
            (effect-result effect) replacement-result)
      (setf (car replacement-payload) :changed
            (cadr replacement-result) :mutated)
      (is (equal (effect-payload effect) '(:message "next")))
      (is (equal (effect-result effect) '(:handled :next))))))

(deftest
  performed-effect-is-copied-into-context-history
  (let* ((returned (list :handled (list :message "ok"))))
    (with-effect-handlers
      (handlers
        "log"
        (lambda (effect context)
          (declare (ignore effect context))
          returned))
      (let ((context (make-context :effect-handlers handlers)))
        (let ((effect (perform-effect context "log" :payload (list :message "ok"))))
          (setf (car (cadr returned)) :changed)
          (setf (effect-result effect) (list :handled :updated))
          (is
            (equal
              (effect-result (first (context-effects context)))
              '(:handled (:message "ok"))))
          (is (equal (effect-result effect) '(:handled :updated)))
          (is
            (equal
              (effect-result (first (context-effects context)))
              '(:handled (:message "ok")))))))))

(deftest
  effect-trace-index-reflects-creation-order
  (let ((event nil)
        (inner nil)
        (pending-trace nil))
    (with-effect-handlers
      (handlers
        "inner"
        (lambda (effect context)
          (declare (ignore context))
          (effect-trace-index effect))
        "outer"
        (lambda (effect context)
          (declare (ignore effect))
          (setf pending-trace (first (context-trace context)))
          (setf event (emit-event context "nested-event"))
          (setf inner (perform-effect context "inner"))
          (list :outer (getf pending-trace :trace-index))))
      (let* ((context (make-context :effect-handlers handlers))
            (outer (perform-effect context "outer"))
            (trace (context-trace-in-order context)))
        (is (= (effect-trace-index outer) 0))
        (is (= (event-trace-index event) 1))
        (is (= (effect-trace-index inner) 2))
        (is (= (effect-trace-index (first (context-effects context))) 0))
        (is (equal (mapcar #'first trace) '(:effect :event :effect)))
        (is
          (equal
            (mapcar
              (lambda (entry)
                (getf entry :trace-index))
              trace)
            '(0 1 2)))
        (progn
          (is
            (loop for (key) on pending-trace by #'cddr
                  thereis (eq key :handled-p)))
          (is (null (getf pending-trace :handled-p))))
        (is (null (getf pending-trace :result)))
        (is
          (not
            (loop for (key) on (first trace) by #'cddr
                  thereis (eq key :handled-p))))
        (is (equal (getf (first trace) :result) '(:outer 0)))
        (is (= (cl-dataflow::%context-trace-count context) 3)))))
  (let ((context (make-context)))
    (register-effect-handler
      context
      "fail"
      (lambda (effect runtime-context)
        (declare (ignore effect runtime-context))
        (error "handler failed")))
    (signals simple-error (perform-effect context "fail"))
    (let ((trace (context-trace-in-order context)))
      (is (= (length trace) 1))
      (is (= (getf (first trace) :trace-index) 0))
      (progn
        (is
          (loop for (key) on (first trace) by #'cddr
                thereis (eq key :handled-p)))
        (is (null (getf (first trace) :handled-p))))
      (is (null (getf (first trace) :result)))
      (is (= (cl-dataflow::%context-trace-count context) 1)))))

(deftest
  effect-constructor-and-performer-support-empty-values-and_existing_trace
  (with-effect-handlers
    (handlers
      "log"
      (lambda (effect context)
        (declare (ignore context))
        (effect-payload effect)))
    (let* ((effect (make-effect "log"))
          (context
          (make-context :trace (list '(:event "seed")) :effect-handlers handlers))
          (performed (perform-effect context "log")))
      (is (null (effect-payload effect)))
      (is (null (effect-metadata effect)))
      (is (null (effect-result effect)))
      (is (= (effect-trace-index performed) 1))
      (is (= (effect-trace-index (first (context-effects context))) 1))
      (assert-context-first-trace-entry
        context
        (:effect "log")
        (:payload nil)
        (:result nil)
        (:trace-index 1)))))

(deftest
  perform-effect-copies-handler-result-into-trace
  (let* ((returned (list :handled (list :message "ok"))))
    (with-effect-handlers
      (handlers
        "log"
        (lambda (effect context)
          (declare (ignore effect context))
          returned))
      (let ((context (make-context :effect-handlers handlers)))
        (let ((effect (perform-effect context "log" :payload '(:message "ok"))))
          (setf (car (cadr returned)) :changed)
          (is (equal (effect-result effect) '(:handled (:message "ok"))))
          (assert-context-first-trace-entry context (:result '(:handled (:message "ok")))))))))

(deftest
  effect-metadata-history-and-trace-are-copied-on-perform
  (let* ((payload (list :message "ok"))
        (metadata (list (list :source "api")))
        (returned (list :handled payload)))
    (with-effect-handlers
      (handlers
        "log"
        (lambda (effect runtime-context)
          (declare (ignore effect runtime-context))
          returned))
      (let* ((context (make-context :effect-handlers handlers))
            (effect (perform-effect context "log" :payload payload :metadata metadata))
            (history (first (context-effects context))))
        (setf (cadr payload) "changed"
              (cadar metadata) "worker"
              (cadr (cadr returned)) "changed"
              (effect-payload effect) '(:message "next")
              (effect-result effect) '(:handled (:message "next"))
              (effect-metadata effect) '((:source "cli")))
        (is (equal (effect-payload history) '(:message "ok")))
        (is (equal (effect-metadata history) '((:source "api"))))
        (is (equal (effect-result history) '(:handled (:message "ok"))))
        (assert-context-first-trace-entry
          context
          (:effect "log")
          (:payload '(:message "ok"))
          (:result '(:handled (:message "ok")))
          (:trace-index 0))
        (is (equal (effect-payload effect) '(:message "next")))
        (is (equal (effect-result effect) '(:handled (:message "next"))))
        (is (equal (effect-metadata effect) '((:source "cli"))))))))

(deftest
  effect-handlers-normalize-keys-and-copy-input-table
  (with-effect-handlers
    (handlers
      'log
      (lambda (effect context)
        (declare (ignore context))
        (list :original (effect-payload effect))))
    (let ((context (make-context :effect-handlers handlers)))
      (setf (gethash 'log handlers) (lambda (effect context)
          (declare (ignore context))
          (list :mutated (effect-payload effect))))
      (let ((effect (perform-effect context "log" :payload '(:message "ok"))))
        (is (equal (effect-result effect) '(:original (:message "ok"))))
        (is
          (equal
            (funcall
              (gethash "log" (context-effect-handlers context))
              (make-effect "log" :payload '(:message "ok"))
              context)
            '(:original (:message "ok"))))
        (is (functionp (gethash "log" (context-effect-handlers context))))
        (is (not (functionp (gethash "mutated" (context-effect-handlers context))))))
      (with-effect-handlers
        (replacement
          'audit
          (lambda (effect context)
            (declare (ignore context))
            (list :audit (effect-payload effect))))
        (setf (context-effect-handlers context) replacement)
        (setf (gethash 'audit replacement) (lambda (effect context)
            (declare (ignore context))
            (list :mutated-audit (effect-payload effect))))
        (let ((audit-effect (perform-effect context :audit :payload '(:message "ok"))))
          (is (equal (effect-result audit-effect) '(:audit (:message "ok"))))
          (is (functionp (gethash "audit" (context-effect-handlers context))))
          (is
            (not (functionp (gethash "mutated-audit" (context-effect-handlers context))))))))))

(deftest
  missing-effect-handler-signals-error
  (let ((context (make-context)))
    (signals
      effect-handler-missing-error
      (perform-effect context "missing" :payload nil))))

(deftest
  missing-effect-handler-exposes-condition-data
  (let ((context (make-context)))
    (with-captured-condition
      (captured effect-handler-missing-error)
      (perform-effect context "missing" :payload nil)
      (is (equal (missing-effect-type captured) "missing"))
      (is (typep (effect-handler-missing-effect captured) 'effect))
      (is (equal (effect-type (effect-handler-missing-effect captured)) "missing"))
      (is (equal (effect-payload (effect-handler-missing-effect captured)) nil))
      (is
        (equal
          (effect-handler-missing-detail captured)
          "No effect handler registered for missing"))
      (assert-condition-report captured "No effect handler registered for missing"))))
