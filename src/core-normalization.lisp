(in-package #:cl-dataflow-kit)

;;;; Normalization helpers shared across the model and runtime layers: name
;;;; and metadata canonicalization, port-list dedup/defaulting, and the
;;;; structured-input/output shape conversions pipeline node bindings use.

(defun %normalize-name (value)
  (typecase value
    (string value)
    (symbol (symbol-name value))
    ;; Non-symbol designators (numbers, characters, ...) are stringified with a
    ;; fixed printer configuration so a node/port identity never depends on the
    ;; caller's dynamic *print-* bindings (e.g. *print-base* 16 turning 255 into
    ;; "FF" and aliasing it onto a different node).
    (t (let ((*print-base* 10)
             (*print-radix* nil)
             (*print-readably* nil)
             (*print-pretty* nil)
             (*print-circle* t)
             (*print-case* :upcase))
         (princ-to-string value)))))

(defun %normalize-handler-key (value)
  (string-downcase (%normalize-name value)))

(defun %normalize-port-list (ports)
  (cond
    ((null ports) '("value"))
    ((listp ports) (mapcar #'%normalize-name ports))
    (t (list (%normalize-name ports)))))

(defun %normalize-unique-port-list (ports kind)
  (let ((normalized (%normalize-port-list ports))
        (seen (make-hash-table :test #'equal)))
    (dolist (port normalized normalized)
      (when (gethash port seen)
        (error 'invalid-input-error
               :expected 'port-list
               :value normalized
               :detail (format nil "Duplicate ~A port: ~A"
                               kind
                               (%escaped-display-string port))))
      (setf (gethash port seen) t))))

(defun %normalize-metadata (metadata)
  (if metadata (%copy-structured-value metadata) '()))

(defun %plist-value (plist key &optional default)
  (let ((position (position key plist :test #'equal)))
    (if position
        (nth (1+ position) plist)
        default)))

(defun %classify-structured-value (value)
  (cond
    ((hash-table-p value) :hash-table)
    ((and (listp value) (every #'consp value)) :alist)
    ((and (listp value) (evenp (length value))) :plist)
    (t :scalar)))

(defun %normalize-port-alist (value ports)
  (ecase (%classify-structured-value value)
    (:hash-table
     (loop for port in ports
           collect (cons port (gethash port value))))
    (:alist
     (loop for port in ports
           for cell = (assoc port value :test #'equal)
           collect (cons port (and cell (cdr cell)))))
    (:plist
     (loop for (key val) on value by #'cddr
           collect (cons (%normalize-name key) val)))))

(defun %structured-value-p (value)
  (not (eq (%classify-structured-value value) :scalar)))

(defun %normalize-single-port-structure (value ports)
  (let ((first-port (first ports)))
    (ecase (%classify-structured-value value)
      (:hash-table (gethash first-port value))
      (:alist (cdr (assoc first-port value :test #'equal)))
      (:plist (%plist-value value first-port)))))

(defun %normalize-structured-input (value ports)
  (let ((port-count (length ports)))
    (cond
      ((and (= port-count 1) (%structured-value-p value))
       (%normalize-single-port-structure value ports))
      ((%structured-value-p value)
       (%normalize-port-alist value ports))
      (t value))))

(defun %normalize-output-structure (value ports)
  (let ((first-port (first ports)))
    (cond
      ((null ports) value)
      ((%structured-value-p value)
       (%normalize-port-alist value ports))
      (t (list (cons first-port value))))))

(defun %node-designator-name (designator)
  (typecase designator
    (node (node-name designator))
    (t (%normalize-name designator))))
