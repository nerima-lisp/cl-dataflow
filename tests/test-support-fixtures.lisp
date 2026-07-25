(in-package #:cl-dataflow.test)

(defmacro with-runtime-artifacts ((record history-entry trace-entry
                                          history-form trace-form)
                                  action-form
                                  &body assertions)
  `(let* ((,record ,action-form)
          (,history-entry ,history-form)
          (,trace-entry ,trace-form))
     (declare (ignorable ,history-entry ,trace-entry))
     ,@assertions))

(defmacro with-stepped-state-machine ((updated-machine transition-record machine event
                                                       &key context
                                                       history-entry trace-entry)
                                      &body assertions)
  `(multiple-value-bind (,updated-machine ,transition-record)
       (step-state-machine ,machine ,event
                           ,@(when context `(:context ,context)))
     (let ((,history-entry (first (state-machine-history ,machine)))
           (,trace-entry ,(if context
                              `(first (context-trace ,context))
                              nil)))
       (declare (ignorable ,history-entry ,trace-entry))
       ,@assertions)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %state-machine-transition-binding (spec)
    (destructuring-bind (name from event to &rest options) spec
      `(,name (make-transition ,from ,event ,to ,@options))))

  (defun %state-machine-transition-name (spec)
    (first spec)))

(defmacro with-state-machine-fixture ((machine &key state initial-state metadata transitions)
                                      &body body)
  (let ((transition-bindings (mapcar #'%state-machine-transition-binding transitions))
        (transition-names (mapcar #'%state-machine-transition-name transitions)))
    `(let* (,@transition-bindings
            (,machine (make-state-machine
                       ,@(when state `(:state ,state))
                       ,@(when initial-state `(:initial-state ,initial-state))
                       ,@(when metadata `(:metadata ,metadata))
                       :transitions (list ,@transition-names))))
       ,@body)))

(defmacro with-state-machine-run-fixture ((machine) &body body)
  `(with-state-machine-fixture (,machine
                                :state "idle"
                                :transitions ((start-transition "idle" "start" "running")
                                              (finish-transition "running" "finish" "completed")))
     ,@body))

(defmacro with-idle-start-transition-machine ((machine &rest transition-options) &body body)
  `(with-state-machine-fixture (,machine
                                :state "idle"
                                :transitions ((transition "idle" "start" "running"
                                                          ,@transition-options)))
     ,@body))

(defmacro define-example-script-tests (&body specs)
  `(progn
     ,@(mapcar (lambda (spec)
                 (destructuring-bind (name path &rest expected-substrings) spec
                   `(deftest ,name
                      (multiple-value-bind (output ran-p)
                          (%run-example-script ,path)
                        (when ran-p
                          ,@(mapcar (lambda (expected-substring)
                                      `(is (search ,expected-substring output)))
                                    expected-substrings))))))
               specs)))

(defmacro with-defined-workflow ((pipeline machine) form &body body)
  `(multiple-value-bind (,pipeline ,machine) ,form
     ,@body))

(defmacro with-workflow-context ((context pipeline &rest run-options) &body body)
  `(let ((,context (run-pipeline-with-test-context ,pipeline ,@run-options)))
     ,@body))

(defmacro with-linear-test-pipeline ((graph pipeline source sink
                                            &key source-handler
                                                 sink-handler
                                                 source-metadata
                                                 sink-metadata
                                                 pipeline-metadata)
                                      &body body)
  `(let* ((,graph (make-graph))
          (,source (make-node "source"
                              ,@(when source-handler
                                  `(:handler ,source-handler))
                              ,@(when source-metadata
                                  `(:metadata ,source-metadata))))
          (,sink (make-node "sink"
                            ,@(when sink-handler
                                `(:handler ,sink-handler))
                            ,@(when sink-metadata
                                `(:metadata ,sink-metadata))))
          (,pipeline (progn
                       (add-node ,graph ,source)
                       (add-node ,graph ,sink)
                       (add-edge ,graph ,source ,sink)
                       (make-pipeline :graph ,graph
                                      ,@(when pipeline-metadata
                                          `(:metadata ,pipeline-metadata))))))
     (declare (ignorable ,graph ,pipeline ,source ,sink))
     (locally ,@body)))





(defun single-node-pipeline (node)
  "Return a fresh pipeline whose only stage is NODE -- the scaffold every
NODE-WITH-* wrapper test needs to see its wrapper actually run through
RUN-PIPELINE, not just via a direct FUNCALL."
  (let ((graph (make-graph)))
    (add-node graph node)
    (make-pipeline :graph graph)))

(defmacro %branching-test-split-handler ()
  `(lambda (input context)
     (declare (ignore context))
     (list (cons "left" (+ input 1))
           (cons "right" (* input 2)))))

(defmacro %branching-test-offset-handler (offset)
  `(lambda (input context)
     (declare (ignore context))
     (+ input ,offset)))

(defmacro with-branching-test-pipeline ((graph pipeline source left right
                                               &key source-handler
                                                    left-handler
                                                    right-handler)
                                         &body body)
  `(let* ((,graph (make-graph))
          (,source (make-node "source"
                              :outputs '("left" "right")
                              :handler ,(or source-handler
                                            '(%branching-test-split-handler))))
          (,left (make-node "left"
                            :handler ,(or left-handler
                                          '(%branching-test-offset-handler 10))))
          (,right (make-node "right"
                             :handler ,(or right-handler
                                           '(%branching-test-offset-handler 20))))
          (,pipeline (progn
                       (dolist (node (list ,source ,left ,right))
                         (add-node ,graph node))
                       (add-edge ,graph ,source ,left :from-port "left")
                       (add-edge ,graph ,source ,right :from-port "right")
                       (make-pipeline :graph ,graph))))
     (declare (ignorable ,graph ,pipeline ,source ,left ,right))
     (locally ,@body)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %graph-fixture-node-binding (spec)
    (destructuring-bind (name label &rest initargs) spec
      `(,name (make-node ,label ,@initargs))))

  (defun %graph-fixture-node-name (spec)
    (first spec))

  (defun %graph-fixture-edge-form (graph spec)
    (destructuring-bind (from to &rest options) spec
      `(add-edge ,graph ,from ,to ,@options))))

(defmacro with-graph-fixture ((graph nodes &key edges) &body body)
  (let ((node-bindings (mapcar #'%graph-fixture-node-binding nodes))
        (node-names (mapcar #'%graph-fixture-node-name nodes))
        (edge-forms (mapcar (lambda (spec)
                              (%graph-fixture-edge-form graph spec))
                            edges)))
    `(let* ((,graph (make-graph))
            ,@node-bindings)
       (dolist (node (list ,@node-names))
         (add-node ,graph node))
       ,@edge-forms
       ,@body)))

(defun make-test-table (&rest bindings)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on bindings by #'cddr
          do (setf (gethash key table) value))
    table))

(defmacro with-test-table ((name &rest bindings) &body body)
  `(let ((,name (make-test-table ,@bindings)))
     ,@body))

(defun make-test-effect-handlers (&rest bindings)
  (apply #'make-test-table bindings))

(defmacro with-effect-handlers ((name &rest bindings) &body body)
  `(let ((,name (make-test-effect-handlers ,@bindings)))
     ,@body))

(defun structured-value-variants (pairs)
  (let ((plist (loop for (key . value) in pairs
                     append (list key value))))
    (list (apply #'make-test-table plist)
          plist
          pairs)))

(defmacro do-structured-value-variants ((name pairs) &body body)
  `(dolist (,name (structured-value-variants ,pairs))
     ,@body))

(defun %sorted-symbol-names (symbols)
  (sort (mapcar (lambda (symbol)
                  (string-upcase (string symbol)))
                symbols)
        #'string<))

(defun collect-single-source-emissions (build inputs)
  "Drive a single-source reactive operator and return what it emitted. BUILD is
applied to a fresh source subject and must return the derived subject to observe;
each of INPUTS is then emitted on the source in order. Returns the list of values
the derived subject emitted, in emission order."
  (let* ((source (make-subject))
         (derived (funcall build source))
         (collector (subject-collect derived)))
    (dolist (value inputs) (subject-emit source value))
    (funcall collector)))

(defmacro define-single-source-subject-tests (&body specs)
  "Define one DEFTEST per (NAME BUILDER INPUTS EXPECTED) spec, collapsing the
build-source / derive / emit-inputs / assert-collected boilerplate every
single-source subject operator test repeats. BUILDER is a function form mapping a
fresh source subject to the derived subject under test; INPUTS are emitted in
order; the collected emissions must EQUAL the literal EXPECTED list."
  `(progn
     ,@(mapcar (lambda (spec)
                 (destructuring-bind (name builder inputs expected) spec
                   `(deftest ,name
                      (is (equal (collect-single-source-emissions ,builder ',inputs)
                                 ',expected)))))
               specs)))
