(in-package #:cl-dataflow-kit)

;;;; Plist serialisation for events, effects, and whole contexts. Graphs,
;;;; pipelines, and state machines use the same round-trip representation.
;;;; A context's observable record (stored node values, events, effects, trace,
;;;; metadata, state, result) serialises; effect handlers are runtime closures and
;;;; are deliberately excluded, so a rebuilt context has an empty handler table.

(defun event-to-plist (event)
  "Serialise EVENT to a plist (:type ... :payload ... :metadata ... :trace-index ...)."
  (list :type (event-type event)
        :payload (event-payload event)
        :metadata (event-metadata event)
        :trace-index (event-trace-index event)))

(defun plist-to-event (plist)
  "Rebuild an event from a plist produced by EVENT-TO-PLIST."
  (make-event (getf plist :type)
              :payload (getf plist :payload)
              :metadata (getf plist :metadata)
              :trace-index (getf plist :trace-index)))

(defun effect-to-plist (effect)
  "Serialise EFFECT to a plist (:type ... :payload ... :metadata ... :trace-index ...
:result ...)."
  (list :type (effect-type effect)
        :payload (effect-payload effect)
        :metadata (effect-metadata effect)
        :trace-index (effect-trace-index effect)
        :result (effect-result effect)))

(defun plist-to-effect (plist)
  "Rebuild an effect from a plist produced by EFFECT-TO-PLIST."
  (make-effect (getf plist :type)
               :payload (getf plist :payload)
               :metadata (getf plist :metadata)
               :trace-index (getf plist :trace-index)
               :result (getf plist :result)))

(defun %context-values-to-plists (context)
  (let ((result '()))
    (maphash (lambda (key value)
               (push (list :node (first key) :port (second key) :value value) result))
             (context-values context))
    (sort result #'string<
          :key (lambda (entry)
                 (format nil "~A~C~A" (getf entry :node) #\Nul (getf entry :port))))))

(defun context-to-plist (context)
  "Serialise CONTEXT's observable state to a plist
  (:state ... :result ... :metadata ... :values (...) :events (...) :effects (...)
   :trace (...)),
with events/effects/trace in chronological order. Effect handlers are runtime
closures and are NOT serialised."
  (list :state (context-state context)
        :result (context-result context)
        :metadata (context-metadata context)
        :values (%context-values-to-plists context)
        :events (mapcar #'event-to-plist (context-events-in-order context))
        :effects (mapcar #'effect-to-plist (context-effects-in-order context))
        :trace (context-trace-in-order context)))

(defun %plists-to-values-table (value-plists)
  (let ((table (%make-result-table)))
    (dolist (entry value-plists table)
      (setf (gethash (list (getf entry :node) (getf entry :port)) table)
            (getf entry :value)))))

(defun plist-to-context (plist)
  "Rebuild a context from a plist produced by CONTEXT-TO-PLIST. The reconstructed
context has an empty effect-handler table (handlers are not serialised)."
  (make-context
   :state (getf plist :state)
   :result (getf plist :result)
   :metadata (getf plist :metadata)
   :values (%plists-to-values-table (getf plist :values))
   :events (reverse (mapcar #'plist-to-event (getf plist :events)))
   :effects (reverse (mapcar #'plist-to-effect (getf plist :effects)))
   :trace (reverse (getf plist :trace))))
