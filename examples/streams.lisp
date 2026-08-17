;;; Lazy stream / transducer pipelines.
;;;
;;; Run with:
;;;   sbcl --script examples/streams.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

;; Streams are lazy: only the elements a consumer pulls are ever produced. Here
;; the source is a million-element range, but map/filter/take force just three.
(format t "~&First 3 even squares: ~S~%"
        (cl-dataflow-kit:stream-collect
          (cl-dataflow-kit:stream-take 3
            (cl-dataflow-kit:stream-filter #'evenp
              (cl-dataflow-kit:stream-map (lambda (x) (* x x))
                (cl-dataflow-kit:stream-range 1 1000000))))))

;; A running total with stream-scan (the seed is emitted first).
(format t "~&Running totals: ~S~%"
        (cl-dataflow-kit:stream-collect
          (cl-dataflow-kit:stream-scan #'+ 0 (cl-dataflow-kit:stream-of 1 2 3 4))))

;; flat-map expands each element into a sub-stream and concatenates them.
(format t "~&Flat-mapped: ~S~%"
        (cl-dataflow-kit:stream-collect
          (cl-dataflow-kit:stream-flat-map
            (lambda (x) (cl-dataflow-kit:stream-of x (* x 10)))
            (cl-dataflow-kit:stream-of 1 2 3))))

;; distinct + reduce over a stream.
(format t "~&Sum of distinct values: ~D~%"
        (cl-dataflow-kit:stream-reduce #'+ 0
          (cl-dataflow-kit:stream-distinct (cl-dataflow-kit:stream-of 1 2 2 3 3 3 4))))
