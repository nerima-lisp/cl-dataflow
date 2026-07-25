(in-package #:cl-dataflow.test)

;;; Single-source operators whose whole contract is "given these inputs, emit
;;; these outputs" are specified declaratively: each line is
;;; (NAME BUILDER INPUTS EXPECTED). Operators needing side-effect checks,
;;; multiple sources, multiple outputs, or extra assertions keep their own
;;; DEFTEST below.

(define-single-source-subject-tests
  (subject-scan-emits-running-accumulations
   (lambda (s) (subject-scan s #'+ 0)) (1 2 3) (1 3 6))
  (subject-distinct-suppresses-repeats
   (lambda (s) (subject-distinct s)) (1 2 1 3 2 4) (1 2 3 4))
  (subject-take-limits-emissions
   (lambda (s) (subject-take s 2)) (10 20 30 40) (10 20))
  (subject-drop-skips-the-first-n
   (lambda (s) (subject-drop s 2)) (10 20 30 40) (30 40))
  ;; 1,2 pass; 3 fails and stops forever, so the later 1 is not re-emitted.
  (subject-take-while-stops-at-first-failure
   (lambda (s) (subject-take-while s (lambda (x) (< x 3)))) (1 2 3 1) (1 2))
  ;; 1,2 dropped; from 3 on everything is forwarded, including the later 1.
  (subject-drop-while-forwards-after-first-failure
   (lambda (s) (subject-drop-while s (lambda (x) (< x 3)))) (1 2 3 1) (3 1))
  (subject-count-emits-running-total
   (lambda (s) (subject-count s)) (:a :b :c) (1 2 3)))

(deftest
  subject-tap-observes-without-changing
  (let* ((source (make-subject))
          (seen '())
          (tapped
        (subject-tap
          source
          (lambda (v)
            (push v seen))))
          (collector (subject-collect tapped)))
    (dolist (value '(1 2 3))
      (subject-emit source value))
    (is (equal (funcall collector) '(1 2 3)))
    (is (equal (nreverse seen) '(1 2 3)))))

(deftest subject-zip-pairs-in-lockstep
  (let* ((a (make-subject))
          (b (make-subject))
          (zipped (subject-zip a b))
          (collector (subject-collect zipped)))
    (subject-emit a 1)     ; queued, b empty -> nothing yet
    (subject-emit a 2)     ; queued
    (subject-emit b 10)    ; pairs with 1
    (subject-emit b 20)    ; pairs with 2
    (subject-emit a 3)     ; verifies queues can be reused after draining
    (subject-emit b 30)
    (subject-emit b 40)    ; reverse-side queued
    (subject-emit a 4)
    (is (equal (funcall collector) '((1 . 10) (2 . 20) (3 . 30) (4 . 40))))))

(deftest subject-combine-latest-tracks-both
  (let* ((a (make-subject))
          (b (make-subject))
          (combined (subject-combine-latest a b))
          (collector (subject-collect combined)))
    (subject-emit a 1)     ; b not seen yet -> nothing
    (subject-emit b 10)    ; -> (1 . 10)
    (subject-emit a 2)     ; -> (2 . 10)
    (subject-emit b 20)    ; -> (2 . 20)
    (is (equal (funcall collector) '((1 . 10) (2 . 10) (2 . 20))))))

(deftest subject-buffer-groups-fixed-batches
  (let* ((source (make-subject))
          (batches (subject-buffer source 2))
          (collector (subject-collect batches)))
    (dolist (value '(1 2 3 4 5)) (subject-emit source value))
    ;; (1 2) and (3 4); the trailing 5 stays buffered.
    (is (equal (funcall collector) '((1 2) (3 4))))
    (signals invalid-input-error (subject-buffer source 0))))

(deftest subject-flat-map-forwards-inner-emissions
  (let* ((source (make-subject))
          (inner-a (make-subject))
          (inner-b (make-subject))
          (flattened (subject-flat-map source (lambda (v) (if (eq v :a) inner-a inner-b))))
          (collector (subject-collect flattened)))
    (subject-emit source :a)   ; subscribe to inner-a
    (subject-emit source :b)   ; subscribe to inner-b
    (subject-emit inner-a 1)
    (subject-emit inner-b 2)
    (subject-emit inner-a 3)
    (is (equal (funcall collector) '(1 2 3)))))

(deftest
  subject-partition-splits-by-predicate
  (let ((source (make-subject)))
    (multiple-value-bind (evens odds) (subject-partition source #'evenp)
      (let ((even-log (subject-collect evens))
            (odd-log (subject-collect odds)))
        (dolist (value '(1 2 3 4 5 6))
          (subject-emit source value))
        (is (equal (funcall even-log) '(2 4 6)))
        (is (equal (funcall odd-log) '(1 3 5)))))))

;;; --- DEFINE-SUBJECT-OPERATOR machinery -----------------------------------
;;; These test the DSL that generates the operators above directly, at test
;;; time, so every clause-parsing branch is exercised and observed (the real
;;; operator definitions expand at file-compile time, before coverage starts).

(deftest define-subject-operator-body-parser-splits-clauses
  (flet ((parse (body)
           (multiple-value-list (cl-dataflow::%parse-subject-operator-body body))))
    ;; docstring + :before + :state, in that order
    (is (equal (parse '("doc" (:before (guard n)) (:state (acc 0) (seen nil))
                        (emit value)))
               '(("doc") ((guard n)) ((acc 0) (seen nil)) ((emit value)))))
    ;; no docstring and no clauses: the whole body is the subscriber
    (is (equal (parse '((emit value)))
               '(() () () ((emit value)))))
    ;; :state only, no docstring
    (is (equal (parse '((:state (remaining n)) (emit value)))
               '(() () ((remaining n)) ((emit value)))))
    ;; empty body: nothing to split (guards the atom/exhausted-body branch)
    (is (equal (parse '())
               '(() () () ())))))

(deftest define-subject-operator-expands-to-a-defun
  (let ((expansion (macroexpand-1
                    '(cl-dataflow::define-subject-operator demo (source factor)
                      "Scale each value." (:state (total 0)) (emit (* value factor))))))
    (is (eq (first expansion) 'defun))
    (is (eq (second expansion) 'demo))
    (is (equal (third expansion) '(source factor)))
    (is (equal (fourth expansion) "Scale each value."))))

;;; SUBJECT-DISTINCT is hand-written (not a DEFINE-SUBJECT-OPERATOR form) so it
;;; can use a hash fast-path for standard test designators; these cover the
;;; fast path, the custom-predicate fallback, and the mutable-EQUAL fallback.

(deftest subject-distinct-accepts-standard-function-designators
  (dolist (test (list 'eql #'eql 'equalp #'equalp))
    (let* ((source (make-subject))
           (collector (subject-collect (subject-distinct source :test test))))
      (dolist (value (list 1 1.0 2 2.0))
        (subject-emit source value))
      (is (equal (funcall collector)
                 (if (member test (list 'equalp #'equalp) :test #'eq)
                     (list 1 2)
                     (list 1 1.0 2 2.0)))))))

(deftest subject-distinct-preserves-custom-test-exploration
  (let* ((calls '())
         (source (make-subject))
         (collector (subject-collect
                     (subject-distinct
                      source
                      :test (lambda (candidate existing)
                              (push (list candidate existing) calls)
                              (eql candidate existing))))))
    (dolist (value '(1 2 1))
      (subject-emit source value))
    (is (equal (funcall collector) '(1 2)))
    (is (equal (nreverse calls) '((2 1) (1 2) (1 1))))))

(deftest subject-distinct-retains-mutable-equal-semantics
  (let* ((value (copy-seq "a"))
         (source (make-subject))
         (collector (subject-collect (subject-distinct source :test 'equal))))
    (subject-emit source value)
    (setf (char value 0) #\b)
    (subject-emit source "a")
    (subject-emit source "b")
    (is (equal (funcall collector) (list "b" "a")))))
