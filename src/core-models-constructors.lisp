(in-package #:cl-dataflow)

;;;; Public constructors (MAKE-NODE, MAKE-EDGE, MAKE-GRAPH, MAKE-CONTEXT) that
;;;; normalize and copy their arguments so a constructed object never aliases
;;;; caller-owned mutable data.

(defun make-node (name &key inputs outputs handler metadata)
  (make-instance 'node
                 :name (%normalize-name name)
                 :inputs (%normalize-unique-port-list inputs "input")
                 :outputs (%normalize-unique-port-list outputs "output")
                 :handler (or handler
                              (lambda (input context)
                                (declare (ignore context))
                                input))
                 :metadata (%normalize-metadata metadata)))

(defun make-edge (from to &key from-port to-port metadata)
  (make-instance 'edge
                 :from (%node-designator-name from)
                 :from-port (%normalize-name (or from-port "value"))
                 :to (%node-designator-name to)
                 :to-port (%normalize-name (or to-port "value"))
                 :metadata (%normalize-metadata metadata)))

(defun make-graph (&key metadata)
  (make-instance 'graph :metadata (%normalize-metadata metadata)))

(defun make-context (&key values events effects trace metadata effect-handlers result state)
  (let ((context (make-instance 'context
                                :metadata (%normalize-metadata metadata)
                                :state state)))
    (setf (context-result context) result)
    (when values
      (setf (context-values context) values))
    (when events
      (setf (context-events context) events))
    (when effects
      (setf (context-effects context) effects))
    (when trace
      (setf (context-trace context) trace))
    (when effect-handlers
      ;; (SETF CONTEXT-EFFECT-HANDLERS) copies the table itself, like every
      ;; other setter used here, so no second %COPY-EFFECT-HANDLERS is needed.
      (setf (context-effect-handlers context) effect-handlers))
    context))
