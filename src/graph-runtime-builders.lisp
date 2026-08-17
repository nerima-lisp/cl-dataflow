(in-package #:cl-dataflow-kit)

;;;; Building and remapping the graph backing a pipeline: mapping stage nodes
;;;; back onto a (possibly copied) graph's own node instances, the
;;;; PIPELINE-GRAPH/PIPELINE-METADATA setters, and %BUILD-SEQUENTIAL-GRAPH,
;;;; which chains a bare list of stage specs into a linear graph when a
;;;; pipeline is defined without an explicit graph.

(defun %remap-pipeline-stages (graph stages)
  (mapcar
    (lambda (stage)
      (or
        (find-node graph (node-name stage))
        (%signal-node-not-found-error
          graph
          stage
          (format
            nil
            "Pipeline stage is not present in the graph: ~A"
            (%escaped-display-string (node-name stage))))))
    stages))

(defun (setf pipeline-graph) (graph-value pipeline)
  (let ((copied-graph (copy-graph graph-value))
        (stages (%pipeline-stages-list pipeline)))
    (validate-graph copied-graph)
    (let ((remapped-stages
          (if stages (%remap-pipeline-stages copied-graph stages)
            '())))
      (setf (slot-value pipeline 'graph) copied-graph
            (slot-value pipeline 'stages) remapped-stages
            (%pipeline-execution-plan pipeline) nil)
      remapped-stages)))

(defun pipeline-graph (pipeline)
  (slot-value pipeline 'graph))

(defun (setf pipeline-metadata) (metadata pipeline)
  (setf (slot-value pipeline 'metadata) (%normalize-metadata metadata)))

(defun pipeline-metadata (pipeline)
  (%copy-structured-value (slot-value pipeline 'metadata)))

(defun %normalize-stage-spec (stage)
  (typecase stage
    (node stage)
    (t
      (%with-plist-bindings
        (stage
          ((name :name)
            (inputs :inputs)
            (outputs :outputs)
            (handler :handler)
            (metadata :metadata)))
        (make-node
          name
          :inputs
          inputs
          :outputs
          outputs
          :handler
          handler
          :metadata
          metadata)))))

(defun %build-sequential-graph (stages)
  (let ((graph (make-graph))
        (nodes (mapcar #'%normalize-stage-spec stages)))
    (dolist (node nodes)
      (add-node graph node))
    (do ((remaining nodes (rest remaining)))
      ((null (rest remaining)))
      (let ((previous (first remaining))
            (current (second remaining)))
        (add-edge
          graph
          previous
          current
          :from-port
          (first (%node-outputs-list previous))
          :to-port
          (first (%node-inputs-list current)))))
    (values graph nodes)))
