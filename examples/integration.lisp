;;; End-to-end integration: one order-processing scenario that composes graphs,
;;; pipelines, streams, reactive subjects, a state machine, and serialization --
;;; demonstrating that the library's subsystems work together.
;;;
;;; Run with:
;;;   sbcl --script examples/integration.lisp
(load
  (merge-pathnames
    #P"bootstrap.lisp"
    (make-pathname :name nil :type nil :defaults *load-truename*)))

(defpackage #:cl-dataflow-kit-integration (:use #:cl #:cl-dataflow-kit))
(in-package #:cl-dataflow-kit-integration)

;;; 1. Model order processing as a pipeline: validate -> price -> ship.
(defparameter *pipeline*
  (define-pipeline ()
    (:node "validate" :handler (mapping-handler (lambda (order) order)))
    (:node "price" :handler (mapping-handler (lambda (order) (* order 10))))
    (:node "ship" :handler (mapping-handler (lambda (priced) priced)))
    (:edge "validate" "price")
    (:edge "price" "ship")))

;;; 2. Analyze the pipeline's structure as a graph.
(format t "~&Stages: ~S~%" (pipeline-stage-names *pipeline*))
(format t "~&Critical path: ~S~%" (graph-longest-path (pipeline-graph *pipeline*)))
(format t "~&Every stage is a single point of failure: ~S~%"
        (graph-articulation-points (pipeline-graph *pipeline*)))

;;; 3. Run a batch of orders through the pipeline (map-pipeline).
(defparameter *orders* '(3 7 12))
(defparameter *priced* (map-pipeline *pipeline* *orders*))
(format t "~&Priced orders: ~S~%" *priced*)

;;; 4. Stream analytics over the priced results (pull side).
(format t "~&Revenue: ~D  Mean: ~A~%"
        (stream-sum (list->stream *priced*))
        (stream-average (list->stream *priced*)))

;;; 5. Reactive live alerts for high-value orders (push side).
(let* ((orders (make-subject))
       (alerts (subject-collect (subject-filter orders (lambda (v) (> v 50))))))
  (dolist (value *priced*) (subject-emit orders value))
  (format t "~&High-value alerts (> 50): ~S~%" (funcall alerts)))

;;; 6. Track the order lifecycle with a state machine.
(defparameter *lifecycle*
  (make-state-machine
    :state "new"
    :transitions (list (make-transition "new" "validate" "validated")
                       (make-transition "validated" "price" "priced")
                       (make-transition "priced" "ship" "shipped"))))
(format t "~&Can a new order reach shipped? ~A~%"
        (state-machine-reachable-p *lifecycle* "new" "shipped"))
(format t "~&Driving events new -> shipped: ~S~%"
        (state-machine-event-path *lifecycle* "new" "shipped"))

;;; 7. Serialize a full run's context and confirm it round-trips.
(multiple-value-bind (result context)
    (run-pipeline-with-context *pipeline* :input 5)
  (format t "~&Single order 5 priced: ~D~%" result)
  (format t "~&Context round-trips through a plist: ~A~%"
          (context-equal-p context (plist-to-context (context-to-plist context)))))
