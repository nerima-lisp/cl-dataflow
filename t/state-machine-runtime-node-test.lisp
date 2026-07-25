(in-package #:cl-dataflow.test)

(deftest state-machine-print-object
  (let ((machine (make-state-machine :state "idle")))
    (is (search "STATE-MACHINE"
                (with-output-to-string (stream)
                  (prin1 machine stream))))
    (is (search "idle"
                (with-output-to-string (stream)
                  (prin1 machine stream)))))
  )

(deftest state-machine-node-drives-pipeline-state
  (let* ((graph (make-graph))
         (source (make-node "source"
                            :handler (lambda (input context)
                                       (declare (ignore context))
                                       (list (cons "value" input)))))
         (sink (make-node "sink"))
         (idle (make-state-machine
                :state "idle"
                :transitions (list (make-transition "idle" "start" "running"
                                                     :action (lambda (machine event context)
                                                               (declare (ignore event context))
                                                               (values nil (state-machine-state machine)))))))
         (node (make-state-machine-node idle :name "controller"))
         (pipeline nil)
         (context (make-context :state "idle")))
    (dolist (item (list source node sink))
      (add-node graph item))
    (add-edge graph source node)
    (add-edge graph node sink)
    (setf pipeline (make-pipeline :graph graph))
    (run-pipeline pipeline :input "start" :context context)
    (is (equal (state-machine-state idle) "running"))
    (is (equal (context-state context) "running"))
    (is (= 1 (length (state-machine-history idle))))
    (let ((trace (context-trace context)))
      (is (= 4 (length trace)))
      (assert-context-trace-entries context
        (0 (:node "sink")
           (:input "running"))
        (1 (:node "controller")
           (:input "start"))
        (2 (:from "idle")
           (:event-type "start")
           (:to "running")
           (:guard-passed t))
        (3 (:node "source")
           (:input "start"))))))

(deftest state-machine-node-supports-event-and-result-fns
  (let* ((calls '())
         (machine (make-state-machine
                   :state "idle"
                   :transitions (list (make-transition "idle" "start" "running"
                                                        :action (lambda (machine event context)
                                                                  (declare (ignore machine event context))
                                                                  (values nil :transitioned)))))))
    (let ((node (make-state-machine-node machine
                                         :event-fn (lambda (input context)
                                                     (push (list :event-fn input context) calls)
                                                     (make-event "start" :payload input))
                                         :result-fn (lambda (updated-machine event input context)
                                                      (push (list :result-fn (state-machine-state updated-machine)
                                                                  (event-type event)
                                                                  (event-payload event)
                                                                  input
                                                                  context)
                                                            calls)
                                                      (list :state (state-machine-state updated-machine)
                                                            :event (event-type event)
                                                            :input input
                                                            :context context)))))
      (let ((result (funcall (node-handler node) 10 :context)))
        (is (equal result '(:state "running" :event "start" :input 10 :context :context)))
        (is (equal (reverse calls)
                   (list (list :event-fn 10 :context)
                         (list :result-fn "running" "start" 10 10 :context))))))))

(deftest state-machine-node-accepts-event-objects-from-event-fn
  (let* ((machine (make-state-machine
                   :state "idle"
                   :transitions (list (make-transition "idle" "boot" "running"))))
         (node (make-state-machine-node machine
                                        :event-fn (lambda (input context)
                                                    (declare (ignore input context))
                                                    (make-event "boot")))))
    (is (equal (funcall (node-handler node) :anything nil) "running"))))

(deftest state-machine-node-defaults-pass-through-event-and-current-state
  (let* ((machine (make-state-machine
                   :state "idle"
                   :transitions (list (make-transition "idle" "start" "running"))))
         (node (make-state-machine-node machine)))
    (is (equal (funcall (node-handler node) "start" nil) "running"))))

(deftest state-machine-introspection-helpers
  (let* ((machine (make-state-machine
                   :state "idle"
                   :transitions (list (make-transition "idle" "start" "running")
                                      (make-transition "running" "stop" "idle"))))
         (transitions (state-machine-available-transitions machine))
         (count (length transitions)))
    (is (= count 1))
    (assert-node-order (mapcar (lambda (transition)
                                 (make-node (transition-from transition)))
                               transitions)
                       '("idle"))))

(deftest state-machine-can-step-p-passes-context-to-guard
  (let* ((guard-contexts '())
         (machine (make-state-machine
                   :state "idle"
                   :transitions (list (make-transition "idle" "start" "running"
                                                        :guard (lambda (machine event context)
                                                                 (declare (ignore machine event))
                                                                 (push context guard-contexts)
                                                                 (eq context :allowed)))))))
    (is (state-machine-can-step-p machine "start" :context :allowed))
    (is (not (state-machine-can-step-p machine "start" :context :blocked)))
    (is (equal guard-contexts '(:blocked :allowed)))))

(deftest state-machine-can-step-p-preserves-truthy-guard-results
  (let ((machine (make-state-machine
                  :state "idle"
                  :transitions (list (make-transition "idle" "start" "running"
                                                       :guard (lambda (machine event context)
                                                                (declare (ignore machine event context))
                                                                1))))))
    (is (state-machine-can-step-p machine "start"))))

(define-snapshot-isolation-test state-machine-transitions-return-independent-snapshots
  ((transition (make-transition "idle" "start" "running"
                                 :metadata '((:labels "alpha"))))
   (machine (make-state-machine
             :state "idle"
             :transitions (list transition))))
  (snapshot (first (state-machine-transitions machine)))
  (is (not (eq snapshot transition)))
  (setf (transition-metadata snapshot) '((:labels "mutated")))
  (is (equal (transition-metadata (first (state-machine-transitions machine)))
             '((:labels "alpha")))))

(define-snapshot-isolation-test state-machine-available-transitions-return-independent-snapshots
  ((transition (make-transition "idle" "start" "running"
                                 :metadata '((:labels "alpha"))))
   (machine (make-state-machine
             :state "idle"
             :transitions (list transition))))
  (snapshot (first (state-machine-available-transitions machine)))
  (is (not (eq snapshot transition)))
  (setf (transition-metadata snapshot) '((:labels "mutated")))
  (is (equal (transition-metadata (first (state-machine-available-transitions machine)))
             '((:labels "alpha")))))

(deftest state-machine-available-transitions-normalizes-state-designator
  (let ((machine (make-state-machine
                  :state "idle"
                  :transitions (list (make-transition "idle" "start" "running")))))
    (is (equal (mapcar #'transition-event-type (state-machine-available-transitions machine :state 'idle))
               '("start")))))

(deftest state-machine-available-transitions-return-empty-list-for-missing-state
  (let ((machine (make-state-machine
                  :state "idle"
                  :transitions (list (make-transition "idle" "start" "running")))))
    (is (equal (state-machine-available-transitions machine :state "missing")
               '()))))
