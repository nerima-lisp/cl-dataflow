(in-package #:cl-dataflow)

;;;; Graph mutation and composition. The base graph API is append-only (ADD-NODE /
;;;; ADD-EDGE); these fill in removal, induced subgraphs, disjoint merge, and node
;;;; relabelling. In-place removals mutate GRAPH and mirror the add-* return
;;;; conventions; the derivations (subgraph, merge, relabel) return fresh graphs
;;;; and never alter their inputs.

(defun %edge-touches-node-p (edge name)
  (or (equal (edge-from edge) name)
      (equal (edge-to edge) name)))

(defun remove-node (graph node)
  "Remove NODE and every edge incident to it from GRAPH, in place, and return
GRAPH. Signals NODE-NOT-FOUND-ERROR when NODE is absent."
  (let ((name (%ensure-graph-node-name graph node)))
    (remhash name (%graph-nodes-table graph))
    (setf (%graph-edges-list graph)
          (remove-if (lambda (edge) (%edge-touches-node-p edge name))
                     (%graph-edges-list graph)))
    graph))

(defun remove-edge (graph from to &key (from-port "value") (to-port "value"))
  "Remove the edge FROM:FROM-PORT -> TO:TO-PORT from GRAPH, in place. Ports default
to \"value\", matching ADD-EDGE. Returns T when a matching edge was removed and NIL
when none existed."
  (let ((target (%edge-identity-key (%node-designator-name from)
                                    (%normalize-name from-port)
                                    (%node-designator-name to)
                                    (%normalize-name to-port)))
        (edges (%graph-edges-list graph)))
    (let ((remaining (remove-if (lambda (edge)
                                  (equal (%edge-sort-key edge) target))
                                edges)))
      (setf (%graph-edges-list graph) remaining)
      (< (length remaining) (length edges)))))

(defun %wanted-node-set (graph node-names)
  "A name -> t table of the members of NODE-NAMES that actually exist in GRAPH."
  (let ((wanted (make-hash-table :test #'equal))
        (nodes (%graph-nodes-table graph)))
    (dolist (name node-names wanted)
      (let ((normalized (%node-designator-name name)))
        (when (gethash normalized nodes)
          (setf (gethash normalized wanted) t))))))

(defun %readd-edge (result edge)
  "Re-create EDGE (endpoints, ports, metadata) inside RESULT."
  (let ((added (add-edge result (edge-from edge) (edge-to edge)
                         :from-port (edge-from-port edge)
                         :to-port (edge-to-port edge))))
    (setf (edge-metadata added) (edge-metadata edge))
    added))

(defun graph-subgraph (graph node-names)
  "Return the subgraph of GRAPH induced by NODE-NAMES: copies of those nodes that
exist in GRAPH, plus every edge whose endpoints are both in the set (ports and
metadata preserved). GRAPH's metadata is copied; names not present in GRAPH are
ignored. GRAPH is not modified."
  (let ((wanted (%wanted-node-set graph node-names))
        (nodes (%graph-nodes-table graph))
        (result (make-graph :metadata (graph-metadata graph))))
    (dolist (name (sort (%hash-table-keys wanted) #'string<))
      (add-node result (%copy-node-snapshot (gethash name nodes))))
    (dolist (edge (reverse (%graph-edges-list graph)))
      (when (and (gethash (edge-from edge) wanted)
                 (gethash (edge-to edge) wanted))
        (%readd-edge result edge)))
    result))

(defun graph-merge (graph-a graph-b &key metadata)
  "Return a new graph containing every node and edge of GRAPH-A and GRAPH-B, with
ports and metadata preserved. Node names must be disjoint; a name present in both
signals GRAPH-ERROR. METADATA sets the merged graph's metadata (default: a copy of
GRAPH-A's). Neither input is modified."
  (let ((result (make-graph :metadata (if metadata metadata (graph-metadata graph-a)))))
    (dolist (source (list graph-a graph-b))
      (let ((nodes (%graph-nodes-table source)))
        (dolist (name (sort (%hash-table-keys nodes) #'string<))
          (when (find-node result name)
            (%signal-graph-error
             result
             (format nil "Cannot merge graphs: duplicate node name ~A"
                     (%escaped-display-string name))))
          (add-node result (%copy-node-snapshot (gethash name nodes))))))
    (dolist (source (list graph-a graph-b))
      (dolist (edge (reverse (%graph-edges-list source)))
        (%readd-edge result edge)))
    result))

(defun %contract-edge-redirect (edge to-name from-name from-out from-in)
  "Return (VALUES NEW-FROM NEW-FROM-PORT NEW-TO NEW-TO-PORT) for EDGE after
merging TO-NAME into FROM-NAME: an endpoint at TO-NAME redirects to FROM-NAME,
attaching at FROM-NAME's first output/input port (FROM-OUT/FROM-IN)."
  (let* ((from-changed (equal (edge-from edge) to-name))
         (to-changed (equal (edge-to edge) to-name)))
    (values (if from-changed from-name (edge-from edge))
            (if from-changed from-out (edge-from-port edge))
            (if to-changed from-name (edge-to edge))
            (if to-changed from-in (edge-to-port edge)))))

(defun graph-contract-edge (graph from to)
  "Return a new graph with node TO merged into node FROM: every edge incident to TO
is redirected to FROM (a redirected endpoint attaches to FROM's first port), edges
that become self-loops through the merge are dropped, and resulting duplicate edges
collapse (the first edge's metadata wins). FROM and TO must be distinct existing
nodes; signals INVALID-INPUT-ERROR otherwise. GRAPH is not modified."
  (let ((from-name (%ensure-graph-node-name graph from))
        (to-name (%ensure-graph-node-name graph to)))
    (when (equal from-name to-name)
      (%signal-invalid-input-error
        'distinct-nodes
        from-name
        "GRAPH-CONTRACT-EDGE requires two distinct nodes."))
    (let* ((nodes (%graph-nodes-table graph))
           (from-node (gethash from-name nodes))
           (from-out (first (%node-outputs-list from-node)))
           (from-in (first (%node-inputs-list from-node)))
           (result (make-graph :metadata (graph-metadata graph)))
           (seen (make-hash-table :test #'equal)))
      (dolist (name (%graph-node-name-set graph))
        (unless (equal name to-name)
          (add-node result (%copy-node-snapshot (gethash name nodes)))))
      (dolist (edge (reverse (%graph-edges-list graph)))
        (multiple-value-bind (new-from new-from-port new-to new-to-port)
            (%contract-edge-redirect edge to-name from-name from-out from-in)
          (unless (equal new-from new-to)
            (let ((key (%edge-identity-key new-from new-from-port new-to new-to-port)))
              (unless (gethash key seen)
                (setf (gethash key seen) t)
                (let ((added (add-edge result new-from new-to
                                       :from-port new-from-port :to-port new-to-port)))
                  (setf (edge-metadata added) (edge-metadata edge))))))))
      result)))

(defun %relabel-name (name old new)
  (if (equal name old) new name))

(defun graph-relabel-node (graph old-name new-name)
  "Return a new graph identical to GRAPH but with node OLD-NAME renamed to
NEW-NAME, updating every incident edge. Signals NODE-NOT-FOUND-ERROR when OLD-NAME
is absent and GRAPH-ERROR when NEW-NAME already names a different node. GRAPH is
not modified."
  (let ((old (%ensure-graph-node-name graph old-name))
        (new (%node-designator-name new-name))
        (nodes (%graph-nodes-table graph)))
    (when (gethash new nodes)
      (%signal-graph-error
       graph
       (format nil "Cannot relabel to existing node name ~A"
               (%escaped-display-string new))))
    (let ((result (make-graph :metadata (graph-metadata graph))))
      (dolist (name (%graph-node-name-set graph))
        (let ((snapshot (%copy-node-snapshot (gethash name nodes))))
          (when (equal name old)
            (setf (node-name snapshot) new))
          (add-node result snapshot)))
      (dolist (edge (reverse (%graph-edges-list graph)))
        (let ((added (add-edge result
                               (%relabel-name (edge-from edge) old new)
                               (%relabel-name (edge-to edge) old new)
                               :from-port (edge-from-port edge)
                               :to-port (edge-to-port edge))))
          (setf (edge-metadata added) (edge-metadata edge))))
      result)))
