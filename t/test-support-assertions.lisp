(in-package #:cl-dataflow.test)

(defmacro is (form &optional message)
  "Assert FORM is truthy. Without MESSAGE, delegates entirely to CL-WEAVE:EXPECT's
own smart-assertion reporting (sub-expression values on failure). With MESSAGE,
FORM is evaluated once; a truthy result still reports through EXPECT as usual,
but a failure reports MESSAGE via CL-WEAVE:FAIL instead of EXPECT's generic
truthiness report -- for the rare assertion where surrounding context (which of
several checked things failed, what input produced it) isn't visible in FORM's
own sub-expression values."
  (if message
      (let ((result (gensym "RESULT")))
        `(let ((,result ,form))
           (if ,result
               (cl-weave:expect ,result :to-be-truthy)
               (fail ,message))))
      `(cl-weave:expect ,form :to-be-truthy)))

(defmatcher :to-have-valid-topological-order (actual expected)
  "Assert that a graph's topological order contains every node and respects every edge."
  (declare (ignore expected))
  (handler-case
      (let* ((order (topological-sort actual))
              (positions (make-hash-table :test #'equal)))
        (loop for node in order
              for position from 0
              do (setf (gethash (node-name node) positions) position))
        (let ((valid-p
                (and (= (length order) (hash-table-count (graph-nodes actual)))
                      (every (lambda (edge)
                              (< (gethash (edge-from edge) positions)
                                  (gethash (edge-to edge) positions)))
                            (graph-edges actual)))))
          (values valid-p
                  (mapcar #'node-name order)
                  "an order containing every node with each source before its sink")))
    (error (condition)
      (values nil condition "an acyclic graph with a valid topological order"))))

(defmacro capture-condition ((var condition) &body body)
  (let ((captured (gensym "CAPTURED-")))
    `(let ((,var nil))
        (handler-case
            (progn ,@body)
          (,condition (,captured)
            (setf ,var ,captured)))
        ,var)))

(defmacro with-captured-condition ((var condition) form &body assertions)
  `(let ((,var (capture-condition (,var ,condition) ,form)))
      (is ,var)
      ,@assertions))

(defmacro %assert-plist-pairs (entry-name &rest expected-pairs)
  `(progn
      ,@(mapcar (lambda (expected-pair)
                  (destructuring-bind (key expected-value) expected-pair
                    `(is (equal (getf ,entry-name ,key) ,expected-value))))
                expected-pairs)
      t))

(defmacro assert-plist-entry (entry &rest expected-pairs)
  (let ((entry-name (gensym "ENTRY-")))
    `(let ((,entry-name ,entry))
        (%assert-plist-pairs ,entry-name ,@expected-pairs))))

(defmacro assert-plist-entries (entries &rest expected-pairs)
  (let ((entry-name (gensym "ENTRY-")))
    `(dolist (,entry-name ,entries)
        (%assert-plist-pairs ,entry-name ,@expected-pairs))))

(defmacro assert-transition-record (record &rest expected-pairs)
  `(assert-plist-entry ,record ,@expected-pairs))

(defmacro assert-transition-records (records &rest expected-pairs)
  `(assert-plist-entries ,records ,@expected-pairs))

(defmacro assert-context-trace-entry (context index &rest expected-pairs)
  `(assert-plist-entry (nth ,index (context-trace ,context)) ,@expected-pairs))

(defmacro assert-context-trace-entries (context &rest clauses)
  `(progn
      ,@(mapcar (lambda (clause)
                  (destructuring-bind (index &rest expected-pairs) clause
                    `(assert-context-trace-entry ,context ,index ,@expected-pairs)))
                clauses)
      t))

(defmacro assert-context-first-trace-entry (context &rest expected-pairs)
  `(assert-context-trace-entry ,context 0 ,@expected-pairs))

(defmacro set-plist-entry (place key value)
  `(setf (getf ,place ,key) ,value))

(defmacro assert-hash-table-count (table expected-count)
  `(is (= ,expected-count (hash-table-count ,table))))

(defmacro assert-plist-hash-table-count (entry key expected-count)
  `(assert-hash-table-count (getf ,entry ,key) ,expected-count))

(defmacro assert-event-sequence (entries expected-event-types)
  `(is (equal (mapcar (lambda (entry)
                        (getf entry :event-type))
                      ,entries)
              ,expected-event-types)))

(defmacro assert-node-order (nodes expected-node-names)
  `(is (equal (mapcar #'node-name ,nodes)
              ,expected-node-names)))

(defmacro assert-distinct-snapshots (&rest pairs)
  `(progn
      ,@(mapcar (lambda (pair)
                  (destructuring-bind (left right) pair
                    `(is (not (eq ,left ,right)))))
                pairs)
      t))

(defmacro with-copy-isolation ((copy original copy-form) &body body)
  `(let ((,copy ,copy-form))
      (is (not (eq ,copy ,original)))
      ,@body))

(defmacro assert-setter-roundtrips (&rest clauses)
  `(progn
      ,@(mapcar (lambda (clause)
                  (destructuring-bind (place value expected) clause
                    `(progn
                      (setf ,place ,value)
                      (is (equal ,place ,expected)
                          ,(format nil "Setter roundtrip failed for ~S" place)))))
                clauses)
      t))

(defmacro assert-setter-copy-isolated (place value expected mutation-form)
  (let ((source-value (gensym "SOURCE-")))
    `(let ((,source-value ,value))
        (setf ,place ,source-value)
        (is (equal ,place ,expected)
            ,(format nil "Setter copy failed for ~S" place))
        ,mutation-form
        (is (equal ,place ,expected)
            ,(format nil "Setter copy became mutable for ~S" place))
        t)))

(defmacro with-mutated-snapshot ((name form) mutation-form &body assertions)
  `(let ((,name ,form))
      ,mutation-form
      ,@assertions))

(defmacro define-snapshot-freshness-test (name bindings &body pairs)
  `(deftest ,name
      (let* ,bindings
        (assert-distinct-snapshots ,@pairs))))

(defmacro define-snapshot-isolation-test (name bindings (snapshot form) mutation-form
                                          &body assertions)
  `(deftest ,name
      (let* ,bindings
        (with-mutated-snapshot (,snapshot ,form)
          ,mutation-form
          ,@assertions))))

(defmacro define-snapshot-payload-isolation-test (name bindings (snapshot form)
                                                    payload-form expected-form
                                                    expected-value)
  `(define-snapshot-isolation-test ,name
        ,bindings
        (,snapshot ,form)
        (let ((payload ,payload-form))
          (setf (cadr payload) "mutated"))
        (is (equal ,expected-form ,expected-value))))

(defmacro define-invalid-dsl-test (name form invalid-value detail-substring)
  `(deftest ,name
      (with-captured-condition (captured invalid-input-error)
          (macroexpand-1 ',form)
        (is (equal (invalid-input-value captured) ,invalid-value))
        (is (search ,detail-substring
                    (invalid-input-detail captured))))))

(defmacro define-invalid-dsl-option-test (name form invalid-option detail-substring)
  `(define-invalid-dsl-test ,name ,form ,invalid-option ,detail-substring))

(defun condition-report-string (condition)
  (with-output-to-string (stream)
    (princ condition stream)))

(defmacro assert-condition-report (condition expected-substring)
  `(is (search ,expected-substring
                (condition-report-string ,condition))))

(defmacro assert-graph-condition (condition graph expected-detail &key type designator)
  `(progn
      (is (typep ,condition 'graph-error))
      (is (eq (graph-error-graph ,condition) ,graph))
      (is (equal (graph-error-detail ,condition) ,expected-detail))
      (assert-condition-report ,condition ,expected-detail)
      ,@(when type
          `((is (typep ,condition ,type))))
      ,@(when designator
          `((is (equal (node-not-found-designator ,condition) ,designator))))))

(defmacro assert-state-machine-condition (condition condition-class state event-type
                                          expected-detail &key transition)
  (ecase condition-class
    (invalid-transition-error
      `(progn
        (is (typep ,condition 'invalid-transition-error))
        (is (equal (invalid-transition-state ,condition) ,state))
        (is (equal (invalid-transition-event-type ,condition) ,event-type))
        (is (equal (invalid-transition-detail ,condition) ,expected-detail))
        (assert-condition-report ,condition ,expected-detail)))
    (guard-failed-error
      `(progn
        (is (typep ,condition 'guard-failed-error))
        (is (equal (guard-failed-state ,condition) ,state))
        (is (equal (guard-failed-event-type ,condition) ,event-type))
        ,@(when transition
            `((is (not (eq (guard-failed-transition ,condition) ,transition)))
              (is (equal (transition-from (guard-failed-transition ,condition))
                          (transition-from ,transition)))
              (is (equal (transition-event-type (guard-failed-transition ,condition))
                          (transition-event-type ,transition)))))
        (is (equal (guard-failed-detail ,condition) ,expected-detail))
        (assert-condition-report ,condition ,expected-detail)))))

(defun %public-api-symbol-defined-p (symbol kind)
  (ecase kind
    (:function
      (and (fboundp symbol)
          (null (macro-function symbol))))
    (:macro
      (not (null (macro-function symbol))))
    (:class
      (not (null (find-class symbol nil))))
    (:variable
      (boundp symbol))))

(defmacro define-public-api-contract-test
    (name package-name (&key classes macros variables) &body groups)
  (let ((documented-symbols
          (loop for group in groups
                append (rest group))))
    `(deftest ,name
        (let* ((package (find-package ,package-name))
              (expected (%sorted-symbol-names ',documented-symbols))
              (actual (%sorted-symbol-names
                        (loop for symbol being the external-symbols of package
                              collect symbol)))
              (classified-symbols
                (append ',classes ',macros ',variables))
              (duplicate-classifications
                (loop for symbol in classified-symbols
                      when (> (count symbol classified-symbols) 1)
                        collect symbol)))
          (is package)
          (is (equal actual expected)
              (format nil
                      "Package ~A export surface drifted.~%Expected: ~S~%Actual: ~S"
                      ,package-name
                      expected
                      actual))
          (is (null duplicate-classifications)
              (format nil "Public API symbols have duplicate classifications: ~S"
                      duplicate-classifications))
          (dolist (symbol ',documented-symbols)
            (let ((kind (cond
                          ((member symbol ',classes) :class)
                          ((member symbol ',macros) :macro)
                          ((member symbol ',variables) :variable)
                          (t :function))))
              (is (%public-api-symbol-defined-p symbol kind)
                  (format nil "Public API symbol ~S is not defined as a ~A."
                          symbol
                          kind))))))))
