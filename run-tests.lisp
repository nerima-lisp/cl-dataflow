;;;; Lisp-level entry point for the cl-dataflow test suite.
;;;;
;;;;     sbcl --script run-tests.lisp
;;;;     nix run .#test
;;;;
;;;; This is the single entry point the org standard asks for, so that the
;;;; suite can be started without the cl-weave CLI on PATH. CL_SOURCE_REGISTRY
;;;; must already resolve cl-dataflow and its dependencies; flake.nix sets it
;;;; for `nix flake check`, `nix run .#test` and `nix develop`.

(require :asdf)

;; Anchor relative paths (notably cl-weave's __snapshots__/ directory) to this
;; file rather than to the caller's working directory, because the flake runs
;; the script by absolute store path from a scratch build directory.
(setf *default-pathname-defaults*
      (make-pathname :name nil :type nil :version nil
                     :defaults (or *load-truename* *default-pathname-defaults*)))

(handler-case
    (progn
      (asdf:load-system "cl-dataflow/test")
      (uiop:symbol-call '#:cl-dataflow.test '#:run-tests))
  (error (condition)
    (format *error-output* "~&cl-dataflow test suite failed:~%~A~%" condition)
    (uiop:quit 1)))

(uiop:quit 0)
