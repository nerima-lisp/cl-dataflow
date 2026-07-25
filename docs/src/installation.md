# Installation

`cl-dataflow` depends on [`cl-prolog`](https://github.com/nerima-lisp/cl-prolog),
which powers the graph reachability core. The test system additionally depends
on [`cl-weave`](https://github.com/nerima-lisp/cl-weave) and
[`cl-process-kit`](https://github.com/nerima-lisp/cl-process-kit).

=== "Nix (recommended)"

    The flake pins every dependency, including SBCL, `cl-prolog`, and `cl-weave`,
    so `nix develop` reproduces the exact verified environment:

    ```bash
    nix develop      # drop into a shell with everything on CL_SOURCE_REGISTRY
    nix run          # run the cl-weave test app against cl-dataflow/test
    nix flake check  # run the full check matrix (tests, coverage, paredit lint)
    ```

    `nix build .#docs` builds this documentation site offline, the same way
    the GitHub Pages workflow does.

=== "ASDF local checkout"

    Place this checkout, and `cl-prolog`, somewhere ASDF can see, then load the
    system directly:

    ```lisp
    (asdf:load-system :cl-dataflow)
    ```

    Register the repository directory in `asdf:*central-registry*` first if it
    is not already on ASDF's default source registry paths.

=== "Quicklisp local-projects"

    Clone the repository (and `cl-prolog`) under Quicklisp's `local-projects`
    directory:

    ```text
    ~/quicklisp/local-projects/cl-dataflow/
    ~/quicklisp/local-projects/cl-prolog/
    ```

    Then load it as usual:

    ```lisp
    (ql:quickload :cl-dataflow)
    ```

## Verifying the install

Confirm the system loads and a trivial pipeline runs:

```lisp
(asdf:load-system :cl-dataflow)

(cl-dataflow:run-pipeline
  (cl-dataflow:define-pipeline ()
    (:node "double" :handler (lambda (input context)
                                (declare (ignore context))
                                (* 2 input))))
  :input 21)
;; => 42
```

If you want to run the full test suite locally (requires `cl-weave` and
`cl-process-kit` on the source registry as well), see
[Testing and Coverage](testing.md).

## Next steps

Continue with [Quick Start](quick-start.md) for a slightly larger pipeline, or
jump straight to [Core Concepts](core-concepts.md) for the vocabulary used
throughout the rest of the guide.
