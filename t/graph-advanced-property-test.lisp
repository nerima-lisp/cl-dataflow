(in-package #:cl-dataflow.test)

;;;; Advanced cl-weave usage: custom matchers, richer generators, differential
;;;; property testing, and performance guards for the Prolog-backed graph layer.

;;; ---------------------------------------------------------------------------
;;; Custom matchers
;;; ---------------------------------------------------------------------------

(defmatcher :to-be-acyclic (graph expected)
  "Passes when GRAPH has a valid topological order (i.e. contains no cycle)."
  (declare (ignore expected))
  (handler-case
      (progn (topological-sort graph)
             (values t :acyclic :acyclic))
    (graph-cycle-error (condition)
      (values nil condition :acyclic))))

(defmatcher :to-reach (graph expected)
  "Passes when GRAPH reaches the second node from the first.
Usage: (expect graph :to-reach from to)."
  (destructuring-bind (from to) expected
    (values (and (graph-reachable-p graph from to) t)
            (list :from from :to to)
            (list :reachable t))))

;;; ---------------------------------------------------------------------------
;;; Random DAG helpers and a reference reachability oracle
;;; ---------------------------------------------------------------------------

(defun %node-label (index)
  (format nil "n~D" index))

(defun %forward-edge-pairs (node-count raw-pairs)
  "Project RAW-PAIRS of integers onto distinct forward edges (i . j) with i<j and
0<=i,j<NODE-COUNT. Forward-only edges guarantee an acyclic graph."
  (let ((seen (make-hash-table :test #'equal))
        (edges '()))
    (dolist (pair raw-pairs (nreverse edges))
      (let* ((a (mod (first pair) node-count))
             (b (mod (second pair) node-count))
             (i (min a b))
             (j (max a b)))
        (when (and (/= i j) (not (gethash (cons i j) seen)))
          (setf (gethash (cons i j) seen) t)
          (push (cons i j) edges))))))

(defun %build-dag (node-count edge-pairs)
  (let ((graph (make-graph)))
    (dotimes (index node-count)
      (add-node graph (make-node (%node-label index))))
    (dolist (pair edge-pairs)
      (add-edge graph (%node-label (car pair)) (%node-label (cdr pair))))
    graph))

(defun %reference-reachable-p (node-count edge-pairs from-index to-index)
  "Breadth-first transitive closure computed independently of the Prolog layer."
  (let ((successors (make-array node-count :initial-element nil))
        (visited (make-array node-count :initial-element nil)))
    (dolist (pair edge-pairs)
      (push (cdr pair) (aref successors (car pair))))
    (let ((worklist (list from-index))
          (found nil))
      (loop while (and worklist (not found)) do
        (let ((current (pop worklist)))
          (dolist (next (aref successors current))
            (when (= next to-index)
              (setf found t))
            (unless (aref visited next)
              (setf (aref visited next) t)
              (push next worklist)))))
      found)))

;;; ---------------------------------------------------------------------------
;;; Property tests
;;; ---------------------------------------------------------------------------

(it-property "random DAGs are acyclic and topologically well ordered"
    ((node-count (gen-integer :min 1 :max 12))
     (raw-pairs (gen-list (gen-tuple (gen-integer :min 0 :max 40)
                                     (gen-integer :min 0 :max 40))
                          :min-length 0 :max-length 40)))
  (let ((graph (%build-dag node-count (%forward-edge-pairs node-count raw-pairs))))
    (with-soft-assertions
      (expect graph :to-be-acyclic)
      (expect graph :to-have-valid-topological-order))))

(it-property "graph-reachable-p agrees with a reference transitive closure"
    ((node-count (gen-integer :min 2 :max 10))
     (raw-pairs (gen-list (gen-tuple (gen-integer :min 0 :max 40)
                                     (gen-integer :min 0 :max 40))
                          :min-length 0 :max-length 40)))
  (let* ((edge-pairs (%forward-edge-pairs node-count raw-pairs))
         (graph (%build-dag node-count edge-pairs)))
    (dotimes (from node-count)
      (dotimes (to node-count)
        (let ((expected (%reference-reachable-p node-count edge-pairs from to))
              (actual (and (graph-reachable-p graph (%node-label from) (%node-label to)) t)))
          (is (eq expected actual)))))))

(it-property "graph-descendants and graph-ancestors match a reference closure"
    ((node-count (gen-integer :min 2 :max 10))
     (raw-pairs (gen-list (gen-tuple (gen-integer :min 0 :max 40)
                                     (gen-integer :min 0 :max 40))
                          :min-length 0 :max-length 40)))
  (let* ((edge-pairs (%forward-edge-pairs node-count raw-pairs))
         (graph (%build-dag node-count edge-pairs)))
    (dotimes (v node-count)
      (let ((expected-descendants
              (sort (loop for u below node-count
                          when (%reference-reachable-p node-count edge-pairs v u)
                            collect (%node-label u))
                    #'string<))
            (actual-descendants
              (sort (mapcar #'node-name (graph-descendants graph (%node-label v)))
                    #'string<))
            (expected-ancestors
              (sort (loop for u below node-count
                          when (%reference-reachable-p node-count edge-pairs u v)
                            collect (%node-label u))
                    #'string<))
            (actual-ancestors
              (sort (mapcar #'node-name (graph-ancestors graph (%node-label v)))
                    #'string<)))
        (is (equal expected-descendants actual-descendants))
        (is (equal expected-ancestors actual-ancestors))))))

;;; ---------------------------------------------------------------------------
;;; Cross-checking against cl-weave's logic-programming engine
;;;
;;; The BFS reference above and GRAPH-DESCENDANTS/-ANCESTORS themselves (which
;;; materialize into a CL-PROLOG rulebase; see GRAPH-RUNTIME-PROLOG.LISP) both
;;; compute a transitive closure, but neither is independent of the other's
;;; general shape. cl-weave ships its own small unification/backtracking logic
;;; engine (LOGIC-QUERY); querying a recursive REACHABLE rule over it is a
;;; third, structurally unrelated implementation of the same relation, so it
;;; makes a stronger oracle than one more hand-rolled traversal would.
;;; ---------------------------------------------------------------------------

(defun %edge-facts (edge-pairs)
  (mapcar (lambda (pair) (list :edge (car pair) (cdr pair))) edge-pairs))

(defparameter +reachable-rules+
  (list '(:- (:reachable ?a ?b) (:edge ?a ?b))
        '(:- (:reachable ?a ?b) (:edge ?a ?m) (:reachable ?m ?b)))
  "REACHABLE/2 defined the standard Datalog way: a base case over direct edges,
and a recursive case that walks one edge and defers back to itself.")

(defun %logic-descendant-indices (edge-pairs from-index)
  (let ((solutions
          (logic-query (append (%edge-facts edge-pairs) +reachable-rules+)
                       (list (list :reachable from-index '?to)))))
    (remove-duplicates (mapcar (lambda (solution) (cdr (assoc '?to solution))) solutions))))

(it-property "graph-descendants agrees with a cl-weave logic-program transitive closure"
    ((node-count (gen-integer :min 2 :max 8))
     (raw-pairs (gen-list (gen-tuple (gen-integer :min 0 :max 20)
                                     (gen-integer :min 0 :max 20))
                          :min-length 0 :max-length 20)))
  (let* ((edge-pairs (%forward-edge-pairs node-count raw-pairs))
         (graph (%build-dag node-count edge-pairs)))
    (dotimes (v node-count)
      (let ((expected
              (sort (mapcar #'%node-label (%logic-descendant-indices edge-pairs v))
                    #'string<))
            (actual
              (sort (mapcar #'node-name (graph-descendants graph (%node-label v)))
                    #'string<)))
        (is (equal expected actual))))))

(defun %label-index (label)
  (parse-integer (subseq label 1)))

(it-property "graph-path returns a valid witnessing path exactly when reachable"
    ((node-count (gen-integer :min 2 :max 10))
     (raw-pairs (gen-list (gen-tuple (gen-integer :min 0 :max 40)
                                     (gen-integer :min 0 :max 40))
                          :min-length 0 :max-length 40)))
  (let* ((edge-pairs (%forward-edge-pairs node-count raw-pairs))
         (graph (%build-dag node-count edge-pairs)))
    (dotimes (from node-count)
      (dotimes (to node-count)
        (let ((reachable (and (graph-reachable-p graph (%node-label from) (%node-label to)) t))
              (path (graph-path graph (%node-label from) (%node-label to))))
          (is (eq (and path t) reachable))
          (when path
            (is (equal (first path) (%node-label from)))
            (is (equal (car (last path)) (%node-label to)))
            (loop for (a b) on path
                  while b
                  do (is (not (null (member (cons (%label-index a) (%label-index b))
                                            edge-pairs :test #'equal)))))))))))

(it-property "topological-sort is deterministic across repeated calls"
    ((node-count (gen-integer :min 1 :max 12))
     (raw-pairs (gen-list (gen-tuple (gen-integer :min 0 :max 40)
                                     (gen-integer :min 0 :max 40))
                          :min-length 0 :max-length 40)))
  (let ((graph (%build-dag node-count (%forward-edge-pairs node-count raw-pairs))))
    (is (equal (mapcar #'node-name (topological-sort graph))
               (mapcar #'node-name (topological-sort graph))))))

;;; ---------------------------------------------------------------------------
;;; Performance / anti-DoS guards
;;;
;;; A long chain exercises the paths hardened against superlinear blow-up: the
;;; single bulk edge query in topological-sort (vs. one query per node), its
;;; merge-based ready queue (vs. a full re-sort per iteration), and the explicit
;;; work list in graph-reachable-p (vs. recursion that overflowed the stack on a
;;; deep chain). The bound is generous so it flags catastrophic regressions
;;; without being timing-flaky.
;;; ---------------------------------------------------------------------------

(defun %build-chain (length)
  (let ((graph (make-graph)))
    (dotimes (index length)
      (add-node graph (make-node (%node-label index))))
    (dotimes (index (1- length))
      (add-edge graph (%node-label index) (%node-label (1+ index))))
    graph))

(deftest deep-chain-topological-sort-and-reachability-stay-cheap
  (let* ((length 3000)
         (graph (%build-chain length))
         (last-label (%node-label (1- length))))
    (expect (lambda () (topological-sort graph)) :to-run-under-ms 8000)
    (expect (lambda () (graph-reachable-p graph "n0" last-label)) :to-run-under-ms 8000)
    (is (graph-reachable-p graph "n0" last-label))
    (is (not (graph-reachable-p graph last-label "n0")))))

(defun %lattice-label (layer index)
  (format nil "L~D-~D" layer index))

(defun %build-lattice (layers width)
  "Fully-connected layered DAG: every node in a layer feeds every node in the
next. The number of distinct source-to-sink paths is WIDTH^(LAYERS-1), so a
path-enumerating reachability would be exponential while a visited-set traversal
stays linear in nodes and edges."
  (let ((graph (make-graph)))
    (dotimes (layer layers)
      (dotimes (index width)
        (add-node graph (make-node (%lattice-label layer index)))))
    (dotimes (layer (1- layers))
      (dotimes (i width)
        (dotimes (j width)
          (add-edge graph (%lattice-label layer i) (%lattice-label (1+ layer) j)))))
    graph))

(deftest reachability-does-not-blow-up-on-exponential-path-lattices
  ;; 4^9 = 262144 distinct source->sink paths. This is exactly the shape a naive
  ;; recursive reachable/2 rule or a per-path visited list would blow up on; the
  ;; shared-visited work list must stay near-instant.
  (let* ((graph (%build-lattice 10 4))
         (source (%lattice-label 0 0))
         (sink (%lattice-label 9 0)))
    (expect (lambda () (graph-reachable-p graph source sink)) :to-run-under-ms 4000)
    (expect (lambda () (graph-descendants graph source)) :to-run-under-ms 4000)
    (expect (lambda () (graph-path graph source sink)) :to-run-under-ms 4000)
    (is (graph-reachable-p graph source sink))
    (let ((path (graph-path graph source sink)))
      (is (equal (first path) source))
      (is (equal (car (last path)) sink)))))

(deftest reachability-terminates-on-large-cycles
  ;; A directed ring: every node reaches every other node, including itself,
  ;; through the cycle. The shared VISITED set must make this linear, not loop.
  (let* ((size 1500)
         (graph (make-graph)))
    (dotimes (index size)
      (add-node graph (make-node (%node-label index))))
    (dotimes (index size)
      (add-edge graph (%node-label index) (%node-label (mod (1+ index) size))))
    (expect (lambda () (graph-reachable-p graph "n0" (%node-label (1- size))))
            :to-run-under-ms 4000)
    (expect (lambda () (graph-reachable-p graph "n0" "n0")) :to-run-under-ms 4000)
    (is (graph-reachable-p graph "n0" "n0"))
    (is (graph-reachable-p graph "n0" (%node-label (1- size))))))
