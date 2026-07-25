(in-package #:cl-dataflow.test)

(deftest context-merge-combines-observations
  (let ((base (make-context))
        (other (make-context)))
    (emit-events base '(:a))
    (emit-events other '(:b))
    (setf (context-metadata base) '((:from :base)))
    (setf (context-metadata other) '((:from :other)))
    (let ((merged (context-merge base other)))
      ;; base's events come first in chronological order.
      (is (equal (context-event-types merged) '("A" "B")))
      ;; metadata concatenates base then other.
      (is (equal (context-metadata merged) '((:from :base) (:from :other))))
      ;; the inputs are untouched.
      (is (equal (context-event-types base) '("A"))))))

(deftest context-merge-collision-precedence-is-asymmetric
  ;; CONTEXT-MERGE's documented contract is deliberately asymmetric: OTHER
  ;; overlays BASE for stored node values and effect handlers (both hash tables,
  ;; where a later write replaces an earlier one), but metadata is a plist/alist
  ;; concatenated BASE-first, and a plist lookup resolves to the first match --
  ;; so BASE wins there. The test above checks that metadata concatenates; this
  ;; one checks which side actually wins a *lookup* on a colliding key, which is
  ;; the part the docstring promises and the part a caller depends on.
  (let ((base (make-context))
        (other (make-context)))
    (cl-dataflow::%store-value base "n" "value" :base)
    (cl-dataflow::%store-value other "n" "value" :other)
    (register-effect-handler base "log"
                             (lambda (effect ctx) (declare (ignore effect ctx)) :base))
    (register-effect-handler other "log"
                             (lambda (effect ctx) (declare (ignore effect ctx)) :other))
    (setf (context-metadata base) '(:owner :base))
    (setf (context-metadata other) '(:owner :other))
    (let ((merged (context-merge base other)))
      (is (eq (context-value merged "n") :other))
      (is (eq (effect-result (perform-effect merged "log")) :other))
      (is (eq (getf (context-metadata merged) :owner) :base)))))

(deftest context-trace-of-kind-filters-entries
  (let ((context (make-context)))
    (register-effect-handler context "log"
                             (lambda (effect ctx) (declare (ignore effect ctx)) :ok))
    (emit-event context :started)
    (perform-effect context "log")
    (is (= (length (context-trace-of-kind context :event)) 1))
    (is (= (length (context-trace-of-kind context :effect)) 1))
    (is (null (context-trace-of-kind context :node)))))

(deftest flow-describe-and-children-cover-every-flow-kind
  (with-graph-fixture (graph ((a "a") (b "b")) :edges ((a b)))
    (let ((description (flow-describe graph)))
      (assert-plist-entry description (:kind :graph) (:children 2)))
    (is (= (length (flow-children graph)) 2)))
  (let* ((sm-graph (make-graph)))
    (add-node sm-graph (make-node "only"))
    (let ((pipeline (make-pipeline :graph sm-graph)))
      (is (equal (getf (flow-describe pipeline) :kind) :pipeline))
      (is (= (length (flow-children pipeline)) 1))))
  (with-state-machine-fixture (machine
                               :state "idle"
                               :transitions ((start "idle" "start" "running")))
    (is (equal (getf (flow-describe machine) :kind) :state-machine))
    (is (= (length (flow-children machine)) 1)))
  ;; Leaf objects have no children.
  (let ((node (make-node "leaf")))
    (is (equal (getf (flow-describe node) :kind) :node))
    (is (null (flow-children node)))))
