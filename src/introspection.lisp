(in-package #:cl-dataflow)

;;;; Cross-cutting introspection: merging contexts, filtering a trace by entry
;;;; kind, and a structural describe/children protocol over every flow object.
;;;; FLOW-DESCRIBE and FLOW-CHILDREN extend the FLOW-NAME/FLOW-METADATA/FLOW-KIND
;;;; protocol with a uniform structural view.

(defun %merged-handler-table (base other)
  (let ((merged (context-effect-handlers base)))
    (maphash (lambda (key value) (setf (gethash key merged) value))
             (context-effect-handlers other))
    merged))

(defun context-merge (base other)
  "Return a new context combining BASE and OTHER: OTHER's stored node values overlay
BASE's (OTHER wins on key collisions), and their events, effects, and traces are
concatenated with BASE's first. Effect handlers merge with OTHER's overlaying
BASE's, but metadata is a plist concatenated with BASE's entries first, so BASE
wins on key collisions (the reverse of the handler-table rule). The current
state and result come from BASE. Neither input is modified."
  (let ((values (context-values base)))
    (maphash (lambda (key value)
               (setf (gethash key values) (%copy-structured-value value)))
             (context-values other))
    (make-context
     :values values
     :events (append (context-events other) (context-events base))
     :effects (append (context-effects other) (context-effects base))
     :trace (append (context-trace other) (context-trace base))
     :metadata (append (context-metadata base) (context-metadata other))
     :effect-handlers (%merged-handler-table base other)
     :state (context-state base)
     :result (context-result base))))

(defun context-trace-of-kind (context kind)
  "Return CONTEXT's trace entries of KIND (:NODE, :EVENT, :EFFECT, or :TRANSITION),
in chronological order."
  (remove-if-not (lambda (entry) (eq (%trace-entry-kind entry) kind))
                 (context-trace-in-order context)))

(defun %graph-children (graph)
  (let ((nodes (graph-nodes graph)))
    (mapcar (lambda (name) (gethash name nodes))
            (sort (%hash-table-keys nodes) #'string<))))

(defun %flow-child-count (object)
  (typecase object
    (graph (hash-table-count (%graph-nodes-table object)))
    (pipeline (length (%pipeline-stages-list object)))
    (state-machine (length (%state-machine-transitions-list object)))
    (t 0)))

(defun flow-children (object)
  "Return the immediate sub-components of a flow OBJECT: a graph's nodes (name
ordered), a pipeline's stages, or a state machine's transitions. Leaf objects
(nodes, edges, events, effects, transitions, contexts) have no children."
  (typecase object
    (graph (%graph-children object))
    (pipeline (pipeline-stages object))
    (state-machine (state-machine-transitions object))
    (t '())))

(defun flow-describe (object)
  "Return a structural plist describing a flow OBJECT:
  (:kind ... :name ... :metadata ... :children <count>),
combining FLOW-KIND, FLOW-NAME, FLOW-METADATA, and FLOW-CHILDREN."
  (list :kind (flow-kind object)
        :name (flow-name object)
        :metadata (flow-metadata object)
        :children (%flow-child-count object)))
