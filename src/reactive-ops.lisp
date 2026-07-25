(in-package #:cl-dataflow)

;;;; Stateful and combining operators over reactive subjects, bringing the
;;;; push-based side toward parity with the pull-based stream operators. Each
;;;; returns a derived subject that subscribes to its source(s) and re-emits;
;;;; per-operator state lives in the closure. Everything is synchronous, so an
;;;; emission propagates through the whole derived graph before EMIT returns.

(define-subject-operator subject-scan (subject function seed)
  "Return a derived subject that emits a running accumulation: starting from SEED,
each source value V produces and emits (FUNCALL FUNCTION ACCUMULATOR V)."
  (:state (accumulator seed))
  (setf accumulator (funcall function accumulator value))
  (emit accumulator))

(defun subject-distinct (subject &key (test 'equal))
  "Return a derived subject that re-emits only the first occurrence of each value
(per TEST). Standard test designators use hash lookup where equality is
mutation-stable; custom predicates and structural EQUAL/EQUALP values retain
O(n) MEMBER semantics. Hand-written rather than a DEFINE-SUBJECT-OPERATOR form
so the hash fast-path can hold its own membership state."
  (let* ((result (make-subject))
         (standard-test (%standard-distinct-test test))
         (hashed-seen (and standard-test (make-hash-table :test standard-test)))
         (seen '()))
    (subject-subscribe
     subject
     (lambda (value)
       (let ((hashable (%distinct-hashable-value-p standard-test value)))
         (if hashable
             (multiple-value-bind (present-value present-p) (gethash value hashed-seen)
               (declare (ignore present-value))
               (unless present-p
                 (setf (gethash value hashed-seen) t)
                 (subject-emit result value)))
             (unless (member value seen :test test)
               (push value seen)
               (subject-emit result value))))))
    result))

(define-subject-operator subject-tap (subject function)
  "Return a derived subject that calls FUNCTION on each source value for its side
effect, then re-emits the value unchanged."
  (funcall function value)
  (emit value))

(define-subject-operator subject-take (subject n)
  "Return a derived subject that re-emits only the first N values of SUBJECT and
ignores the rest."
  (:state (remaining n))
  (when (plusp remaining)
    (decf remaining)
    (emit value)))

(defun subject-zip (subject-a subject-b)
  "Return a derived subject that pairs values of SUBJECT-A and SUBJECT-B in
lockstep, emitting (A . B) once the Nth value of each has arrived. Values queue
until their counterpart arrives."
  (let ((result (make-subject)))
    (with-fifo-queue (queue-a enqueue-a)
      (with-fifo-queue (queue-b enqueue-b)
        (flet ((emit-if-ready ()
                 (when (and queue-a queue-b)
                   (let ((value-a (first queue-a))
                         (value-b (first queue-b)))
                     (setf queue-a (rest queue-a)
                           queue-b (rest queue-b))
                     (subject-emit result (cons value-a value-b))))))
          (subject-subscribe
            subject-a
            (lambda (value)
              (enqueue-a value)
              (emit-if-ready)))
          (subject-subscribe
            subject-b
            (lambda (value)
              (enqueue-b value)
              (emit-if-ready))))))
    result))

(defun subject-combine-latest (subject-a subject-b)
  "Return a derived subject that emits (LATEST-A . LATEST-B) whenever either source
emits, once both have emitted at least once."
  (let ((result (make-subject))
        (latest-a nil)
        (has-a nil)
        (latest-b nil)
        (has-b nil))
    (flet ((emit-combined ()
              (when (and has-a has-b)
            (subject-emit result (cons latest-a latest-b)))))
      (subject-subscribe
        subject-a
        (lambda (value)
          (setf latest-a value
                has-a t)
          (emit-combined)))
      (subject-subscribe
        subject-b
        (lambda (value)
          (setf latest-b value
                has-b t)
          (emit-combined))))
    result))

(define-subject-operator subject-buffer (subject n)
  "Return a derived subject that collects every N source values into a list and
emits that list. A trailing partial buffer is not emitted. N must be positive."
  (:before (%positive-size n "SUBJECT-BUFFER"))
  (:state (buffer '()) (count 0))
  (push value buffer)
  (incf count)
  (when (= count n)
    (emit (reverse buffer))
    (setf buffer '() count 0)))

(define-subject-operator subject-drop (subject n)
  "Return a derived subject that ignores the first N source values and re-emits the
rest. The push-side dual of STREAM-DROP."
  (:state (remaining n))
  (if (plusp remaining)
      (decf remaining)
      (emit value)))

(define-subject-operator subject-take-while (subject predicate)
  "Return a derived subject that re-emits the leading run of source values
satisfying PREDICATE and permanently stops at (and excluding) the first that does
not."
  (:state (active t))
  (when active
    (if (funcall predicate value)
        (emit value)
        (setf active nil))))

(define-subject-operator subject-drop-while (subject predicate)
  "Return a derived subject that drops the leading run of source values satisfying
PREDICATE, then re-emits every value from the first that does not onward."
  (:state (dropping t))
  (unless (and dropping (funcall predicate value))
    (setf dropping nil)
    (emit value)))

(define-subject-operator subject-flat-map (subject function)
  "Return a derived subject that, for each value V of SUBJECT, calls FUNCTION to
obtain an inner subject and forwards all of that inner subject's later emissions.
The higher-order (flatten) reactive operator."
  (subject-subscribe (funcall function value)
                     (lambda (inner-value) (emit inner-value))))

(defun subject-partition (subject predicate)
  "Return (VALUES MATCHING NON-MATCHING): two derived subjects that split SUBJECT's
values by PREDICATE -- each value is emitted on MATCHING when PREDICATE holds, and
on NON-MATCHING otherwise."
  (let ((matching (make-subject))
        (non-matching (make-subject)))
    (subject-subscribe
      subject
      (lambda (value)
        (if (funcall predicate value) (subject-emit matching value)
          (subject-emit non-matching value))))
    (values matching non-matching)))

(define-subject-operator subject-count (subject)
  "Return a derived subject that emits the running count of source emissions
(1, 2, 3, ...)."
  (:state (count 0))
  (declare (ignore value))
  (incf count)
  (emit count))
