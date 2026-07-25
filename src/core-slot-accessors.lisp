(in-package #:cl-dataflow)

;;;; The lowest-level slot-access primitives (%READ-SLOT and friends) plus
;;;; DEFINE-SLOT-APIS/DEFINE-TYPE-PREDICATES, the two code-generating macros
;;;; that every model accessor and type predicate in this library expands
;;;; from -- the DSL "schema" data lives with each macro's call sites, not
;;;; here.

(defun %read-slot (object slot-name)
  (slot-value object slot-name))

(defun %slot-value-or (object slot-name default)
  (if (slot-boundp object slot-name) (slot-value object slot-name)
    default))

(defun (setf %read-slot) (value object slot-name)
  (setf (slot-value object slot-name) value))

(defun %expected-object-detail (expected value)
  (format nil "Expected ~A, got ~S" expected value))

(defun %node-inputs-list (node)
  (%read-slot node 'inputs))

(defun %node-outputs-list (node)
  (%read-slot node 'outputs))

(defun %graph-nodes-table (graph)
  (%read-slot graph 'nodes))

(defun %graph-edges-list (graph)
  (%read-slot graph 'edges))

(defsetf %graph-edges-list (graph)
  (new-edges)
  `(setf (%read-slot ,graph 'edges) ,new-edges))

(defun %context-values-table (context)
  (%read-slot context 'values))

(defun %context-effect-handler-table (context)
  (%read-slot context 'effect-handlers))

(defun %context-events-list (context)
  (%read-slot context 'events))

(defsetf %context-events-list (context)
  (new-events)
  `(setf (%read-slot ,context 'events) ,new-events))

(defun %context-effects-list (context)
  (%read-slot context 'effects))

(defsetf %context-effects-list (context)
  (new-effects)
  `(setf (%read-slot ,context 'effects) ,new-effects))

(defun %context-trace-list (context)
  (%read-slot context 'trace))

(defsetf %context-trace-list (context)
  (new-trace)
  `(setf (%read-slot ,context 'trace) ,new-trace))

(defun %context-trace-count (context)
  (slot-value context 'trace-count))

(defun %state-machine-transitions-list (machine)
  (%read-slot machine 'transitions))

(defun %state-machine-history-list (machine)
  (%read-slot machine 'history))

(defsetf %state-machine-history-list (machine)
  (new-history)
  `(setf (%read-slot ,machine 'history) ,new-history))

(defun %pipeline-stages-list (pipeline)
  (%read-slot pipeline 'stages))

(defun %pipeline-execution-plan (pipeline)
  (%read-slot pipeline 'execution-plan))

(defun (setf %pipeline-execution-plan) (plan pipeline)
  (setf (%read-slot pipeline 'execution-plan) plan))

(defun %slot-api-getter-form (name object-name body)
  `(defun ,name (,object-name)
    ,body))

(defun %slot-api-setter-form (name object-name slot-name body)
  `(defun (setf ,name) (value ,object-name)
    (setf (slot-value ,object-name ',slot-name) ,body)))

(defun %slot-api-accessor-forms (name object-name slot-name getter-body setter-body)
  (list
    (%slot-api-getter-form name object-name getter-body)
    (%slot-api-setter-form name object-name slot-name setter-body)))

(defmacro define-type-predicates (&body specs)
  `(progn
    ,@(mapcar
      (lambda (spec)
        (destructuring-bind (predicate-name type-name) spec
          `(defun ,predicate-name (object)
            (typep object ',type-name))))
      specs)))

(defun %slot-api-clause-forms (clause)
  (destructuring-bind (kind name object-name slot-name &rest args) clause
    (ecase kind
      (:read-only
        (list
          (%slot-api-getter-form name object-name `(slot-value ,object-name ',slot-name))))
      (:copy
        (destructuring-bind (&optional (copy-form '%copy-structured-value)) args
          (%slot-api-accessor-forms
            name
            object-name
            slot-name
            `(,copy-form (slot-value ,object-name ',slot-name))
            `(,copy-form value))))
      (:mapcar-copy
        (destructuring-bind (copier-name) args
          (%slot-api-accessor-forms
            name
            object-name
            slot-name
            `(mapcar #',copier-name (slot-value ,object-name ',slot-name))
            `(mapcar #',copier-name value))))
      (:setter-transform
        (destructuring-bind (transform-form) args
          (%slot-api-accessor-forms
            name
            object-name
            slot-name
            `(slot-value ,object-name ',slot-name)
            `(,transform-form value))))
      (:transform
        (destructuring-bind (getter-form setter-form) args
          (%slot-api-accessor-forms name object-name slot-name getter-form setter-form))))))

(defmacro define-slot-apis (&body clauses)
  `(progn
    ,@(mapcan #'%slot-api-clause-forms clauses)))

(defun %hash-table-keys (table)
  (let (keys)
    (maphash
      (lambda (key value)
        (declare (ignore value))
        (push key keys))
      table)
    (nreverse keys)))
