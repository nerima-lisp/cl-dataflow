(in-package #:cl-dataflow-kit)

;;;; Per-slot public accessors for the model classes (event/effect/node/edge/
;;;; transition/state-machine payload, metadata, and normalized-setter slots),
;;;; declared in bulk via DEFINE-SLOT-APIS rather than hand-written per class.

(defmethod context-effect-handlers ((context context))
  (%copy-effect-handlers (slot-value context 'effect-handlers)))

(defmethod (setf context-effect-handlers) (effect-handlers (context context))
  (setf (slot-value context 'effect-handlers)
        (if effect-handlers
            (%copy-effect-handlers effect-handlers)
            (%make-result-table))))

(defmethod context-state ((context context))
  (slot-value context 'state))

(defmethod (setf context-state) (state (context context))
  (setf (slot-value context 'state) state))

(defmethod state-machine-history-limit ((machine state-machine))
  (slot-value machine 'history-limit))

(defmethod (setf state-machine-history-limit) (limit (machine state-machine))
  (let ((resolved-limit (%validate-state-machine-history-limit limit)))
    (setf (slot-value machine 'history-limit) resolved-limit)
    (setf (%state-machine-history-list machine)
          (%trim-transition-history (%state-machine-history-list machine)
                                    resolved-limit))
    resolved-limit))

(define-slot-apis
  (:read-only event-type event type)
  (:read-only event-trace-index event trace-index)
  (:read-only effect-type effect type)
  (:read-only effect-trace-index effect trace-index)
  (:setter-transform transition-guard transition guard identity)
  (:setter-transform transition-action transition action identity)
  (:read-only node-handler node handler)
  (:copy event-payload event payload %copy-structured-value)
  (:copy effect-payload effect payload %copy-structured-value)
  (:copy effect-result effect result %copy-structured-value)
  (:setter-transform transition-from transition from %normalize-name)
  (:setter-transform transition-event-type transition event-type %normalize-name)
  (:setter-transform transition-to transition to %normalize-name)
  (:setter-transform state-machine-state machine state %normalize-name)
  (:setter-transform state-machine-initial-state machine initial-state %normalize-name)
  (:setter-transform node-name node name %normalize-name)
  (:setter-transform edge-from edge from %node-designator-name)
  (:setter-transform edge-from-port edge from-port (lambda (value)
                                                      (%normalize-name (or value "value"))))
  (:setter-transform edge-to edge to %node-designator-name)
  (:setter-transform edge-to-port edge to-port (lambda (value)
                                                  (%normalize-name (or value "value"))))
  (:transform event-metadata event metadata
              (%copy-structured-value (%read-slot event 'metadata))
              (%normalize-metadata value))
  (:transform effect-metadata effect metadata
              (%copy-structured-value (%read-slot effect 'metadata))
              (%normalize-metadata value))
  (:transform transition-metadata transition metadata
              (%copy-structured-value (slot-value transition 'metadata))
              (%normalize-metadata value))
  (:transform state-machine-history machine history
              (%copy-transition-history (slot-value machine 'history))
              (%trim-transition-history
               (%copy-transition-history value)
               (state-machine-history-limit machine)))
  (:transform state-machine-metadata machine metadata
              (%copy-structured-value (slot-value machine 'metadata))
              (%normalize-metadata value))
  (:transform node-inputs node inputs
              (%normalize-unique-port-list (slot-value node 'inputs) "input")
              (%normalize-unique-port-list value "input"))
  (:transform node-outputs node outputs
              (%normalize-unique-port-list (slot-value node 'outputs) "output")
              (%normalize-unique-port-list value "output"))
  (:transform node-metadata node metadata
              (%copy-structured-value (slot-value node 'metadata))
              (%normalize-metadata value))
  (:transform edge-metadata edge metadata
              (%copy-structured-value (slot-value edge 'metadata))
              (%normalize-metadata value)))
