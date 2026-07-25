(in-package #:cl-dataflow)

;;;; Execution-oriented state-machine helpers layered on the core runtime
;;;; (STEP-STATE-MACHINE) and the analysis layer. STATE-MACHINE-RUN-STATES and
;;;; STATE-MACHINE-ACCEPTS-P interpret an event sequence and inherit the runtime's
;;;; exact guard/transition semantics; STATE-MACHINE-EVENT-PATH is the event-level
;;;; analog of GRAPH-PATH, searching for the events that connect two states.

(defun state-machine-run-states (machine events &key context)
  "Return the list of states MACHINE visits while consuming EVENTS: the starting
state, then the state after each event that successfully steps. Stops at the first
event with no available (or guard-passing) transition, so the result has one entry
per successful step plus the initial state. MACHINE itself is not modified."
  (let ((current (copy-state-machine machine))
        (states (list (state-machine-state machine))))
    (dolist (event events (nreverse states))
      (handler-case
          (progn
            (setf current (step-state-machine current event :context context))
            (push (state-machine-state current) states))
        ((or invalid-transition-error guard-failed-error) ()
          (return (nreverse states)))))))

(defun state-machine-accepts-p (machine events accepting &key context)
  "Return true when consuming EVENTS from MACHINE steps successfully at every event
and lands in a state named in ACCEPTING (compared case-insensitively). A failed
transition anywhere yields NIL."
  (let ((current (copy-state-machine machine)))
    (dolist (event events)
      (handler-case
          (setf current (step-state-machine current event :context context))
        ((or invalid-transition-error guard-failed-error) ()
          (return-from state-machine-accepts-p nil))))
    (and (member (state-machine-state current) accepting :test #'string-equal)
         t)))

(defun %state-machine-transition-index (machine)
  "State -> list of (EVENT-TYPE . TO-STATE) for every transition of MACHINE."
  (let ((index (%make-result-table)))
    (dolist (state (state-machine-states machine))
      (setf (gethash state index) '()))
    (dolist (transition (%state-machine-transitions-list machine) index)
      (push (cons (transition-event-type transition) (transition-to transition))
            (gethash (transition-from transition) index)))))

(defun %reconstruct-event-path (parent start goal)
  "Walk the PARENT table (state -> (PREV-STATE . EVENT)) back from GOAL to START,
collecting the events in forward order."
  (let ((events '())
        (cursor goal))
    (loop until (string= cursor start)
          do (destructuring-bind (previous . event) (gethash cursor parent)
               (push event events)
               (setf cursor previous)))
    events))

(defun state-machine-event-path (machine from to)
  "Return a shortest list of event types that drives MACHINE from state FROM to
state TO through its transitions (ignoring guards), or NIL when TO is unreachable
from FROM. FROM = TO returns an empty list. This is the event-level analog of
GRAPH-PATH."
  (let ((start (%normalize-name from))
        (goal (%normalize-name to)))
    (let ((successors (%state-machine-transition-index machine)))
      (cond ((not (and (%state-machine-known-state-p start successors)
                       (%state-machine-known-state-p goal successors)))
             nil)
            ((string= start goal)
             '())
            (t
             (let ((parent (make-hash-table :test #'equal))
                   (seen (make-hash-table :test #'equal)))
               (setf (gethash start seen) t)
               (labels ((expand-frontier (frontier)
                          "Discover every unvisited destination reachable by one
transition from a state in FRONTIER, recording PARENT (PREV-STATE . EVENT) on
first discovery, and return the next frontier."
                          (let ((next '()))
                            (dolist (state frontier)
                              (dolist (edge (gethash state successors))
                                (let ((event (car edge))
                                      (destination (cdr edge)))
                                  (unless (gethash destination seen)
                                    (setf (gethash destination seen) t
                                          (gethash destination parent) (cons state event))
                                    (push destination next)))))
                            (nreverse next))))
                 (let ((frontier (list start)))
                   (loop
                     (unless frontier (return nil))
                     (setf frontier (expand-frontier frontier))
                     (when (gethash goal parent)
                       (return (%reconstruct-event-path parent start goal))))))))))))
