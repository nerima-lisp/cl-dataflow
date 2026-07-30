(in-package #:cl-dataflow)

;;;; Weighted shortest-path algorithms over edge-metadata weights: Dijkstra's
;;;; single-target distance, all-destinations distances, and path
;;;; reconstruction.

(defun %validate-non-negative-edge-value (caller key value)
  (unless (and (realp value) (not (minusp value)))
    (%signal-invalid-input-error
      'non-negative-real
      value
      (format nil "~A ~A must be a non-negative real number."
              caller
              (%escaped-display-string key))))
  value)

(defun %edge-weight (edge weight-key default-weight caller)
  (let ((weight (getf (edge-metadata edge) weight-key default-weight)))
    (%validate-non-negative-edge-value caller weight-key weight)))

(defun %weighted-adjacency (graph weight-key default-weight)
  "Name -> list of (TO-NAME . COST). Parallel edges collapse to their cheapest."
  (let ((adjacency (%make-result-table)))
    (dolist (name (%graph-node-name-set graph))
      (setf (gethash name adjacency) (make-hash-table :test #'equal)))
    (dolist (edge (%graph-edges-list graph))
      (let* ((bucket (gethash (edge-from edge) adjacency))
             (cost (%edge-weight edge weight-key default-weight "GRAPH-WEIGHTED"))
             (existing (gethash (edge-to edge) bucket)))
        (when (or (null existing) (< cost existing))
          (setf (gethash (edge-to edge) bucket) cost))))
    (let ((result (%make-result-table)))
      (maphash (lambda (name bucket)
                 (setf (gethash name result)
                       (loop for to being the hash-keys of bucket using (hash-value cost)
                             collect (cons to cost))))
               adjacency)
      result)))

(defun %dijkstra-pick (distance settled)
  "The unsettled node in DISTANCE with the smallest tentative cost, or NIL."
  (let ((chosen nil)
        (best nil))
    (maphash (lambda (name cost)
               (unless (gethash name settled)
                 (when (or (null best) (< cost best))
                   (setf best cost chosen name))))
             distance)
    chosen))

(defun %dijkstra-relax (distance previous name name-cost neighbors settled)
  (dolist (edge neighbors)
    (let ((to (car edge))
          (candidate (+ name-cost (cdr edge))))
      (unless (gethash to settled)
        (let ((existing (gethash to distance)))
          (when (or (null existing) (< candidate existing))
            (setf (gethash to distance) candidate
                  (gethash to previous) name)))))))

(defun %dijkstra-run (from-name neighbors)
  "Run Dijkstra's algorithm from FROM-NAME over NEIGHBORS (as returned by
%WEIGHTED-ADJACENCY) to exhaustion, returning (VALUES DISTANCE PREVIOUS): hash
tables of the minimum cost to, and predecessor of, every node reached from
FROM-NAME. Every weighted shortest-path function in this file shares this
seed-then-settle-to-exhaustion loop and differs only in what it reads back out
of DISTANCE/PREVIOUS afterward, so PREVIOUS is always tracked even when a
caller only needs DISTANCE -- one extra SETF per relaxation is cheaper than a
second driver loop."
  (let ((distance (make-hash-table :test #'equal))
        (previous (make-hash-table :test #'equal))
        (settled (make-hash-table :test #'equal)))
    (%dijkstra-relax distance previous from-name 0 (gethash from-name neighbors) settled)
    (loop for name = (%dijkstra-pick distance settled)
          while name
          do (setf (gethash name settled) t)
             (%dijkstra-relax distance previous name (gethash name distance)
                              (gethash name neighbors) settled))
    (values distance previous)))

(defun graph-weighted-distance (graph from to &key weight-key default-weight)
  "Return the minimum total edge weight of a path from FROM to TO (traversing at
least one edge), or NIL when TO is unreachable. Each edge's weight is
(GETF (EDGE-METADATA EDGE) WEIGHT-KEY DEFAULT-WEIGHT); WEIGHT-KEY defaults to
:WEIGHT and DEFAULT-WEIGHT to 1, and weights must be non-negative. FROM = TO
resolves only through a cycle, matching GRAPH-DISTANCE."
  (let ((weight-key (or weight-key :weight))
        (default-weight (or default-weight 1))
        (from-name (%ensure-graph-node-name graph from))
        (to-name (%ensure-graph-node-name graph to)))
    (let ((neighbors (%weighted-adjacency graph weight-key default-weight)))
      (gethash to-name (%dijkstra-run from-name neighbors)))))

(defun graph-weighted-distances-from (graph from &key weight-key default-weight)
  "Return an alist (NAME . COST) of the minimum total edge weight from FROM to every
node reachable from it (weights from edge metadata exactly as in
GRAPH-WEIGHTED-DISTANCE). FROM appears only if a cycle returns to it. This is
Dijkstra to all targets -- the weighted, all-destinations companion to
GRAPH-DISTANCES-FROM. Ordered by name."
  (let ((weight-key (or weight-key :weight))
        (default-weight (or default-weight 1))
        (from-name (%ensure-graph-node-name graph from)))
    (let* ((neighbors (%weighted-adjacency graph weight-key default-weight))
           (distance (%dijkstra-run from-name neighbors)))
      (sort (loop for name being the hash-keys of distance using (hash-value cost)
                  collect (cons name cost))
            #'string< :key #'car))))

(defun %reconstruct-weighted-path (previous from to)
  "Rebuild the FROM ... TO node sequence from a Dijkstra PREVIOUS table, taking the
first step through PREVIOUS so a FROM = TO cycle yields the whole loop."
  (let ((path (list to))
        (cursor (gethash to previous)))
    (loop
      (push cursor path)
      (when (string= cursor from) (return))
      (setf cursor (gethash cursor previous)))
    path))

(defun graph-weighted-path (graph from to &key weight-key default-weight)
  "Return the node names of a minimum-weight path from FROM to TO (FROM first, TO
last), or NIL when TO is unreachable. Weights come from edge metadata exactly as in
GRAPH-WEIGHTED-DISTANCE, and FROM = TO resolves only through a cycle."
  (let ((weight-key (or weight-key :weight))
        (default-weight (or default-weight 1))
        (from-name (%ensure-graph-node-name graph from))
        (to-name (%ensure-graph-node-name graph to)))
    (let ((neighbors (%weighted-adjacency graph weight-key default-weight)))
      (multiple-value-bind (distance previous) (%dijkstra-run from-name neighbors)
        (when (nth-value 1 (gethash to-name distance))
          (%reconstruct-weighted-path previous from-name to-name))))))
