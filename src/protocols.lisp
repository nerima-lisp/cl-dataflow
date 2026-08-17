(in-package #:cl-dataflow-kit)

;;;; FLOW-NAME, FLOW-METADATA, and FLOW-KIND: one cross-type introspection
;;;; protocol over every public flow object (node, edge, graph, context,
;;;; event, effect, state-transition, state-machine, pipeline), generated
;;;; from a per-type dispatch table via DEFINE-FLOW-DISPATCH.

(defmacro define-flow-dispatch (name &body clauses)
  `(defun ,name (object)
     (typecase object
       ,@(mapcar (lambda (clause)
                   `(,(first clause) ,(second clause)))
                 clauses)
       (t
        (error 'type-error
               :datum object
               :expected-type
               '(or node edge graph context event effect
                    state-transition state-machine pipeline))))))

(define-flow-dispatch flow-name
  (node (node-name object))
  (edge (list (edge-from object) (edge-to object)))
  (graph :graph)
  (context :context)
  (event (event-type object))
  (effect (effect-type object))
  (state-transition (transition-event-type object))
  (state-machine (state-machine-state object))
  (pipeline :pipeline))

(define-flow-dispatch flow-metadata
  (node (node-metadata object))
  (edge (edge-metadata object))
  (graph (graph-metadata object))
  (context (context-metadata object))
  (event (event-metadata object))
  (effect (effect-metadata object))
  (state-transition (transition-metadata object))
  (state-machine (state-machine-metadata object))
  (pipeline (pipeline-metadata object)))

(define-flow-dispatch flow-kind
  (node :node)
  (edge :edge)
  (graph :graph)
  (context :context)
  (event :event)
  (effect :effect)
  (state-transition :state-transition)
  (state-machine :state-machine)
  (pipeline :pipeline))
