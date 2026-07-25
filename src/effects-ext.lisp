(in-package #:cl-dataflow)

;;;; Ergonomics for the effect boundary. The context's effect-handler table is
;;;; only reachable publicly through copying accessors (CONTEXT-EFFECT-HANDLERS
;;;; returns a snapshot), so registering a single handler previously meant
;;;; rebuilding the whole table. These helpers register, look up, and scope
;;;; handlers through the live table (%CONTEXT-EFFECT-HANDLER-TABLE, in
;;;; core-slot-accessors.lisp alongside the other internal live readers), all
;;;; keyed through %NORMALIZE-HANDLER-KEY so ":Log", 'LOG, and "log" collide
;;;; exactly as PERFORM-EFFECT resolves them.

(defun register-effect-handler (context type handler)
  "Register HANDLER for effect TYPE on CONTEXT (mutating it) and return HANDLER. A
handler already registered for the same normalized TYPE is replaced. HANDLER is a
function of (EFFECT CONTEXT), matching PERFORM-EFFECT's calling convention."
  (setf (gethash (%normalize-handler-key type)
                 (%context-effect-handler-table context))
        handler)
  handler)

(defun context-effect-handler (context type)
  "Return the handler registered for effect TYPE on CONTEXT, or NIL when none is."
  (values (gethash (%normalize-handler-key type)
                   (%context-effect-handler-table context))))

(defun effect-handled-p (context type)
  "Return true when CONTEXT has a handler registered for effect TYPE."
  (nth-value 1 (gethash (%normalize-handler-key type)
                        (%context-effect-handler-table context))))

(defun context-effect-handler-types (context)
  "Return the normalized effect types CONTEXT has handlers for, ordered by name."
  (sort (%hash-table-keys (%context-effect-handler-table context)) #'string<))

(defmacro with-effect-handler-scope ((context &rest bindings) &body body)
  "Evaluate BODY with each (TYPE HANDLER) of BINDINGS temporarily registered on
CONTEXT, restoring CONTEXT's original handler table afterward (even on non-local
exit). Returns BODY's value."
  (let ((context-var (gensym "CONTEXT"))
        (saved-var (gensym "SAVED-HANDLERS")))
    `(let* ((,context-var ,context)
            (,saved-var (context-effect-handlers ,context-var)))
       (unwind-protect
            (progn
              ,@(loop for (type handler) in bindings
                      collect `(register-effect-handler ,context-var ,type ,handler))
              ,@body)
         (setf (context-effect-handlers ,context-var) ,saved-var)))))
