(in-package #:cl-dataflow-kit)

;;;; Test-support helpers for asserting on a completed pipeline/state-machine
;;;; run: RUN-PIPELINE-WITH-TEST-CONTEXT builds a fresh runtime context, and
;;;; the ASSERT-* helpers (generated via %DEFINE-ASSERTION) each check one
;;;; observable facet -- emitted events, performed effects, final state, and
;;;; pipeline result -- against an expected value.

(defun %normalize-expected-list (value)
  (if (listp value) value (list value)))

(defmacro %define-assertion (name lambda-list actual-form expected-form message)
  `(defun ,name ,lambda-list
     (let ((actual ,actual-form)
           (expected-value ,expected-form))
       (unless (equal actual expected-value)
         (error ,message expected-value actual))
       t)))

(%define-assertion assert-emitted-events
    (context expected)
    (context-event-types context)
    (%normalize-expected-list expected)
    "Expected events ~S but saw ~S")

(%define-assertion assert-performed-effects
    (context expected)
    (context-effect-types context)
    (%normalize-expected-list expected)
    "Expected effects ~S but saw ~S")

(%define-assertion assert-final-state
    (context expected)
    (context-state context)
    expected
    "Expected final state ~S but saw ~S")

(%define-assertion assert-state-machine-state
    (machine expected)
    (state-machine-state machine)
    expected
    "Expected state machine state ~S but saw ~S")

(%define-assertion assert-pipeline-result
    (context expected)
    (context-result context)
    expected
    "Expected pipeline result ~S but saw ~S")

(defun run-pipeline-with-test-context (pipeline &key input effect-handlers state metadata)
  (let ((context (%make-runtime-context :state state
                                        :metadata metadata
                                        :effect-handlers effect-handlers)))
    (multiple-value-bind (result run-context)
        (run-pipeline-with-context pipeline :input input :context context)
      (declare (ignore result))
      run-context)))
