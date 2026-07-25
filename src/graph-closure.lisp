(in-package #:cl-dataflow)

;;;; Reachability-derived graph algorithms: transitive closure/reduction,
;;;; topological rank, and longest (critical) path. Structural traversals
;;;; reuse the one-shot adjacency snapshot and stay iterative.

(defun %closure-edge-ports (from-node to-node)
  "Default (from-port to-port) for a synthesised edge between two nodes: their
first output/input ports, which always exist. Synthesised edges therefore stay
valid even when nodes use non-default port names."
  (values (first (%node-outputs-list from-node))
          (first (%node-inputs-list to-node))))

(defun %add-derived-edge (result from-name to-name from-node to-node)
  (multiple-value-bind (from-port to-port) (%closure-edge-ports from-node to-node)
    (add-edge result from-name to-name :from-port from-port :to-port to-port)))

(defun graph-transitive-closure (graph)
  "Return a new graph with the same nodes as GRAPH and an edge A -> B for every
ordered pair where B is reachable from A through one or more edges (so a node on a
cycle gains a self-edge). Synthesised edges use each node's first ports; GRAPH is
not modified."
  (let ((names (%graph-node-name-set graph))
        (adjacency (%graph-adjacency-snapshot graph :successors))
        (nodes (%graph-nodes-table graph))
        (result (make-graph :metadata (graph-metadata graph))))
    (dolist (name names)
      (add-node result (%copy-node-snapshot (gethash name nodes))))
    (dolist (name names)
      (dolist (reached (%reachable-closure adjacency name))
        (%add-derived-edge result name reached
                           (gethash name nodes) (gethash reached nodes))))
    result))

(defun %reachable-through-successors-p (successors from to)
  "Whether TO is reachable from FROM through SUCCESSORS, with early exit."
  (let ((visited (%make-result-table))
        (worklist (copy-list (gethash from successors))))
    (loop while worklist do
      (let ((name (pop worklist)))
        (when (equal name to)
          (return-from %reachable-through-successors-p t))
        (unless (gethash name visited)
          (setf (gethash name visited) t)
          (dolist (successor (gethash name successors))
            (unless (gethash successor visited)
              (push successor worklist)))))))
  nil)

(defun graph-transitive-reduction (graph)
  "Return the transitive reduction of the (acyclic) GRAPH: the minimal edge set
with the same reachability. An edge U -> V is dropped when V is still reachable
from U through some other direct successor. Signals GRAPH-CYCLE-ERROR when GRAPH
is cyclic (the reduction is only unique on a DAG). GRAPH is not modified."
  (topological-sort graph)
  (let ((names (%graph-node-name-set graph))
        (successors (%graph-adjacency-snapshot graph :successors))
        (reachable (make-hash-table :test #'equal))
        (nodes (%graph-nodes-table graph))
        (result (make-graph :metadata (graph-metadata graph))))
    (dolist (name names)
      (add-node result (%copy-node-snapshot (gethash name nodes))))
    (labels ((reachable-p (from to)
               (let ((key (cons from to)))
                 (multiple-value-bind (cached present-p) (gethash key reachable)
                   (if present-p
                       cached
                       (setf (gethash key reachable)
                             (%reachable-through-successors-p successors from to)))))))
      (dolist (u names)
        (dolist (v (gethash u successors))
          (unless (some (lambda (w)
                          (and (not (equal w v))
                               (reachable-p w v)))
                        (gethash u successors))
            (%add-derived-edge result u v (gethash u nodes) (gethash v nodes))))))
    result))

(defun %longest-path-dp (order successors)
  "Return (VALUES DISTANCE-TABLE PREV-TABLE) for the longest path ending at each
node, over nodes in topological ORDER."
  (let ((distance (%make-result-table))
        (previous (%make-result-table)))
    (dolist (node order)
      (setf (gethash (node-name node) distance) 0))
    (dolist (node order)
      (let ((name (node-name node)))
        (dolist (successor (gethash name successors))
          (when (> (1+ (gethash name distance)) (gethash successor distance))
            (setf (gethash successor distance) (1+ (gethash name distance))
                  (gethash successor previous) name)))))
    (values distance previous)))

(defun graph-topological-rank (graph)
  "Return an alist (NAME . RANK) where RANK is the length of the longest path from
any source (indegree-0 node) to NAME; sources have rank 0. Signals
GRAPH-CYCLE-ERROR when GRAPH is cyclic. Ordered by name.

RANK is exactly GRAPH-LONGEST-PATH's per-node distance, so this shares
%LONGEST-PATH-DP's dynamic program rather than re-running the same longest-path
computation by hand; only the DISTANCE table is needed here, not the
path-reconstruction PREV table %LONGEST-PATH-DP also produces."
  (let* ((order (topological-sort graph))
         (distance (%longest-path-dp order (%graph-adjacency-snapshot graph :successors))))
    (sort (loop for name being the hash-keys of distance using (hash-value value)
                collect (cons name value))
          #'string< :key #'car)))

(defun %longest-path-endpoint (order distance)
  (let ((best-name nil)
        (best-distance -1))
    (dolist (node order best-name)
      (let ((name (node-name node)))
        (when (> (gethash name distance) best-distance)
          (setf best-distance (gethash name distance)
                best-name name))))))

(defun graph-longest-path (graph)
  "Return the node names of a longest path in the (acyclic) GRAPH, from a source to
the deepest reachable node. Returns NIL for an empty graph and a single-element
list for a graph with no edges. Signals GRAPH-CYCLE-ERROR when GRAPH is cyclic."
  (let ((order (topological-sort graph)))
    (multiple-value-bind (distance previous)
        (%longest-path-dp order (%graph-adjacency-snapshot graph :successors))
      (let ((endpoint (%longest-path-endpoint order distance)))
        (when endpoint
          (let ((path (list endpoint))
                (cursor endpoint))
            (loop for prior = (gethash cursor previous)
                  while prior
                  do (push prior path)
                     (setf cursor prior))
            path))))))
