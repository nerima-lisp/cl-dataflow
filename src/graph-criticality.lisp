(in-package #:cl-dataflow)

;;;; Critical-node and critical-connection analysis over the undirected view of a
;;;; graph: articulation points (cut vertices) and bridges (cut connections) --
;;;; the single points of failure in a dataflow graph. Both are computed the
;;;; recursion-free way: remove the element and recount weakly connected
;;;; components. This is O(V*(V+E)) / O(E*(V+E)) -- linear traversals over the
;;;; whole graph per candidate -- but never grows the control stack, matching the
;;;; library's deep-graph guarantees, and correctly handles multigraphs.

(defun graph-articulation-points (graph)
  "Return the names of the articulation points (cut vertices) of GRAPH's undirected
view, ordered lexicographically. A node is an articulation point when removing it
increases the number of weakly connected components -- i.e. it is a single point of
failure whose loss disconnects the graph."
  (let ((base (length (graph-connected-components graph))))
    (sort (loop for name in (graph-node-names graph)
                when (> (length (graph-connected-components (remove-node (copy-graph graph) name)))
                        base)
                collect name)
          #'string<)))

(defun %unordered-pair-key (a b)
  "A canonical key for the unordered pair {A, B} so both endpoint orderings match."
  (if (string< a b)
      (format nil "~A~C~A" a #\Nul b)
      (format nil "~A~C~A" b #\Nul a)))

(defun %undirected-edge-pairs (graph)
  "The distinct unordered adjacent node pairs (A . B) with A string< B, ignoring
self-loops."
  (let ((seen (make-hash-table :test #'equal))
        (pairs '()))
    (dolist (edge (%graph-edges-list graph) pairs)
      (let ((from (edge-from edge))
            (to (edge-to edge)))
        (unless (equal from to)
          (let ((key (%unordered-pair-key from to)))
            (unless (gethash key seen)
              (setf (gethash key seen) t)
              (push (if (string< from to) (cons from to) (cons to from)) pairs))))))))

(defun %graph-without-undirected-pair (graph from to)
  "A copy of GRAPH with every edge between FROM and TO (in either direction)
removed."
  (let ((copy (copy-graph graph))
        (key (%unordered-pair-key from to)))
    (setf (%graph-edges-list copy)
          (remove-if (lambda (edge)
                       (equal (%unordered-pair-key (edge-from edge) (edge-to edge)) key))
                     (%graph-edges-list copy)))
    copy))

(defun graph-bridges (graph)
  "Return the critical connections of GRAPH's undirected view as a list of (A B)
pairs (A string< B), ordered lexicographically. A connection is critical when
removing every edge between its two nodes leaves them in different weakly connected
components. For a simple graph this is exactly the set of bridges; a connection
carried by parallel edges is critical only if severing all of them disconnects it."
  (sort (loop for pair in (%undirected-edge-pairs graph)
              for reduced = (%graph-without-undirected-pair graph (car pair) (cdr pair))
              unless (graph-undirected-reachable-p reduced (car pair) (cdr pair))
              collect (list (car pair) (cdr pair)))
        (lambda (left right)
          (string< (%unordered-pair-key (first left) (second left))
                   (%unordered-pair-key (first right) (second right))))))

;;;; Dominator analysis of a rooted directed graph: for a source S, node D
;;;; dominates node N when every path from S to N passes through D, and the
;;;; immediate dominator IDOM(N) is the closest such D. Dominators are the
;;;; mandatory-waypoint counterpart of articulation points and the classical
;;;; substrate of dataflow analysis. Computed by the iterative Cooper-Harvey-
;;;; Kennedy algorithm over reverse postorder, with an explicit-stack DFS, so it
;;;; is polynomial and never grows the control stack on deep or cyclic graphs.

(defun %dominance-postorder (source successors)
  "Return (values RPO INDEX): the nodes reachable from SOURCE in reverse
postorder (SOURCE first) and a name -> position table. The depth-first search
uses an explicit work stack, so arbitrarily deep graphs are safe."
  (let ((visited (%make-result-table))
        (postorder '())
        (stack (list (cons source (gethash source successors)))))
    (setf (gethash source visited) t)
    (loop while stack
          do (let* ((frame (car stack))
                    (remaining (cdr frame)))
               (if remaining
                   (let ((next (car remaining)))
                     (setf (cdr frame) (cdr remaining))
                     (unless (gethash next visited)
                       (setf (gethash next visited) t)
                       (push (cons next (gethash next successors)) stack)))
                   (progn
                     (push (car frame) postorder)
                     (pop stack)))))
    (let ((index (%make-result-table))
          (position 0))
      (dolist (name postorder)
        (setf (gethash name index) position)
        (incf position))
      (values postorder index))))

(defun %dominance-intersect (a b index idom)
  "The nearest common dominator of A and B, found by walking both up the partial
immediate-dominator tree IDOM until the two fingers meet, comparing INDEX depths."
  (loop until (equal a b)
        do (loop while (> (gethash a index) (gethash b index))
                 do (setf a (gethash a idom)))
           (loop while (> (gethash b index) (gethash a index))
                 do (setf b (gethash b idom))))
  a)

(defun %immediate-dominators (root forward backward)
  "The immediate-dominator alist (NODE . IDOM) of the flow graph whose out-edges
are FORWARD and in-edges are BACKWARD, rooted at ROOT and ordered by node name.
FORWARD drives the reverse-postorder walk; BACKWARD supplies the predecessors
whose partial dominators are intersected. GRAPH-DOMINATORS passes successors as
FORWARD; GRAPH-POST-DOMINATORS passes predecessors, computing dominance on the
reversed graph. Nodes ROOT cannot reach through FORWARD are omitted."
  (let ((idom (%make-result-table)))
    (multiple-value-bind (rpo index) (%dominance-postorder root forward)
      (setf (gethash root idom) root)
      (let ((changed t))
        (loop while changed
              do (setf changed nil)
                 (dolist (node rpo)
                   (unless (equal node root)
                     (let ((new-idom nil))
                       (dolist (predecessor (gethash node backward))
                         (when (nth-value 1 (gethash predecessor idom))
                           (setf new-idom
                                 (if new-idom
                                     (%dominance-intersect predecessor new-idom
                                                           index idom)
                                     predecessor))))
                       (unless (equal (gethash node idom) new-idom)
                         (setf (gethash node idom) new-idom
                               changed t)))))))
      (sort (loop for node being the hash-keys of idom using (hash-value dominator)
                  unless (equal node root)
                  collect (cons node dominator))
            #'string< :key #'car))))

(defun graph-dominators (graph source)
  "Return the immediate-dominator map of GRAPH rooted at SOURCE as an alist
(NODE . IDOM), ordered by node name: for every node reachable from SOURCE other
than SOURCE itself, the closest node through which every path from SOURCE must
pass. Nodes unreachable from SOURCE are omitted. Uses the iterative
Cooper-Harvey-Kennedy dominance algorithm over reverse postorder, so it stays
polynomial and stack-safe on deep, cyclic graphs. Signals when SOURCE is absent."
  (let ((source-name (%node-designator-name source)))
    (%ensure-graph-node graph source-name)
    (multiple-value-bind (successors predecessors) (%graph-both-adjacencies graph)
      (%immediate-dominators source-name successors predecessors))))

(defun graph-post-dominators (graph sink)
  "Return the immediate-post-dominator map of GRAPH toward SINK as an alist
(NODE . IPDOM), ordered by node name: for every node that can reach SINK other
than SINK itself, the closest node through which every path from that node to
SINK must pass. It is exactly GRAPH-DOMINATORS on the reversed graph rooted at
SINK, so it shares the same iterative, stack-safe machinery; nodes that cannot
reach SINK are omitted. Signals when SINK is absent."
  (let ((sink-name (%node-designator-name sink)))
    (%ensure-graph-node graph sink-name)
    (multiple-value-bind (successors predecessors) (%graph-both-adjacencies graph)
      (%immediate-dominators sink-name predecessors successors))))
