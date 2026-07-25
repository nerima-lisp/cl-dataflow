(in-package #:cl-dataflow)

;;;; Synchronous push-based reactive subjects -- the producer-driven dual of the
;;;; consumer-driven FLOW-STREAM. A SUBJECT holds an ordered list of subscriber
;;;; functions; SUBJECT-EMIT pushes a value to each of them, immediately and in
;;;; subscription order (no threads, fully deterministic). Derived subjects
;;;; (map/filter/merge) subscribe to their sources and re-emit, so a small reactive
;;;; graph can be wired up for event-driven workflows. The SUBJECT type is opaque;
;;;; use SUBJECT-P and the operators below.
(defstruct (subject (:constructor %make-subject ()) (:copier nil) (:predicate subject-p)) (subscribers '())
  (subscriber-tail nil))

(defun make-subject ()
  "Return a fresh subject with no subscribers."
  (%make-subject))

(defun subject-subscribe (subject function)
  "Register FUNCTION (called with each emitted value) as a subscriber of SUBJECT,
after any existing subscribers, and return FUNCTION (usable as an unsubscribe
token)."
  (let ((cell (list function)))
    (if (subject-subscribers subject) (setf (cdr (subject-subscriber-tail subject)) cell
            (subject-subscriber-tail subject) cell)
      (setf (subject-subscribers subject) cell
            (subject-subscriber-tail subject) cell)))
  function)

(defun %remove-subject-subscribers (subscribers function)
  (let ((head nil)
        (tail nil))
    (dolist (subscriber subscribers (values head tail))
      (unless (eql subscriber function)
        (let ((cell (list subscriber)))
          (if head (setf (cdr tail) cell
                  tail cell)
            (setf head cell
                  tail cell)))))))

(defun subject-unsubscribe (subject function)
  "Remove FUNCTION from SUBJECT's subscribers (all occurrences) and return SUBJECT."
  (multiple-value-bind (subscribers tail) (%remove-subject-subscribers (subject-subscribers subject) function)
    (setf (subject-subscribers subject) subscribers
          (subject-subscriber-tail subject) tail))
  subject)

(defun subject-subscriber-count (subject)
  "Return the number of subscribers currently registered on SUBJECT."
  (length (subject-subscribers subject)))

(defun subject-emit (subject value)
  "Push VALUE to the subscribers present when emission starts, synchronously and
in subscription order, and return SUBJECT. Registry changes affect reentrant and
later emissions, but do not disturb the current pass."
  (let ((subscriber-cell (subject-subscribers subject))
        (last-cell (subject-subscriber-tail subject)))
    (loop while subscriber-cell
          do (funcall (car subscriber-cell) value)
            ;; The captured tail is the final cell in this emission's snapshot.
            (when (eq subscriber-cell last-cell)
              (return))
            (setf subscriber-cell (cdr subscriber-cell))))
  subject)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %parse-subject-operator-body (body)
    "Split a DEFINE-SUBJECT-OPERATOR body into
(VALUES DOCSTRING-FORMS BEFORE-FORMS STATE-BINDINGS SUBSCRIBER-FORMS): an optional
leading docstring (as a splice-ready list, empty when absent), the :BEFORE forms,
the :STATE bindings, and the remaining subscriber forms. Called at macro-expansion
time, so it is wrapped in EVAL-WHEN to be available when the macro expands its uses
in this same file."
    (let ((docstring-forms '())
          (before '())
          (state '()))
      (when (stringp (first body))
        (setf docstring-forms (list (pop body))))
      (loop for clause = (first body)
            while (and (consp clause) (member (first clause) '(:before :state)))
            do (if (eq (first clause) :before)
                   (setf before (rest clause))
                   (setf state (rest clause)))
               (pop body))
      (values docstring-forms before state body))))

(defmacro define-subject-operator (name lambda-list &body body)
  "Define NAME as a single-source derived-subject operator over the source subject
named by the first parameter of LAMBDA-LIST. This captures the scaffold every such
operator shares -- make a fresh subject, subscribe to the source, re-emit, return
the subject -- so each definition carries only its own transformation logic.

Optional leading clauses in BODY, in order: a docstring; then any mix of
  (:before FORM*)  -- forms evaluated once at call time (e.g. argument validation);
  (:state BINDING*) -- extra LET bindings holding per-operator closure state.
The remaining BODY is the subscriber. It runs once per value the source emits with
VALUE bound to that value, and the local macro EMIT pushes a value to the derived
subject. NAME returns the derived subject."
  (multiple-value-bind (docstring-forms before state subscriber)
      (%parse-subject-operator-body body)
    (let ((result (gensym "RESULT"))
          (source (first lambda-list)))
      `(defun ,name ,lambda-list
         ,@docstring-forms
         ,@before
         (let ((,result (make-subject)) ,@state)
           (macrolet ((emit (form) (list 'subject-emit ',result form)))
             (subject-subscribe ,source (lambda (value) ,@subscriber)))
           ,result)))))

(define-subject-operator subject-map (subject function)
  "Return a derived subject that emits (FUNCALL FUNCTION VALUE) whenever SUBJECT
emits VALUE."
  (emit (funcall function value)))

(define-subject-operator subject-filter (subject predicate)
  "Return a derived subject that re-emits only the values of SUBJECT for which
PREDICATE is true."
  (when (funcall predicate value)
    (emit value)))

(defun subject-merge (&rest subjects)
  "Return a derived subject that emits whenever any of SUBJECTS emits."
  (let ((result (make-subject)))
    (dolist (source subjects result)
      (subject-subscribe
        source
        (lambda (value)
          (subject-emit result value))))))

(defun subject-collect (subject &key limit (on-limit :error))
  "Subscribe a collector to SUBJECT and return a function of no arguments yielding
the list of values SUBJECT has emitted since, in emission order.
LIMIT bounds retained values. ON-LIMIT is :ERROR (signal from SUBJECT-EMIT) or
:DROP-NEWEST (ignore values after LIMIT)."
  (%validate-stream-limit limit "SUBJECT-COLLECT")
  (%validate-stream-limit-mode on-limit "SUBJECT-COLLECT" '(:error :drop-newest))
  (let ((collected '())
        (count 0))
    (subject-subscribe
      subject
      (lambda (value)
        (if (and limit (= count limit))
            (ecase on-limit
              (:error (%signal-stream-limit-exceeded "SUBJECT-COLLECT" limit))
              (:drop-newest nil))
            (progn
              (push value collected)
              (incf count)))))
    (lambda ()
      (reverse collected))))
