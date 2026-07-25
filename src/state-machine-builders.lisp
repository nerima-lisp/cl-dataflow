(in-package #:cl-dataflow)

;;;; State-machine serialisation, completeness checking, transition lookup, and
;;;; mutation/relabelling. Serialisation round-trips structure through plists;
;;;; guards and actions are runtime closures and are not serialised. Mutators keep
;;;; transitions normalised and copied exactly as MAKE-STATE-MACHINE does.
(defun %transition-plist (transition)
  (list
    :from
    (transition-from transition)
    :event-type
    (transition-event-type transition)
    :to
    (transition-to transition)
    :metadata
    (transition-metadata transition)))

(defun state-machine-to-plist (machine)
  "Serialise MACHINE's structure to a plist
  (:state ... :initial-state ... :metadata ... :transitions (transition-plist ...)).
Guards and actions are runtime closures and are NOT serialised, so a round trip
preserves states, events, targets, and metadata but not guarded behaviour."
  (list
    :state
    (state-machine-state machine)
    :initial-state
    (state-machine-initial-state machine)
    :metadata
    (state-machine-metadata machine)
    :transitions
    (mapcar #'%transition-plist (state-machine-transitions machine))))

(defun plist-to-state-machine (plist)
  "Rebuild a state machine from a plist produced by STATE-MACHINE-TO-PLIST.
Reconstructed transitions have no guard or action."
  (make-state-machine
    :state
    (getf plist :state)
    :initial-state
    (getf plist :initial-state)
    :metadata
    (getf plist :metadata)
    :transitions
    (mapcar
      (lambda (transition-plist)
        (make-transition
          (getf transition-plist :from)
          (getf transition-plist :event-type)
          (getf transition-plist :to)
          :metadata
          (getf transition-plist :metadata)))
      (getf plist :transitions))))

(defun state-machine-complete-p (machine)
  "Return true when MACHINE defines a transition for every (state, event-type)
pair -- i.e. its transition relation is total over its states and events. A machine
with no events is vacuously complete."
  (let ((defined (make-hash-table :test #'equal))
        (events (state-machine-event-types machine)))
    (dolist (transition (%state-machine-transitions-list machine))
      (setf (gethash
          (cons (transition-from transition) (transition-event-type transition))
          defined) t))
    (block done
      (dolist (state (state-machine-states machine) t)
        (dolist (event events)
          (unless (gethash (cons state event) defined)
            (return-from done nil)))))))

(defun state-machine-transition-for (machine state event-type)
  "Return the first transition of MACHINE from STATE on EVENT-TYPE (guards ignored),
or NIL when none matches. The result is an independent copy."
  (let ((normalized-state (%normalize-name state))
        (normalized-event (%normalize-name event-type)))
    (let ((transition
          (find-if
            (lambda (transition)
              (and
                (string-equal (transition-from transition) normalized-state)
                (string-equal (transition-event-type transition) normalized-event)))
            (%state-machine-transitions-list machine))))
      (when transition
        (%copy-state-transition transition)))))

(defun add-transition (machine from event-type to &key guard action metadata)
  "Append a transition FROM --EVENT-TYPE--> TO to MACHINE, in place, and return
MACHINE. Because guard selection picks the first matching transition, appended
transitions act as lower-priority fallbacks relative to existing ones."
  (setf (state-machine-transitions machine) (append
      (slot-value machine 'transitions)
      (list
        (make-transition
          from
          event-type
          to
          :guard
          guard
          :action
          action
          :metadata
          metadata))))
  machine)

(defun %transition-key (from event-type to)
  (format nil "~A~C~A~C~A" from #\Nul event-type #\Nul to))

(defun remove-transition (machine from event-type to)
  "Remove every transition FROM --EVENT-TYPE--> TO from MACHINE, in place, and
return MACHINE."
  (let ((target
        (%transition-key
          (%normalize-name from)
          (%normalize-name event-type)
          (%normalize-name to))))
    (setf (state-machine-transitions machine) (remove-if
        (lambda (transition)
          (string=
            target
            (%transition-key
              (transition-from transition)
              (transition-event-type transition)
              (transition-to transition))))
        (slot-value machine 'transitions)))
    machine))

(defun state-machine->graph (machine)
  "Return a graph modelling MACHINE's state structure: one node per state and one
edge per distinct (FROM, TO) transition pair (the first such transition's event type
is stored in the edge's metadata under :event). This bridges a state machine to the
graph-analysis toolkit -- cycles, strongly connected components, distances,
condensation, and so on all apply. Parallel transitions between the same pair of
states collapse to a single edge; a self-transition becomes a self-loop."
  (let ((graph (make-graph))
        (seen (make-hash-table :test #'equal)))
    (dolist (state (state-machine-states machine))
      (add-node graph (make-node state)))
    (dolist (transition (%state-machine-transitions-list machine))
      (let ((key (cons (transition-from transition) (transition-to transition))))
        (unless (gethash key seen)
          (setf (gethash key seen) t)
          (let ((edge (add-edge graph (transition-from transition) (transition-to transition))))
            (setf (edge-metadata edge) (list :event (transition-event-type transition)))))))
    graph))

(defun state-machine-relabel-state (machine old-state new-state)
  "Return a new state machine identical to MACHINE but with state OLD-STATE renamed
to NEW-STATE everywhere (current state, initial state, and every transition
endpoint). Guards and actions are carried over unchanged; MACHINE is not modified."
  (let ((old (%normalize-name old-state))
        (new (%normalize-name new-state)))
    (flet ((relabel (state)
              (if (string= state old) new
            state)))
      (make-state-machine
        :state
        (relabel (state-machine-state machine))
        :initial-state
        (relabel (state-machine-initial-state machine))
        :metadata
        (state-machine-metadata machine)
        :transitions
        (mapcar
          (lambda (transition)
            (make-transition
              (relabel (transition-from transition))
              (transition-event-type transition)
              (relabel (transition-to transition))
              :guard
              (transition-guard transition)
              :action
              (transition-action transition)
              :metadata
              (transition-metadata transition)))
          (%state-machine-transitions-list machine))))))
