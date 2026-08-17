;;; Advanced graph analysis: paths, metrics, and serialization.
;;;
;;; Run with:
;;;   sbcl --script examples/graph-analysis-advanced.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

;; A small build-dependency DAG.
(defparameter *graph* (cl-dataflow-kit:make-graph))
(dolist (name '("fetch" "compile" "test" "lint" "package"))
  (cl-dataflow-kit:add-node *graph* (cl-dataflow-kit:make-node name)))
(dolist (edge '(("fetch" "compile") ("compile" "test") ("compile" "lint")
                ("test" "package") ("lint" "package") ("fetch" "package")))
  (cl-dataflow-kit:add-edge *graph* (first edge) (second edge)))

;; The critical path is the longest chain of dependencies.
(format t "~&Critical path: ~S~%" (cl-dataflow-kit:graph-longest-path *graph*))

;; Topological rank = earliest layer each step can run in.
(format t "~&Topological rank: ~S~%" (cl-dataflow-kit:graph-topological-rank *graph*))

;; The transitive reduction drops the redundant fetch -> package edge.
(format t "~&Edges after transitive reduction: ~D (was ~D)~%"
        (cl-dataflow-kit:graph-size (cl-dataflow-kit:graph-transitive-reduction *graph*))
        (cl-dataflow-kit:graph-size *graph*))

;; Weighted shortest distance using edge metadata (defaulting to 1 per hop here).
(format t "~&Hops fetch -> package: ~D~%"
        (cl-dataflow-kit:graph-weighted-distance *graph* "fetch" "package"))

;; Whole-graph metrics.
(format t "~&Density: ~A  Bipartite? ~A~%"
        (cl-dataflow-kit:graph-density *graph*)
        (cl-dataflow-kit:graph-bipartite-p *graph*))

;; Structural serialization round-trips back to an equal graph.
(let ((rebuilt (cl-dataflow-kit:plist-to-graph (cl-dataflow-kit:graph-to-plist *graph*))))
  (format t "~&Round-trips to an equal graph? ~A~%"
          (cl-dataflow-kit:graph-equal-p *graph* rebuilt)))
