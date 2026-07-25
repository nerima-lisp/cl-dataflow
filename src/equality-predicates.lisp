(in-package #:cl-dataflow)

(defmacro define-plist-equal-p (&body specs)
  "For each (NAME ARG-A ARG-B TO-PLIST DOCSTRING) in SPECS, define a two-argument
structural-equality predicate NAME comparing ARG-A and ARG-B via TO-PLIST -- the
runtime closures TO-PLIST already strips (node handlers, guards, actions, effect
handlers) are therefore ignored by every predicate in the family."
  `(progn
     ,@(mapcar (lambda (spec)
                 (destructuring-bind (name arg-a arg-b to-plist docstring) spec
                   `(defun ,name (,arg-a ,arg-b)
                      ,docstring
                      (equal (,to-plist ,arg-a) (,to-plist ,arg-b)))))
               specs)))

;;;; Structural equality predicates for graphs, pipelines, state machines, and
;;;; contexts, plus a state reachability predicate. Every equality predicate
;;;; compares deterministic plist serialisations via DEFINE-PLIST-EQUAL-P, so
;;;; runtime closures -- node handlers, guards, actions, effect handlers -- are
;;;; ignored.

(define-plist-equal-p
  (pipeline-equal-p pipeline-a pipeline-b pipeline-to-plist
   "Return true when PIPELINE-A and PIPELINE-B have the same structure: identical
graphs, stage order, and metadata. Node handlers are not compared (see
PIPELINE-TO-PLIST).")
  (state-machine-equal-p machine-a machine-b state-machine-to-plist
   "Return true when MACHINE-A and MACHINE-B have the same structure: identical
state, initial state, metadata, and transitions (by from/event/to/metadata). Guards
and actions are not compared (see STATE-MACHINE-TO-PLIST).")
  (context-equal-p context-a context-b context-to-plist
   "Return true when CONTEXT-A and CONTEXT-B have the same observable state: identical
stored values, events, effects, trace, metadata, state, and result. Effect handlers
are not compared (see CONTEXT-TO-PLIST).")
  (graph-equal-p graph-a graph-b graph-to-plist
   "Return true when GRAPH-A and GRAPH-B are structurally identical: the same nodes
(names, ports, metadata) and the same edges (endpoints, ports, metadata),
independent of insertion order. Node handlers are runtime closures and are not
compared (see GRAPH-TO-PLIST)."))

(defun state-machine-reachable-p (machine from to)
  "Return true when state TO is reachable from state FROM in MACHINE by following
zero or more transitions (so FROM = TO is trivially reachable). States are compared
case-insensitively."
  (and (member (%normalize-name to)
               (state-machine-reachable-states machine :from from)
               :test #'string-equal)
       t))

