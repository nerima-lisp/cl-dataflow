(in-package #:cl-dataflow)

;;;; Simple-path enumeration and cycle discovery: every FROM->TO path with no
;;;; repeated node, and one ordered cycle witness via the strongly connected
;;;; components. GRAPH-ALL-PATHS is an explicitly exponential enumerator meant
;;;; for small graphs; GRAPH-FIND-CYCLE reuses the (iterative) SCC + subgraph +
;;;; GRAPH-PATH machinery so it stays safe on deep graphs.

(defun %path-sort-key (path)
  (format nil "~{~A~}"
          (loop for name in path
                collect name
                collect #\Nul)))

(defun %validate-non-negative-limit (name value)
  (when (and value (or (not (integerp value)) (minusp value)))
    (%signal-invalid-input-error
      '(or null (integer 0 *))
      value
      (format nil "~A must be NIL or a non-negative integer." name))))

(defun %signal-path-limit-exceeded (limit)
  (%signal-invalid-input-error
    'path-count-within-max-paths
    limit
    (format nil "GRAPH-ALL-PATHS exceeded MAX-PATHS (~D)." limit)))

(defun graph-all-paths (graph from to &key (max-paths 10000) max-depth)
  "Return every simple path (no repeated node) from FROM to TO as a list of
name-lists, ordered deterministically. FROM = TO yields the single trivial path
(FROM). Enumeration is exponential in the worst case and intended for small graphs;
MAX-PATHS bounds the number of returned paths (NIL disables the bound) and
MAX-DEPTH bounds the number of edges in a path. Signals NODE-NOT-FOUND-ERROR for
unknown endpoints."
  (%validate-non-negative-limit :max-paths max-paths)
  (%validate-non-negative-limit :max-depth max-depth)
  (let ((from-name (%ensure-graph-node-name graph from))
        (to-name (%ensure-graph-node-name graph to)))
    (when (eql max-paths 0)
      (return-from graph-all-paths '()))
    (let ((successors (%graph-adjacency-snapshot graph :successors))
          (visited (make-hash-table :test #'equal))
          (results '())
          (path-count 0))
      (labels ((record-path (path)
                 (when (and max-paths (>= path-count max-paths))
                   (%signal-path-limit-exceeded max-paths))
                 (incf path-count)
                 (push (reverse path) results))
               (walk (current path depth)
                 (cond ((equal current to-name)
                        (record-path path))
                       ((and max-depth (>= depth max-depth))
                        nil)
                       (t
                        (dolist (next (gethash current successors))
                          (unless (gethash next visited)
                            (setf (gethash next visited) t)
                            (walk next (cons next path) (1+ depth))
                            (remhash next visited)))))))
        (setf (gethash from-name visited) t)
        (walk from-name (list from-name) 0))
      (sort (nreverse results) #'string< :key #'%path-sort-key))))

(defun %component-cyclic-p (graph component)
  (or (> (length component) 1)
      (graph-reachable-p graph (first component) (first component))))

(defun graph-find-cycle (graph)
  "Return the node names of one directed cycle in GRAPH (an ordered list whose last
element repeats the first), or NIL when GRAPH is acyclic. Uses the strongly
connected components and a shortest self-returning path within the first cyclic
component, so it is safe on deep graphs."
  (dolist (component (graph-strongly-connected-components graph) nil)
    (when (%component-cyclic-p graph component)
      (let ((start (first component)))
        (return (graph-path (graph-subgraph graph component) start start))))))
