(in-package #:cl-dataflow)

;;;; The CLOS class definitions behind every public data model (NODE, EDGE,
;;;; GRAPH, CONTEXT, EVENT, EFFECT, STATE-TRANSITION, STATE-MACHINE, PIPELINE)
;;;; and their PRINT-OBJECT methods. Pure data: constructors, accessors, and
;;;; copying logic live in the sibling core-models-*.lisp files.

(defclass node ()
  ((name :initarg :name)
    (inputs :initarg :inputs)
    (outputs :initarg :outputs)
    (handler :initarg :handler)
    (metadata :initarg :metadata :initform '())))

(defclass edge ()
  ((from :initarg :from)
    (from-port :initarg :from-port)
    (to :initarg :to)
    (to-port :initarg :to-port)
    (metadata :initarg :metadata :initform '())))

(defclass graph ()
  ((nodes :initform (%make-result-table))
    (edges :initform '())
    (metadata :initarg :metadata :initform '())))

(defclass context ()
  ((values :initform (%make-result-table))
    (events :initform '())
    (effects :initform '())
    (trace :initform '())
    ;; Mirrors (length trace); kept in sync by %PUSH-CONTEXT-TRACE-ENTRY and the
    ;; CONTEXT-TRACE setter so TRACE-INDEX allocation doesn't re-walk the whole
    ;; trace history on every event/effect.
    (trace-count :initform 0)
    (metadata :initarg :metadata :initform '())
    (effect-handlers :initform (%make-result-table))
    (result :initarg :result :initform nil)
    (state :initarg :state :initform nil)))

(defclass event ()
  ((type :initarg :type)
    (payload :initarg :payload :initform nil)
    (metadata :initarg :metadata :initform '())
    (trace-index :initarg :trace-index :initform nil)))

(defclass effect ()
  ((type :initarg :type)
    (payload :initarg :payload :initform nil)
    (metadata :initarg :metadata :initform '())
    (trace-index :initarg :trace-index :initform nil)
    (result :initarg :result :initform nil)))

(defclass state-transition ()
  ((from :initarg :from)
    (event-type :initarg :event-type)
    (to :initarg :to)
    (guard :initarg :guard :initform nil)
    (action :initarg :action :initform nil)
    (metadata :initarg :metadata :initform '())))

(defclass state-machine ()
  ((state :initarg :state)
    (initial-state :initarg :initial-state)
    (transitions :initarg :transitions :initform '())
    (transition-index :initform nil)
    (history :initarg :history :initform '())
    (history-limit :initarg :history-limit :initform nil)
    (metadata :initarg :metadata :initform '())))

(defclass pipeline-stage-signature ()
  ((node :initarg :node :reader %pipeline-stage-signature-node)
    (name :initarg :name :reader %pipeline-stage-signature-name)
    (inputs :initarg :inputs :reader %pipeline-stage-signature-inputs)
    (outputs :initarg :outputs :reader %pipeline-stage-signature-outputs)))

(defclass pipeline-edge-signature ()
  ((edge :initarg :edge :reader %pipeline-edge-signature-edge)
    (from :initarg :from :reader %pipeline-edge-signature-from)
    (from-port :initarg :from-port :reader %pipeline-edge-signature-from-port)
    (to :initarg :to :reader %pipeline-edge-signature-to)
    (to-port :initarg :to-port :reader %pipeline-edge-signature-to-port)))

(defclass pipeline-execution-plan ()
  ((graph :initarg :graph :reader %pipeline-execution-plan-graph)
    (stages :initarg :stages :reader %pipeline-execution-plan-stages)
    (stage-signatures
      :initarg
      :stage-signatures
      :reader
      %pipeline-execution-plan-stage-signatures)
    (incoming-index
      :initarg
      :incoming-index
      :reader
      %pipeline-execution-plan-incoming-index)
    (input-binding-plans
      :initarg
      :input-binding-plans
      :reader
      %pipeline-execution-plan-input-binding-plans)
    (input-key-plans
      :initarg
      :input-key-plans
      :reader
      %pipeline-execution-plan-input-key-plans)
    (output-key-plans
      :initarg
      :output-key-plans
      :reader
      %pipeline-execution-plan-output-key-plans)
    (sinks :initarg :sinks :reader %pipeline-execution-plan-sinks)
    (sink-result-plans
      :initarg
      :sink-result-plans
      :reader
      %pipeline-execution-plan-sink-result-plans)
    (edge-signatures
      :initarg
      :edge-signatures
      :reader
      %pipeline-execution-plan-edge-signatures)))

(defclass pipeline ()
  ((graph :initarg :graph)
    (stages :initarg :stages :initform '())
    (execution-plan :initarg :execution-plan :initform nil)
    (metadata :initarg :metadata :initform '())))

(defmacro define-print-object (&body clauses)
  "Each CLAUSE is (CLASS-NAME (VAR STREAM-VAR) FORMAT-STRING &rest ARG-FORMS) and
expands to a PRINT-OBJECT method rendering VAR via PRINT-UNREADABLE-OBJECT with
:TYPE T and (FORMAT STREAM-VAR FORMAT-STRING . ARG-FORMS)."
  `(progn
    ,@(mapcar
      (lambda (clause)
        (destructuring-bind (class-name (var stream-var) format-string &rest arg-forms) clause
          `(defmethod print-object ((,var ,class-name) ,stream-var)
            (print-unreadable-object
              (,var ,stream-var :type t)
              (format ,stream-var ,format-string ,@arg-forms)))))
      clauses)))

(define-print-object
  (node (node stream) "~A" (%escaped-display-string (node-name node)))
  (edge (edge stream) "~A:~A -> ~A:~A"
    (%escaped-display-string (edge-from edge))
    (%escaped-display-string (edge-from-port edge))
    (%escaped-display-string (edge-to edge))
    (%escaped-display-string (edge-to-port edge)))
  (graph (graph stream) "~D nodes ~D edges"
    (hash-table-count (%graph-nodes-table graph))
    (length (%graph-edges-list graph)))
  (context (context stream) "events=~D effects=~D"
    (length (%context-events-list context))
    (length (%context-effects-list context)))
  (state-transition (transition stream) "~A --~A--> ~A"
    (%escaped-display-string (transition-from transition))
    (%escaped-display-string (transition-event-type transition))
    (%escaped-display-string (transition-to transition)))
  (state-machine (machine stream) "~A transitions=~D"
    (%escaped-display-string (state-machine-state machine))
    (length (%state-machine-transitions-list machine))))

(define-type-predicates
  (node-p node)
  (edge-p edge)
  (graph-p graph)
  (context-p context)
  (event-p event)
  (effect-p effect)
  (state-transition-p state-transition)
  (state-machine-p state-machine)
  (pipeline-p pipeline))
