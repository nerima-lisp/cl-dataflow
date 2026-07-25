(in-package #:cl-dataflow.test)

(defun %constant-effect-handler (value)
  (lambda (effect context)
    (declare (ignore effect context))
    value))

(deftest register-effect-handler-enables-perform-effect
  (let ((context (make-context)))
    (is (not (effect-handled-p context "log")))
    (register-effect-handler context "log" (%constant-effect-handler :logged))
    (is (effect-handled-p context "log"))
    (is (eq (effect-result (perform-effect context "log")) :logged))))

(deftest register-effect-handler-replaces-and-returns-handler
  (let* ((context (make-context))
         (second (%constant-effect-handler :second)))
    (register-effect-handler context "log" (%constant-effect-handler :first))
    (is (eq (register-effect-handler context "log" second) second))
    (is (eq (context-effect-handler context "log") second))))

(deftest effect-handler-keys-are-normalized
  (let ((context (make-context)))
    (register-effect-handler context :log (%constant-effect-handler :ok))
    ;; :Log, "LOG" and "log" all resolve to the same normalized key.
    (is (effect-handled-p context "log"))
    (is (effect-handled-p context :log))
    (is (effect-handled-p context "LOG"))
    (is (not (effect-handled-p context "other")))))

(deftest context-effect-handler-lookup-and-listing
  (let ((context (make-context)))
    (is (null (context-effect-handler context "missing")))
    (register-effect-handler context "metric" (%constant-effect-handler 1))
    (register-effect-handler context "log" (%constant-effect-handler 2))
    (is (equal (context-effect-handler-types context) '("log" "metric")))))

(deftest with-effect-handler-scope-scopes-registration
  (let ((context (make-context)))
    (with-effect-handler-scope (context ("log" (%constant-effect-handler :scoped)))
      (is (effect-handled-p context "log"))
      (is (eq (effect-result (perform-effect context "log")) :scoped)))
    ;; The handler is gone once the scope exits.
    (is (not (effect-handled-p context "log")))))

(deftest with-effect-handler-scope-restores-shadowed-handlers
  (let* ((context (make-context))
         (outer (%constant-effect-handler :outer))
         (inner (%constant-effect-handler :inner)))
    (register-effect-handler context "log" outer)
    (with-effect-handler-scope (context ("log" inner))
      (is (eq (context-effect-handler context "log") inner)))
    ;; The pre-existing handler is restored afterward.
    (is (eq (context-effect-handler context "log") outer))))

(deftest with-effect-handler-scope-restores-on-non-local-exit
  (let ((context (make-context)))
    (ignore-errors
      (with-effect-handler-scope (context ("log" (%constant-effect-handler :scoped)))
        (error "boom")))
    (is (not (effect-handled-p context "log")))))
