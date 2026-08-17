(in-package #:cl-dataflow-kit)

;;;; Set algebra and functional transforms over graphs: union, intersection, and
;;;; difference (by node name and edge identity), plus predicate filtering and a
;;;; node-relabelling map. All produce fresh graphs and never mutate their inputs.
;;;; Edges are compared by their identity key (endpoints + ports), reusing the
;;;; same %EDGE-SORT-KEY the export/mutation layers use.

(defun %graph-name-set (graph)
  (let ((set (make-hash-table :test #'equal)))
    (dolist (name (%graph-node-name-set graph) set)
      (setf (gethash name set) t))))

(defun %graph-edge-key-set (graph)
  (let ((set (make-hash-table :test #'equal)))
    (dolist (edge (%graph-edges-list graph) set)
      (setf (gethash (%edge-sort-key edge) set) t))))

(defun graph-union (graph-a graph-b &key metadata)
  "Return a new graph containing every node and edge of GRAPH-A and GRAPH-B. Node
names and edges shared between the inputs appear once; GRAPH-A's definition wins
for a shared node, so shared names are assumed to have compatible ports. METADATA
sets the result's metadata (default: a copy of GRAPH-A's)."
  (let ((result (make-graph :metadata (if metadata metadata (graph-metadata graph-a))))
        (seen-nodes (make-hash-table :test #'equal)))
    (dolist (graph (list graph-a graph-b))
      (let ((nodes (%graph-nodes-table graph)))
        (dolist (name (%graph-node-name-set graph))
          (unless (gethash name seen-nodes)
            (setf (gethash name seen-nodes) t)
            (add-node result (%copy-node-snapshot (gethash name nodes)))))))
    (let ((seen-edges (make-hash-table :test #'equal)))
      (dolist (graph (list graph-a graph-b))
        (dolist (edge (reverse (%graph-edges-list graph)))
          (unless (gethash (%edge-sort-key edge) seen-edges)
            (setf (gethash (%edge-sort-key edge) seen-edges) t)
            (%readd-edge result edge)))))
    result))

(defun graph-intersection (graph-a graph-b)
  "Return a new graph of the nodes present in both GRAPH-A and GRAPH-B (by name) and
the edges present in both (by identity). GRAPH-A's node and metadata definitions are
used. Neither input is modified."
  (let ((b-names (%graph-name-set graph-b))
        (b-edges (%graph-edge-key-set graph-b))
        (nodes (%graph-nodes-table graph-a))
        (result (make-graph :metadata (graph-metadata graph-a))))
    (dolist (name (%graph-node-name-set graph-a))
      (when (gethash name b-names)
        (add-node result (%copy-node-snapshot (gethash name nodes)))))
    ;; An edge shared by both graphs necessarily has both endpoints in both, hence
    ;; in the intersected node set -- no extra endpoint check is needed.
    (dolist (edge (reverse (%graph-edges-list graph-a)))
      (when (gethash (%edge-sort-key edge) b-edges)
        (%readd-edge result edge)))
    result))

(defun graph-difference (graph-a graph-b)
  "Return a new graph with all of GRAPH-A's nodes but only the edges of GRAPH-A whose
identity does not also appear in GRAPH-B. This is edge subtraction; nodes are kept.
Neither input is modified."
  (let ((b-edges (%graph-edge-key-set graph-b))
        (nodes (%graph-nodes-table graph-a))
        (result (make-graph :metadata (graph-metadata graph-a))))
    (dolist (name (%graph-node-name-set graph-a))
      (add-node result (%copy-node-snapshot (gethash name nodes))))
    (dolist (edge (reverse (%graph-edges-list graph-a)))
      (unless (gethash (%edge-sort-key edge) b-edges)
        (%readd-edge result edge)))
    result))

(defun graph-filter-nodes (graph predicate)
  "Return the subgraph of GRAPH induced by the nodes for which PREDICATE (called on
each node) is true, together with the edges among them (see GRAPH-SUBGRAPH)."
  (graph-subgraph graph
                  (let ((nodes (%graph-nodes-table graph)))
                    (loop for name in (%graph-node-name-set graph)
                          when (funcall predicate (gethash name nodes))
                          collect name))))

(defun %readd-edge-mapped (result edge name-function)
  (let ((added (add-edge result
                         (funcall name-function (edge-from edge))
                         (funcall name-function (edge-to edge))
                         :from-port (edge-from-port edge)
                         :to-port (edge-to-port edge))))
    (setf (edge-metadata added) (edge-metadata edge))
    added))

(defun %graph-edge-tuple-map (graph)
  "Edge-identity-key -> (FROM FROM-PORT TO TO-PORT) tuple for every edge of GRAPH."
  (let ((map (make-hash-table :test #'equal)))
    (dolist (edge (%graph-edges-list graph) map)
      (setf (gethash (%edge-sort-key edge) map)
            (list (edge-from edge) (edge-from-port edge)
                  (edge-to edge) (edge-to-port edge))))))

(defun %edge-tuple-diff (present-map absent-map)
  "The edge tuples in PRESENT-MAP whose identity is absent from ABSENT-MAP, ordered
by identity key."
  (let ((result '()))
    (maphash (lambda (key tuple)
               (unless (gethash key absent-map)
                 (push (cons key tuple) result)))
             present-map)
    (mapcar #'cdr (sort result #'string< :key #'car))))

(defun graph-diff (graph-a graph-b)
  "Return a plist describing how GRAPH-B differs from GRAPH-A:
  (:added-nodes (...) :removed-nodes (...)
   :added-edges ((from from-port to to-port) ...) :removed-edges (...)).
Added items are present in GRAPH-B but not GRAPH-A; removed items are present in
GRAPH-A but not GRAPH-B. Edges are compared by identity (endpoints and ports).
This is the structured-diff complement to GRAPH-DIFFERENCE."
  (let ((a-names (%graph-name-set graph-a))
        (b-names (%graph-name-set graph-b))
        (a-edges (%graph-edge-tuple-map graph-a))
        (b-edges (%graph-edge-tuple-map graph-b)))
    (list :added-nodes (loop for name in (%graph-node-name-set graph-b)
                             unless (gethash name a-names) collect name)
          :removed-nodes (loop for name in (%graph-node-name-set graph-a)
                               unless (gethash name b-names) collect name)
          :added-edges (%edge-tuple-diff b-edges a-edges)
          :removed-edges (%edge-tuple-diff a-edges b-edges))))

(defun graph-map-nodes (graph name-function)
  "Return a new graph with every node name replaced by (FUNCALL NAME-FUNCTION NAME)
and every incident edge rewritten accordingly. NAME-FUNCTION must be injective
(distinct names must map to distinct names), or ADD-NODE will signal a duplicate.
Ports and metadata are preserved; GRAPH is not modified."
  (let ((result (make-graph :metadata (graph-metadata graph)))
        (nodes (%graph-nodes-table graph)))
    (dolist (name (%graph-node-name-set graph))
      (let ((snapshot (%copy-node-snapshot (gethash name nodes))))
        (setf (node-name snapshot) (funcall name-function name))
        (add-node result snapshot)))
    (dolist (edge (reverse (%graph-edges-list graph)))
      (%readd-edge-mapped result edge name-function))
    result))
