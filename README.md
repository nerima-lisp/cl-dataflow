# cl-dataflow

[![CI](https://github.com/nerima-lisp/cl-dataflow/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-dataflow/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](https://nerima-lisp.github.io/cl-dataflow/)

`cl-dataflow` is a Common Lisp library for composable computation graphs:
pipelines, event-driven workflows, guarded state machines, effect boundaries,
lazy streams, and their push-based reactive dual. It targets SBCL, exports a
single package, and takes exactly one runtime dependency — `cl-prolog`, which
backs the graph edge relation. Where a general-purpose graph library gives you
data structures, `cl-dataflow` gives you a runtime: graphs that execute, carry a
context, record a trace, and hand control to a state machine.

Full documentation is published at <https://nerima-lisp.github.io/cl-dataflow/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```lisp
(asdf:load-system "cl-dataflow")

(defparameter *pipeline*
  (cl-dataflow:define-pipeline ()
    (:node "start"
     :handler (lambda (input context)
                (declare (ignore context))
                (1+ input)))
    (:node "finish"
     :handler (lambda (input context)
                (declare (ignore context))
                (* input 2)))
    (:edge "start" "finish")))

(cl-dataflow:run-pipeline *pipeline* :input 10)
;; => 22
```

## Install

```nix
# flake.nix
inputs.cl-dataflow = {
  url = "github:nerima-lisp/cl-dataflow/v1.0.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Note the pinned tag. Consumers inside this org pin a release tag rather than
follow the default branch.

Outside Nix, put this checkout and `cl-prolog` somewhere ASDF can see them —
`~/quicklisp/local-projects/`, `asdf:*central-registry*`, or
`CL_SOURCE_REGISTRY` — then add `"cl-dataflow"` to your system's
`:depends-on`. Full instructions are in
[Installation](https://nerima-lisp.github.io/cl-dataflow/installation/).

## Documentation

- [Quick Start](https://nerima-lisp.github.io/cl-dataflow/quick-start/) — one
  pipeline, start to finish
- [Core Concepts](https://nerima-lisp.github.io/cl-dataflow/core-concepts/) —
  nodes, edges, graphs, contexts, events, effects, state machines
- [API Reference](https://nerima-lisp.github.io/cl-dataflow/api-reference/) —
  every exported symbol
- [Architecture](https://nerima-lisp.github.io/cl-dataflow/architecture/) —
  how the runtime is split, and the feature-by-feature status table

## Development

```sh
nix develop          # SBCL with CL_SOURCE_REGISTRY already set
nix run .#test       # run the test suite
nix run .#watch      # re-run the suite on every source change
nix flake check      # tests + coverage + lint + formatting + docs, as CI runs it
nix fmt              # format Nix sources (treefmt)
```

Without Nix, `sbcl --script run-tests.lisp` runs the same suite, given a
`CL_SOURCE_REGISTRY` that resolves the dependencies.

Tests live in `t/` and run under
[cl-weave](https://github.com/nerima-lisp/cl-weave), the org's test framework.
`nix flake check` additionally enforces the coverage gate (84% expression, 100%
branch), the `paredit` lint pass, and a `mkdocs --strict` docs build.
See [Development](https://nerima-lisp.github.io/cl-dataflow/development/).

## Contributing

See the org-wide [CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide and the [package standard](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md).

## Support

See [SUPPORT](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md).

## License

MIT. See [LICENSE](LICENSE).
