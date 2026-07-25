(in-package #:cl-dataflow.test)

;;;; Mutation testing (cl-weave:run-mutations) applied to small, pure
;;;; arithmetic/conditional formulas lifted verbatim from the runtime, as a
;;;; second line of defense beyond example- and property-based tests: it
;;;; proves the reference computation used by those tests is itself sharp
;;;; enough to distinguish every arithmetic-operator, comparison-operator,
;;;; boolean-literal, and if-branch mutant cl-weave can generate, not just
;;;; agree with the original on the cases already exercised.

(defun %safe-eval-with-bindings (form bindings)
  "Evaluate FORM under lexical BINDINGS (an alist of symbol . value), treating
any signalled error as a distinguishable outcome rather than propagating --
a mutant that errors where the original does not counts as caught, matching
the intent of mutation testing without needing cl-weave to classify it as an
:ERRORED result. Muffles compiler warnings: binding a mutation-testing edge
case like COUNT = 0 makes SBCL's compiler prove a division-by-zero is
reachable in isolation, even though the surrounding IF guard makes it
unreachable at runtime for that binding -- exactly the case this helper
exists to exercise, not a real problem to report."
  (handler-case
      (handler-bind ((warning #'muffle-warning))
        (eval `(let ,(mapcar (lambda (binding) (list (car binding) (cdr binding))) bindings)
                 ,form)))
    (error () :error)))

(defun %mutation-fully-killed-p (form cases)
  "Return true when every mutant of FORM (under cl-weave's default operators)
disagrees with FORM on at least one of CASES, an alist of BINDINGS lists."
  (zerop (getf (mutation-summary
                (run-mutations
                 form
                 (lambda (mutated-form mutation)
                   (declare (ignore mutation))
                   (every (lambda (bindings)
                            (equal (%safe-eval-with-bindings form bindings)
                                   (%safe-eval-with-bindings mutated-form bindings)))
                          cases))))
               :survived)))

(deftest stream-average-formula-has-no-surviving-mutants
  ;; Lifted from STREAM-AVERAGE in stream-ops.lisp: (if (zerop count) nil (/ sum count)).
  (is (%mutation-fully-killed-p
       '(if (zerop count) nil (/ sum count))
       '(((sum . 0) (count . 0))
         ((sum . 10) (count . 4))
         ((sum . 7) (count . 3))
         ((sum . -6) (count . 3))
         ((sum . 5) (count . 1))))))

(deftest graph-density-formula-has-no-surviving-mutants
  ;; Lifted from GRAPH-DENSITY in graph-metrics.lisp: (if (< order 2) 0 (/ edges (* order (1- order)))).
  (is (%mutation-fully-killed-p
       '(if (< order 2) 0 (/ edges (* order (1- order))))
       '(((order . 0) (edges . 0))
         ((order . 1) (edges . 0))
         ((order . 2) (edges . 1))
         ((order . 3) (edges . 2))
         ((order . 4) (edges . 6))))))
