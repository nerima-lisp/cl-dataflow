(in-package #:cl-dataflow.test)

(it-property "generated chain graphs preserve their topological invariant"
    ((weights (gen-list (gen-integer :min -1000 :max 1000)
                        :min-length 1
                        :max-length 30)))
  (let ((graph (make-graph))
        (nodes '()))
    (loop for weight in weights
          for index from 0
          for node = (make-node (format nil "node-~D-~D" index weight))
          do (add-node graph node)
              (push node nodes))
    (setf nodes (nreverse nodes))
    (loop for (source sink) on nodes
          while sink
          do (add-edge graph source sink))
    (cl-weave:expect graph :to-have-valid-topological-order)))
