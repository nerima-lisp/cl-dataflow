(in-package #:cl-dataflow)

;;;; Structural deep-copying: %COPY-STRUCTURED-VALUE walks an arbitrary
;;;; cons/hash-table/vector/string value (memoizing shared and circular
;;;; substructure) so no two model objects ever alias the same mutable data.
;;;; Its cons-chain traversal is continuation-passing with an explicit
;;;; trampoline (%COPY-STRUCTURED-VALUE/CPS, %RUN-COPY-TRAMPOLINE) so copying
;;;; a very long list costs O(1) Lisp control-stack depth.

(defun %make-result-table (&optional size)
  (if size
      (make-hash-table :test #'equal :size size)
      (make-hash-table :test #'equal)))

(defun %copy-hash-table-with-value-transform (table value-transform)
  (let ((copy
        (make-hash-table :test (hash-table-test table) :size (hash-table-count table))))
    (maphash
      (lambda (key value)
        (setf (gethash key copy) (funcall value-transform value)))
      table)
    copy))

(defmacro define-copy-hash-table (name (source element-copy))
  `(defun ,name (,source)
    (%copy-hash-table-with-value-transform ,source ,element-copy)))

(defparameter +first-printable-ascii-code+ 32
  "The lowest ASCII code %ESCAPED-DISPLAY-STRING treats as printable as-is
(the space character); codes below it are C0 control characters.")

(defparameter +ascii-delete-code+ 127
  "The ASCII DEL code, the one control character above +FIRST-PRINTABLE-ASCII-CODE+
that %ESCAPED-DISPLAY-STRING still escapes.")

(defun %escaped-display-string (value)
  (with-output-to-string (out)
    (loop for char across (princ-to-string value)
          do (case char
               (#\Newline (write-string "\\n" out))
               (#\Return (write-string "\\r" out))
               (#\Tab (write-string "\\t" out))
               (t
                (if (or (< (char-code char) +first-printable-ascii-code+)
                        (= (char-code char) +ascii-delete-code+))
                    (format out "\\x~2,'0X;" (char-code char))
                    (write-char char out)))))))

(defstruct (%copy-bounce (:constructor %make-copy-bounce (thunk)))
  "A deferred continuation for %COPY-STRUCTURED-VALUE/CPS's trampoline: calling
THUNK takes one more step instead of growing the Lisp control stack, so a long
cons chain copies in bounded stack depth regardless of its length."
  (thunk nil :type function :read-only t))

(defun %run-copy-trampoline (step)
  (loop while (%copy-bounce-p step)
        do (setf step (funcall (%copy-bounce-thunk step))))
  step)

(defun %copy-structured-value/cps (value seen continuation)
  "Copy VALUE (memoizing already-seen substructures in SEEN for cycle safety),
then invoke CONTINUATION on the result -- or, for a cons, return a bounce for
%RUN-COPY-TRAMPOLINE to step instead of recursing, so a long list's spine
costs O(1) Lisp stack regardless of its length. Hash-table values, vector
elements, and a cons's CAR still recurse directly: that dimension is bounded
by branching depth rather than an unbounded chain, so it stays safe."
  (multiple-value-bind (cached present-p) (gethash value seen)
    (cond
      (present-p (funcall continuation cached))
      ((hash-table-p value)
       (let ((copy (make-hash-table :test (hash-table-test value)
                                    :size (hash-table-count value))))
         (setf (gethash value seen) copy)
         (maphash (lambda (key table-value)
                    (setf (gethash (%run-copy-trampoline
                                    (%copy-structured-value/cps key seen #'identity))
                                   copy)
                          (%run-copy-trampoline
                           (%copy-structured-value/cps table-value seen #'identity))))
                  value)
         (funcall continuation copy)))
      ((stringp value)
       (let ((copy (copy-seq value)))
         (setf (gethash value seen) copy)
         (funcall continuation copy)))
      ((vectorp value)
       (let ((copy (copy-seq value)))
         (setf (gethash value seen) copy)
         (dotimes (index (length copy))
           (setf (aref copy index)
                 (%run-copy-trampoline
                  (%copy-structured-value/cps (aref copy index) seen #'identity))))
         (funcall continuation copy)))
      ((consp value)
       (let ((copy (cons nil nil)))
         (setf (gethash value seen) copy)
         (%make-copy-bounce
          (lambda ()
            (%copy-structured-value/cps
             (car value) seen
             (lambda (car-copy)
               (setf (car copy) car-copy)
               (%copy-structured-value/cps
                (cdr value) seen
                (lambda (cdr-copy)
                  (setf (cdr copy) cdr-copy)
                  (funcall continuation copy)))))))))
      (t (funcall continuation value)))))

(defun %copy-structured-value* (value seen)
  (%run-copy-trampoline (%copy-structured-value/cps value seen #'identity)))

(defun %copy-structured-value (value)
  (if (or (consp value) (hash-table-p value) (stringp value) (vectorp value)) (%copy-structured-value* value (make-hash-table :test #'eq))
    value))

(defun %copy-result-table (table)
  (let ((copy
        (make-hash-table :test (hash-table-test table) :size (hash-table-count table))))
    (maphash
      (lambda (key value)
        (setf
          (gethash (%copy-structured-value key) copy)
          (%copy-structured-value value)))
      table)
    copy))

(defun %copy-effect-handlers (effect-handlers)
  (let ((copy (make-hash-table :test #'equal :size (hash-table-count effect-handlers))))
    (maphash
      (lambda (key value)
        (setf (gethash (%normalize-handler-key key) copy) value))
      effect-handlers)
    copy))
