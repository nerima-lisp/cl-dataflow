(in-package #:cl-dataflow)

;;;; Introspection and observability that ties the other layers together:
;;;; render a pipeline's graph, enumerate its structural roles, and turn a
;;;; context's trace into human-readable text and roll-up counts. Trace entries
;;;; are the plists appended by EMIT-EVENT (:event), PERFORM-EFFECT (:effect),
;;;; the pipeline node runner (:node), and state-machine transitions (:from ...);
;;;; a single classifier keys off the first distinguishing slot.

;;; --- Pipeline introspection / visualization ------------------------------

(defun pipeline->dot (pipeline &key (name "pipeline"))
  "Render PIPELINE's graph as a Graphviz DOT string (see GRAPH->DOT)."
  (graph->dot (pipeline-graph pipeline) :name name))

(defun pipeline->mermaid (pipeline &key (direction "TD"))
  "Render PIPELINE's graph as a Mermaid flowchart string (see GRAPH->MERMAID)."
  (graph->mermaid (pipeline-graph pipeline) :direction direction))

(defun pipeline-node-names (pipeline)
  "Return the names of every node in PIPELINE's graph, ordered lexicographically."
  (graph-node-names (pipeline-graph pipeline)))

(defun pipeline-stage-names (pipeline)
  "Return the names of PIPELINE's stages in execution order."
  (mapcar #'node-name (%pipeline-stages-list pipeline)))

(defun pipeline-source-names (pipeline)
  "Return the names of PIPELINE's source nodes (indegree 0), ordered by name."
  (mapcar #'node-name (graph-source-nodes (pipeline-graph pipeline))))

(defun pipeline-sink-names (pipeline)
  "Return the names of PIPELINE's sink nodes (no successors), ordered by name."
  (mapcar #'node-name (graph-sink-nodes (pipeline-graph pipeline))))

;;; --- Trace and context observability -------------------------------------

(defun %trace-entry-kind (entry)
  "Classify a trace ENTRY as :NODE, :EVENT, :EFFECT, or :TRANSITION. Node/event/
effect entries lead with a truthy slot of that name; anything else is the
transition record appended by the state machine (which leads with :FROM)."
  (cond ((getf entry :node) :node)
        ((getf entry :event) :event)
        ((getf entry :effect) :effect)
        (t :transition)))

(defun %trace-display-value (value)
  (%escaped-display-string value))

(defun %trace-entry-description (entry)
  (case (%trace-entry-kind entry)
    (:node (format nil "node ~A" (%trace-display-value (getf entry :node))))
    (:event (format nil "event ~A" (%trace-display-value (getf entry :event))))
    (:effect (format nil "effect ~A" (%trace-display-value (getf entry :effect))))
    (t (format nil "transition ~A --~A--> ~A"
               (%trace-display-value (getf entry :from))
               (%trace-display-value (getf entry :event-type))
               (%trace-display-value (getf entry :to))))))

(defun format-trace (context)
  "Return a human-readable, newline-terminated rendering of CONTEXT's trace in
chronological order, one numbered entry per line."
  (with-output-to-string (out)
    (loop for entry in (context-trace-in-order context)
          for index from 0
          do (format out "~D. ~A~%" index (%trace-entry-description entry)))))

(defun trace-summary (context)
  "Return a plist counting CONTEXT's trace entries by kind:
  (:total N :nodes N :events N :effects N :transitions N)."
  (let ((kinds (mapcar #'%trace-entry-kind (context-trace-in-order context))))
    (list :total (length kinds)
          :nodes (count :node kinds)
          :events (count :event kinds)
          :effects (count :effect kinds)
          :transitions (count :transition kinds))))

(defun context-summary (context)
  "Return a plist summarising CONTEXT: event, effect, stored-value, and trace
counts plus the current state
  (:events N :effects N :values N :trace N :state S)."
  ;; Measured off the live collections, like %FLOW-CHILD-COUNT: the public
  ;; readers deep-copy every event, effect, stored value, and trace entry, and a
  ;; summary that only reports sizes has no use for the copies.
  (list :events (length (%context-events-list context))
        :effects (length (%context-effects-list context))
        :values (hash-table-count (%context-values-table context))
        :trace (length (%context-trace-list context))
        :state (context-state context)))
