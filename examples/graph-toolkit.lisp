;;; Graph analysis and visualization toolkit.
;;;
;;; Run with:
;;;   sbcl --script examples/graph-toolkit.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

(defun names (nodes)
  (mapcar #'cl-dataflow-kit:node-name nodes))

;; A small dependency DAG:  a -> b,c ; b,c -> d
(defparameter *dag* (cl-dataflow-kit:make-graph))
(dolist (name '("a" "b" "c" "d"))
  (cl-dataflow-kit:add-node *dag* (cl-dataflow-kit:make-node name)))
(dolist (edge '(("a" "b") ("a" "c") ("b" "d") ("c" "d")))
  (cl-dataflow-kit:add-edge *dag* (first edge) (second edge)))

(format t "~&Order: ~D  Size: ~D~%"
        (cl-dataflow-kit:graph-order *dag*)
        (cl-dataflow-kit:graph-size *dag*))

;; Topological generations show which stages can run in parallel.
(format t "~&Generations: ~S~%"
        (mapcar #'names (cl-dataflow-kit:graph-topological-generations *dag*)))

;; Shortest hop distance across the graph.
(format t "~&Distance a -> d: ~D~%"
        (cl-dataflow-kit:graph-distance *dag* "a" "d"))

;; The transpose reverses every dependency (useful for "what feeds this?").
(format t "~&Transposed successors of d: ~S~%"
        (names (cl-dataflow-kit:graph-successors (cl-dataflow-kit:graph-transpose *dag*) "d")))

;; A cyclic graph collapses into a single strongly connected component.
(defparameter *cycle* (cl-dataflow-kit:make-graph))
(dolist (name '("x" "y" "z"))
  (cl-dataflow-kit:add-node *cycle* (cl-dataflow-kit:make-node name)))
(dolist (edge '(("x" "y") ("y" "z") ("z" "x")))
  (cl-dataflow-kit:add-edge *cycle* (first edge) (second edge)))
(format t "~&Strongly connected components: ~S~%"
        (cl-dataflow-kit:graph-strongly-connected-components *cycle*))

;; Render the DAG for Graphviz and Mermaid.
(format t "~&--- DOT ---~%~A" (cl-dataflow-kit:graph->dot *dag* :name "deps"))
(format t "~&--- Mermaid ---~%~A" (cl-dataflow-kit:graph->mermaid *dag*))
