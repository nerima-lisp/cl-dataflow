(in-package #:cl-dataflow)

;;;; Condition types for every error this library signals (input validation,
;;;; graph structure, missing effect handlers, invalid transitions, guard
;;;; failures) and the shared detail-report formatting they use.

;; NOTINLINE only under coverage instrumentation (see PACKAGE.LISP): it makes
;; SB-COVER see every call site separately, at the cost of the CLOS
;; fast-slot-access transform and copier inlining a SPEED 3 policy would
;; otherwise apply. Outside coverage runs, this declaim is skipped entirely
;; so the default (non-NOTINLINE) policy -- combined with PACKAGE.LISP's
;; SPEED 3 -- can optimize these hot accessors and copiers freely.
#.(if (find-package "SB-COVER")
      '(declaim (notinline %copy-structured-value
                           %copy-node-snapshot
                           %copy-edge-snapshot
                           %copy-graph-snapshot
                           %copy-event
                           %copy-effect
                           graph-nodes
                           graph-edges
                           graph-metadata
                           context-values
                           context-events
                           context-effects
                           context-trace
                           context-metadata
                           context-effect-handlers
                           context-result
                           context-state
                           event-type
                           event-payload
                           event-metadata
                           event-trace-index
                           effect-type
                           effect-payload
                           effect-metadata
                           effect-trace-index))
      '(progn))

(define-condition cl-dataflow-error (error) ())

(defun %write-condition-detail-report (condition stream detail-reader)
  (format stream "~A: ~A"
          (type-of condition)
          (%escaped-display-string (funcall detail-reader condition))))

(defun %write-graph-cycle-report (condition stream)
  (%write-condition-detail-report
   condition
   stream
   (lambda (graph-condition)
     (let ((detail (graph-error-detail graph-condition))
           (cycle-nodes (mapcar (lambda (node)
                                  (%escaped-display-string (node-name node)))
                                (graph-cycle-nodes graph-condition))))
       (if cycle-nodes
           (format nil "~A Cyclic nodes: ~{~A~^, ~}" detail cycle-nodes)
           detail)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro %define-condition-with-report (name (&rest supers) slots report-form)
    `(define-condition ,name (,@supers)
       ,slots
       (:report ,report-form)))

  (defmacro %define-condition-with-detail-report (name (&rest supers) slots detail-reader)
    `(%define-condition-with-report ,name (,@supers) ,slots
       (lambda (condition stream)
         (%write-condition-detail-report condition stream #',detail-reader)))))

(%define-condition-with-detail-report invalid-input-error (cl-dataflow-error)
  ((expected :initarg :expected :reader invalid-input-expected)
   (value :initarg :value :reader invalid-input-value)
   (detail :initarg :detail :reader invalid-input-detail))
  invalid-input-detail)

(defun %signal-invalid-input-error (expected value detail)
  (error 'invalid-input-error
         :expected expected
         :value value
         :detail detail))

(%define-condition-with-detail-report graph-error (cl-dataflow-error)
  ((graph :initarg :graph :reader graph-error-graph)
   (detail :initarg :detail :reader graph-error-detail))
  graph-error-detail)

(define-condition node-not-found-error (graph-error)
  ((designator :initarg :designator :reader node-not-found-designator)))

(%define-condition-with-report graph-cycle-error (graph-error)
  ((nodes :initarg :nodes :reader graph-cycle-nodes))
  (lambda (condition stream)
    (%write-graph-cycle-report condition stream)))

(%define-condition-with-detail-report effect-handler-missing-error (cl-dataflow-error)
  ((effect-type :initarg :effect-type :reader missing-effect-type)
   (effect :initarg :effect :reader effect-handler-missing-effect)
   (detail :initarg :detail :reader effect-handler-missing-detail))
  effect-handler-missing-detail)

(%define-condition-with-detail-report invalid-transition-error (cl-dataflow-error)
  ((state :initarg :state :reader invalid-transition-state)
   (event-type :initarg :event-type :reader invalid-transition-event-type)
   (detail :initarg :detail :reader invalid-transition-detail))
  invalid-transition-detail)

(%define-condition-with-detail-report guard-failed-error (cl-dataflow-error)
  ((state :initarg :state :reader guard-failed-state)
   (event-type :initarg :event-type :reader guard-failed-event-type)
   (transition :initarg :transition :reader guard-failed-transition)
   (detail :initarg :detail :reader guard-failed-detail))
  guard-failed-detail)
