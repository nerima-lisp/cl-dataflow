(in-package #:cl-dataflow)

;;;; Pipeline serialisation, validation, and composition helpers. Structure is
;;;; serialised through the graph plist round trip (so handlers, being runtime
;;;; closures, are not persisted); MAP-PIPELINE and PIPELINE->NODE let a pipeline
;;;; be applied across a collection or embedded as a single node in a larger graph.

(defun pipeline-to-plist (pipeline)
  "Serialise PIPELINE's structure to a plist
  (:metadata ... :graph <graph-plist> :stages (name ...)).
Node handlers are runtime closures and are not serialised (see GRAPH-TO-PLIST), so
the round trip preserves topology, ports, metadata, and stage order."
  (list :metadata (pipeline-metadata pipeline)
        :graph (graph-to-plist (pipeline-graph pipeline))
        :stages (mapcar #'node-name (%pipeline-stages-list pipeline))))

(defun plist-to-pipeline (plist)
  "Rebuild a pipeline from a plist produced by PIPELINE-TO-PLIST. Reconstructed
nodes use the default identity handler."
  (let ((graph (plist-to-graph (getf plist :graph))))
    (make-pipeline :graph graph
                   :stages (mapcar (lambda (name) (find-node graph name))
                                   (getf plist :stages))
                   :metadata (getf plist :metadata))))

(defun pipeline-validate (pipeline)
  "Validate PIPELINE's graph (structural integrity plus acyclicity) and return T.
Signals the same conditions as VALIDATE-GRAPH on a malformed or cyclic graph."
  (validate-graph (pipeline-graph pipeline))
  t)

(defun pipeline-stage-count (pipeline)
  "Return the number of stages in PIPELINE."
  (length (%pipeline-stages-list pipeline)))

(defun map-pipeline (pipeline inputs &key context parallel)
  "Run PIPELINE once for each element of INPUTS and return the list of results in
order. With no CONTEXT each run uses its own fresh context (independent runs); with
a CONTEXT that single context is shared, so events, effects, and trace accumulate
across every run. PARALLEL runs the independent (no-CONTEXT) case concurrently via
cl-concurrent-kit -- since each run already gets its own fresh context, there is no
shared state to guard, unlike RUN-PIPELINE's own :PARALLEL. Combining PARALLEL with
a shared CONTEXT is rejected with INVALID-INPUT-ERROR: concurrent runs against one
context would race on it and silently break the documented in-order accumulation
guarantee."
  (cond
    ((and parallel context)
      (%signal-invalid-input-error
        nil
        context
        "MAP-PIPELINE's :PARALLEL cannot be combined with a shared :CONTEXT."))
    (parallel (%map-pipeline-parallel pipeline inputs))
    (t
      (mapcar (lambda (input)
                (run-pipeline pipeline :input input :context context))
              inputs))))

(defun pipeline->node (pipeline name &key metadata)
  "Return a node named NAME whose handler runs PIPELINE on the node's input (in its
own isolated context) and yields PIPELINE's result. This embeds a whole pipeline as
one stage of a larger graph."
  (make-node name
             :metadata metadata
             :handler (lambda (input context)
                        (declare (ignore context))
                        (run-pipeline pipeline :input input))))
