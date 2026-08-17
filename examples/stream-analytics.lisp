;;; Stream analytics: grouping, frequencies, windowing, and aggregation.
;;;
;;; Run with:
;;;   sbcl --script examples/stream-analytics.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

(defparameter *events*
  (cl-dataflow-kit:stream-of :click :view :click :click :view :purchase :view))

;; Count how often each event type occurs.
(format t "~&Frequencies: ~S~%" (cl-dataflow-kit:stream-frequencies *events*))

;; Group a numeric stream by parity.
(format t "~&Grouped by parity: ~S~%"
        (cl-dataflow-kit:stream-group-by #'evenp (cl-dataflow-kit:stream-of 1 2 3 4 5 6)))

;; Partition into matches / non-matches.
(multiple-value-bind (evens odds)
    (cl-dataflow-kit:stream-partition #'evenp (cl-dataflow-kit:stream-of 1 2 3 4 5 6))
  (format t "~&Evens: ~S  Odds: ~S~%" evens odds))

;; Sliding windows over a lazy range, then average each window.
(format t "~&Window averages: ~S~%"
        (cl-dataflow-kit:stream-collect
          (cl-dataflow-kit:stream-map
            (lambda (window) (cl-dataflow-kit:stream-average (cl-dataflow-kit:list->stream window)))
            (cl-dataflow-kit:stream-window 3 (cl-dataflow-kit:stream-range 1 7)))))

;; The whole-stream average.
(format t "~&Mean of 1..100: ~A~%"
        (cl-dataflow-kit:stream-average (cl-dataflow-kit:stream-range 1 101)))
