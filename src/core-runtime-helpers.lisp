(in-package #:cl-dataflow)

;;;; Small runtime helpers shared by the pipeline and testing layers: the
;;;; context value store, runtime-context construction, the context mutation
;;;; lock guard, and the %WITH-PLIST-BINDINGS macro used to destructure
;;;; plist-shaped stage specs.

(defmacro %with-context-lock-if-present ((context) &body body)
  "Run BODY holding CONTEXT's lock if one is installed (RUN-PIPELINE's
:PARALLEL mode; see PIPELINE-PARALLEL.LISP's %ENSURE-CONTEXT-LOCK), or run it
unguarded otherwise -- every sequential run, the overwhelming common case,
pays only the one slot read this checks, never a lock acquisition."
  (let ((lock (gensym "LOCK")))
    `(let ((,lock (slot-value ,context 'lock)))
       (if ,lock
           (cl-concurrent-kit:with-lock-held (,lock) ,@body)
           (progn ,@body)))))

(defun %store-value-by-key (context key value)
  "Unguarded: every caller either runs before RUN-PIPELINE's :PARALLEL mode
spawns any concurrent handler for the current level (input resolution) or
after every handler in it has already been awaited (result recording, done
sequentially on the orchestrating thread) -- see PIPELINE-PARALLEL.LISP -- so
no call site ever races another thread."
  (setf (gethash key (%context-values-table context))
        (%copy-structured-value value)))

(defun %store-value (context node-name port value)
  (%store-value-by-key context (list node-name port) value))

(defun %read-value-by-key (context key)
  (gethash key (%context-values-table context)))

(defun %read-value (context node-name port)
  (%read-value-by-key context (list node-name port)))

(defun %make-runtime-context (&key state metadata effect-handlers)
  (make-context :state state
                :metadata metadata
                :effect-handlers effect-handlers))

(defmacro %with-plist-bindings ((plist bindings) &body body)
  (let ((plist-name (gensym "PLIST")))
    `(let ((,plist-name ,plist))
       (let ,(mapcar (lambda (binding)
                       (destructuring-bind (name key) binding
                         `(,name (getf ,plist-name ,key))))
                     bindings)
         ,@body))))
