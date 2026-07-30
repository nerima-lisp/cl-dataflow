(in-package #:cl-dataflow)

;;;; Design-by-contract wrappers for node handlers. A contract is a pair of
;;;; predicates: BEFORE checks the handler's input, AFTER checks its output. A
;;;; violation signals INVALID-INPUT-ERROR (with the offending value), turning a
;;;; silent bad value into an explicit, inspectable failure at the node boundary.

(defun contract-handler (handler &key before after)
  "Wrap HANDLER so that BEFORE (a predicate on the input) is checked before it runs
and AFTER (a predicate on the output) is checked after. A NIL predicate is skipped;
a failing predicate signals INVALID-INPUT-ERROR. Returns the handler's output
unchanged when both contracts hold."
  (lambda (input context)
    (when (and before (not (funcall before input)))
      (%signal-invalid-input-error
        'valid-node-input
        input
        "Node input violated its contract."))
    (let ((output (funcall handler input context)))
      (when (and after (not (funcall after output)))
        (%signal-invalid-input-error
          'valid-node-output
          output
          "Node output violated its contract."))
      output)))

(define-node-wrapper
  (node-with-contract (&key before after)
   (contract-handler handler :before before :after after)
   "Return a copy of NODE whose handler enforces the input/output contract BEFORE and
AFTER (see CONTRACT-HANDLER)."))
