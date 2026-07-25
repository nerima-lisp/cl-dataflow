(in-package #:cl-dataflow)

;;;; Batch event/effect emission and result/predicate helpers over a context.
;;;; A spec is either a bare type designator or a (TYPE &KEY PAYLOAD METADATA)
;;;; list, so a sequence of occurrences can be described declaratively and emitted
;;;; in order.

(defun %emit-specs (context specs emit-one)
  "Call EMIT-ONE -- a function of the same (CONTEXT TYPE &KEY PAYLOAD METADATA)
signature as EMIT-EVENT/PERFORM-EFFECT -- once per element of SPECS on CONTEXT, in
order, returning the results. Each spec is either a type designator or a
(TYPE &KEY PAYLOAD METADATA) list; EMIT-EVENTS and PERFORM-EFFECTS both drive this
same batch shape over their own single-item function."
  (mapcar (lambda (spec)
            (if (consp spec)
                (destructuring-bind (type &key payload metadata) spec
                  (funcall emit-one context type :payload payload :metadata metadata))
                (funcall emit-one context spec)))
          specs))

(defun emit-events (context specs)
  "Emit one event per element of SPECS on CONTEXT, in order, returning the list of
events. Each spec is either a type designator or a (TYPE &KEY PAYLOAD METADATA)
list."
  (%emit-specs context specs #'emit-event))

(defun perform-effects (context specs)
  "Perform one effect per element of SPECS on CONTEXT, in order, returning the list
of effects. Each spec is either a type designator or a (TYPE &KEY PAYLOAD METADATA)
list. Every effect type must have a registered handler."
  (%emit-specs context specs #'perform-effect))

(defun context-effect-results (context)
  "Return the results of every effect performed on CONTEXT, in chronological order."
  (mapcar #'effect-result (context-effects-in-order context)))

(defun context-effect-results-of-type (context type)
  "Return the results of the effects of TYPE performed on CONTEXT, in order."
  (mapcar #'effect-result (context-effects-of-type context type)))

(defun event-of-type-p (event type)
  "Return true when EVENT's type matches TYPE (compared case-insensitively after
normalisation)."
  (string-equal (event-type event) (%normalize-name type)))

(defun effect-of-type-p (effect type)
  "Return true when EFFECT's type matches TYPE (compared case-insensitively after
normalisation)."
  (string-equal (effect-type effect) (%normalize-name type)))
