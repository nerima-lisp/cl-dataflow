(in-package #:cl-user)

(defparameter *bootstrap-pathname* (or *load-truename* *load-pathname* *default-pathname-defaults*))

(defun bootstrap-directory ()
  (make-pathname :name nil :type nil :defaults *bootstrap-pathname*))

(defun repository-directory ()
  (merge-pathnames #P"../" (bootstrap-directory)))

(defun use-interpreted-loading-when-available ()
  (let* ((package (find-package "SB-EXT"))
         (evaluator-mode (and package (find-symbol "*EVALUATOR-MODE*" package))))
    (when evaluator-mode
      (setf (symbol-value evaluator-mode) :interpret))))

;; find-symbol defers every ASDF reference to after (require :asdf) runs, so
;; this file never takes a read-time dependency on the ASDF package existing.
;; Loading the "cl-dataflow" system -- rather than hand-listing its source
;; files, which previously drifted out of sync with cl-dataflow.asd whenever
;; a file was renamed or split -- lets ASDF resolve load order and the
;; cl-prolog :depends-on itself.
(defun load-cl-dataflow ()
  (use-interpreted-loading-when-available)
  (require :asdf)
  (push (repository-directory) (symbol-value (find-symbol "*CENTRAL-REGISTRY*" "ASDF")))
  (funcall (find-symbol "LOAD-SYSTEM" "ASDF") "cl-dataflow"))

(load-cl-dataflow)
