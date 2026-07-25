(in-package #:cl-dataflow)

;;;; Maximum-flow / minimum-cut over edge-metadata capacities, computed by
;;;; Edmonds-Karp (breadth-first-augmenting Ford-Fulkerson).

(defun %capacity-network (graph capacity-key default-capacity)
  "Return (values RESIDUAL NEIGHBORS).  RESIDUAL maps a (FROM . TO) cons to its
summed edge capacity; NEIGHBORS maps each node to the list of nodes adjacent to
it in either direction, so a breadth-first search can also push flow back along
a saturated forward edge."
  (let ((residual (%make-result-table))
        (adjacency (%make-result-table)))
    (dolist (name (%graph-node-name-set graph))
      (setf (gethash name adjacency) (%make-result-table)))
    (dolist (edge (%graph-edges-list graph))
      (let ((from (edge-from edge))
            (to (edge-to edge))
            (capacity (%edge-weight edge capacity-key default-capacity "GRAPH-FLOW")))
        (incf (gethash (cons from to) residual 0) capacity)
        (setf (gethash to (gethash from adjacency)) t)
        (setf (gethash from (gethash to adjacency)) t)))
    (let ((neighbors (%make-result-table)))
      (maphash (lambda (name bucket)
                 (setf (gethash name neighbors)
                       (loop for other being the hash-keys of bucket
                             collect other)))
               adjacency)
      (values residual neighbors))))

(defun %augmenting-path (residual neighbors source sink)
  "Breadth-first search for a shortest augmenting path in the residual graph.
Return the predecessor map when SINK is reached, otherwise NIL."
  (let ((parent (%make-result-table)))
    (setf (gethash source parent) source)
    (with-fifo-queue (queue enqueue source)
      (loop while queue
            do (let ((node (pop queue)))
                 (dolist (next (gethash node neighbors))
                   (when (and (not (nth-value 1 (gethash next parent)))
                              (> (gethash (cons node next) residual 0) 0))
                     (setf (gethash next parent) node)
                     (enqueue next))))))
    (when (nth-value 1 (gethash sink parent))
      parent)))

(defun %augment-bottleneck (residual parent source sink)
  "The minimum residual capacity along the SOURCE->SINK path recorded in PARENT."
  (let ((bottleneck nil)
        (node sink))
    (loop until (equal node source)
          do (let* ((previous (gethash node parent))
                    (capacity (gethash (cons previous node) residual 0)))
               (setf bottleneck (if bottleneck (min bottleneck capacity) capacity))
               (setf node previous)))
    bottleneck))

(defun %augment-apply (residual parent source sink amount)
  "Push AMOUNT of flow along the SOURCE->SINK path in PARENT, decreasing forward
residuals and increasing the matching reverse residuals."
  (let ((node sink))
    (loop until (equal node source)
          do (let ((previous (gethash node parent)))
               (decf (gethash (cons previous node) residual 0) amount)
               (incf (gethash (cons node previous) residual 0) amount)
               (setf node previous)))))

(defun %max-flow-search (graph source-name sink-name capacity-key default-capacity)
  "Run Edmonds-Karp over GRAPH's capacity network and return
(values TOTAL RESIDUAL NEIGHBORS): the maximum flow value together with the
saturated residual capacities and adjacency, which callers such as the minimum
cut inspect after the search converges."
  (multiple-value-bind (residual neighbors)
      (%capacity-network graph capacity-key default-capacity)
    (let ((total 0))
      (loop for parent = (%augmenting-path residual neighbors
                                           source-name sink-name)
            while parent
            do (let ((bottleneck (%augment-bottleneck residual parent
                                                      source-name sink-name)))
                 (%augment-apply residual parent source-name sink-name
                                 bottleneck)
                 (incf total bottleneck)))
      (values total residual neighbors))))

(defun %residual-reachable (residual neighbors source)
  "The hash set of nodes reachable from SOURCE along positive-residual edges --
the source side of the minimum cut once Edmonds-Karp has saturated the network."
  (let ((seen (%make-result-table)))
    (setf (gethash source seen) t)
    (with-fifo-queue (queue enqueue source)
      (loop while queue
            do (let ((node (pop queue)))
                 (dolist (next (gethash node neighbors))
                   (when (and (not (nth-value 1 (gethash next seen)))
                              (> (gethash (cons node next) residual 0) 0))
                     (setf (gethash next seen) t)
                     (enqueue next))))))
    seen))

(defun %resolve-flow-endpoints (graph source sink capacity-key default-capacity)
  "Resolve and validate SOURCE/SINK against GRAPH and default CAPACITY-KEY/
DEFAULT-CAPACITY, returning (VALUES SOURCE-NAME SINK-NAME CAPACITY-KEY
DEFAULT-CAPACITY) -- the shared preamble GRAPH-MAX-FLOW and GRAPH-MIN-CUT both
need before running Edmonds-Karp."
  (let ((capacity-key (or capacity-key :capacity))
        (default-capacity (or default-capacity 1))
        (source-name (%node-designator-name source))
        (sink-name (%node-designator-name sink)))
    (%ensure-graph-node graph source-name)
    (%ensure-graph-node graph sink-name)
    (values source-name sink-name capacity-key default-capacity)))

(defun graph-max-flow (graph source sink &key capacity-key default-capacity)
  "The maximum flow value from SOURCE to SINK over edge-metadata capacities
(CAPACITY-KEY defaults to :capacity; a capacity-less edge contributes
DEFAULT-CAPACITY, itself defaulting to 1), computed by Edmonds-Karp -- the
breadth-first-augmenting form of Ford-Fulkerson.  Parallel edges' capacities
add.  Returns 0 when SINK is unreachable from SOURCE or when the two coincide.
Signals when either node is absent.  Runs in polynomial time and terminates on
cyclic graphs because every augmentation strictly saturates an edge."
  (multiple-value-bind (source-name sink-name capacity-key default-capacity)
      (%resolve-flow-endpoints graph source sink capacity-key default-capacity)
    (if (equal source-name sink-name)
        0
        (values (%max-flow-search graph source-name sink-name
                                  capacity-key default-capacity)))))

(defun graph-min-cut (graph source sink &key capacity-key default-capacity)
  "The minimum SOURCE-to-SINK cut as a list of directed (FROM TO) edge pairs
whose removal disconnects SINK from SOURCE and whose total capacity equals
GRAPH-MAX-FLOW.  Found by the max-flow min-cut theorem: after Edmonds-Karp
saturates the network, the cut is exactly the edges leaving the set of nodes
still reachable from SOURCE in the residual graph.  Parallel edges collapse to
one pair.  Empty when SINK is unreachable from SOURCE or the two coincide.
Capacity arguments match GRAPH-MAX-FLOW.  Ordered lexicographically."
  (multiple-value-bind (source-name sink-name capacity-key default-capacity)
      (%resolve-flow-endpoints graph source sink capacity-key default-capacity)
    (if (equal source-name sink-name)
        '()
        (multiple-value-bind (total residual neighbors)
            (%max-flow-search graph source-name sink-name
                              capacity-key default-capacity)
          (declare (ignore total))
          (let ((reachable (%residual-reachable residual neighbors source-name))
                (crossings (%make-result-table)))
            (dolist (edge (%graph-edges-list graph))
              (let ((from (edge-from edge))
                    (to (edge-to edge)))
                (when (and (nth-value 1 (gethash from reachable))
                           (not (nth-value 1 (gethash to reachable))))
                  (setf (gethash (cons from to) crossings) t))))
            (sort (loop for pair being the hash-keys of crossings
                        collect (list (car pair) (cdr pair)))
                  #'string<
                  :key (lambda (pair)
                         (format nil "~A~C~A" (first pair) #\Nul (second pair)))))))))
