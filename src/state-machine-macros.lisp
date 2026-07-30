(in-package #:cl-dataflow)

;;;; The DEFINE-STATE-MACHINE DSL macro: transition-clause parsing and
;;;; validation, expanding into a MAKE-STATE-MACHINE call.

;;; --- DEFINE-STATE-MACHINE DSL schema (data) --------------------------------

(defparameter +state-machine-transition-clause-options+ '(:guard :action :metadata))
(defparameter +state-machine-definition-options+
  '(:state :initial-state :history :history-limit :metadata))

(defun %macro-validate-option-list (options allowed-keys context)
  (unless (evenp (length options))
    (%signal-invalid-input-error
      `(property-list ,allowed-keys)
      options
      (format nil "~A options must be a property list."
              (%escaped-display-string context))))
  (loop for (key nil) on options by #'cddr
        do (unless (member key allowed-keys)
             (%signal-invalid-input-error
               allowed-keys
               key
               (format nil "Unsupported ~A option: ~S"
                       (%escaped-display-string context)
                       key)))))

(defun %parse-state-machine-clause (clause)
  (unless (and (listp clause) (>= (length clause) 3))
    (%signal-invalid-input-error
      '(from event to &key guard action metadata)
      clause
      "DEFINE-STATE-MACHINE clauses require FROM EVENT TO."))
  (destructuring-bind (from event to &rest options) clause
    (%macro-validate-option-list options +state-machine-transition-clause-options+
                                 "DEFINE-STATE-MACHINE transition")
    `(make-transition ,from ,event ,to
                      ,@options)))

(defun %parse-state-machine-definition (options clauses)
  (%macro-validate-option-list options
                                +state-machine-definition-options+
                               "DEFINE-STATE-MACHINE")
  `(make-state-machine
    ,@options
    :transitions (list ,@(mapcar #'%parse-state-machine-clause clauses))))

(defmacro define-state-machine ((&rest options) &body clauses)
  (%parse-state-machine-definition options clauses))
