(in-package #:cl-dataflow-kit)

;;;; Eulerian trail discovery over the directed multigraph via Hierholzer's
;;;; algorithm, after checking in/out-degree balance.

(defun %eulerian-start (graph out-degree in-degree)
  "Return the node an Eulerian trail must start from given the OUT-DEGREE and
IN-DEGREE tables, or NIL when the degree balance rules out any trail. A closed
trail (every node balanced) may start at any node with an outgoing edge; an open
trail needs exactly one node with one more out- than in-edge (the start) and one
with the reverse (the end)."
  (let ((surplus '())
        (deficit '())
        (unbalanced 0))
    (dolist (name (graph-node-names graph))
      (let ((difference (- (gethash name out-degree) (gethash name in-degree))))
        (cond ((= difference 1) (push name surplus))
              ((= difference -1) (push name deficit))
              ((/= difference 0) (incf unbalanced)))))
    (cond
      ((plusp unbalanced) nil)
      ((and (null surplus) (null deficit))
       (find-if (lambda (name) (plusp (gethash name out-degree)))
                (graph-node-names graph)))
      ((and (= (length surplus) 1) (= (length deficit) 1))
       (first surplus))
      (t nil))))

(defun %hierholzer-trail (adjacency start)
  "Trace an Eulerian trail from START through ADJACENCY, a node -> mutable list of
successor names consumed one edge at a time. Returns the node sequence in order.
Iterative (explicit stack), so long trails never grow the control stack."
  (let ((stack (list start))
        (trail '()))
    (loop while stack
          do (let ((node (car stack)))
               (if (gethash node adjacency)
                   (push (pop (gethash node adjacency)) stack)
                   (push (pop stack) trail))))
    trail))

(defun graph-eulerian-path (graph)
  "Return an Eulerian trail of GRAPH -- a sequence of node names traversing every
edge exactly once -- or NIL when none exists. Works on the directed multigraph, so
parallel edges are each used once; among the choices the name-least successor is
taken first, making the result deterministic. Uses Hierholzer's algorithm after
checking the in/out-degree balance, and confirms every edge was reached (a
disconnected edge set has no trail), so it stays linear and stack-safe."
  (let ((edges (%graph-edges-list graph))
        (adjacency (%make-result-table))
        (out-degree (%make-result-table))
        (in-degree (%make-result-table)))
    (dolist (name (graph-node-names graph))
      (setf (gethash name adjacency) '()
            (gethash name out-degree) 0
            (gethash name in-degree) 0))
    (dolist (edge edges)
      (let ((from (edge-from edge))
            (to (edge-to edge)))
        (push to (gethash from adjacency))
        (incf (gethash from out-degree))
        (incf (gethash to in-degree))))
    (dolist (name (graph-node-names graph))
      (setf (gethash name adjacency) (sort (gethash name adjacency) #'string<)))
    (let ((start (%eulerian-start graph out-degree in-degree)))
      (if (null start)
          nil
          (let ((trail (%hierholzer-trail adjacency start)))
            (if (= (length trail) (1+ (length edges)))
                trail
                nil))))))
