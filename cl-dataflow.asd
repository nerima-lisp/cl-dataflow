(in-package #:asdf-user)

;;; System names are written as STRINGS rather than #:symbols or :keywords, so
;;; that reading this file never depends on the reader's current package state.
(defsystem "cl-dataflow"
  :description "Composable computation graphs, pipelines, events, state machines, and effect boundaries."
  :long-description "cl-dataflow is a small, dependency-light Common Lisp library for
building composable pipelines, event-driven workflows, and stateful computation
graphs. It provides graphs and nodes, sequential and branching pipelines,
event and effect boundaries, guarded state machines, and deterministic testing
helpers, all behind a single public package."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  ;; Single source of truth for the version: flake.nix reads this form and
  ;; release.yml refuses to publish a tag that disagrees with it.
  :version "1.0.0"
  :homepage "https://github.com/nerima-lisp/cl-dataflow"
  :source-control (:git "https://github.com/nerima-lisp/cl-dataflow.git")
  :bug-tracker "https://github.com/nerima-lisp/cl-dataflow/issues"
  ;; cl-prolog backs the graph edge relation (src/graph-runtime-prolog.lisp).
  ;; It is the only runtime dependency; see DEPENDENCY_POLICY.md (L3, depth 1).
  :depends-on ("cl-prolog")
  :serial t
  :pathname "src/"
  :components ((:file "package")
                (:file "core-normalization")
                (:file "core-copying")
                (:file "core-slot-accessors")
                (:file "core-runtime-helpers")
                (:file "core-conditions")
                (:file "core-models-classes")
                (:file "core-models-copying")
                (:file "core-models-slot-accessors")
                (:file "core-models-constructors")
                (:file "core-context-accessors")
                (:file "graph-runtime-validation")
                (:file "graph-runtime-prolog")
                (:file "graph-runtime-topology")
                (:file "graph-runtime-bindings")
                (:file "graph-runtime-builders")
                (:file "protocols")
                (:file "events")
                (:file "effects")
                (:file "state-machine-macros")
                (:file "state-machine-runtime-core")
                (:file "state-machine-runtime-cps")
                (:file "state-machine-runtime-api")
                (:file "pipeline-macros")
                (:file "pipeline-runtime")
                (:file "graph-structure")
                (:file "graph-components")
                (:file "graph-export")
                (:file "graph-builders")
                (:file "graph-closure")
                (:file "graph-paths")
                (:file "graph-shortest-path")
                (:file "graph-flow")
                (:file "graph-eulerian")
                (:file "graph-metrics")
                (:file "graph-distance")
                (:file "graph-algebra")
                (:file "graph-criticality")
                (:file "state-machine-analysis")
                (:file "state-machine-execution")
                (:file "state-machine-builders")
                (:file "combinators")
                (:file "contracts")
                (:file "streams")
                (:file "stream-extras")
                (:file "stream-ops")
                (:file "stream-stats")
                (:file "stream-search")
                (:file "observability")
                (:file "effects-ext")
                (:file "pipeline-ext")
                (:file "pipeline-iteration")
                (:file "events-ext")
                (:file "introspection")
                (:file "context-serialization")
                (:file "equality-predicates")
                (:file "reactive")
                (:file "reactive-ops")
                (:file "testing"))
  :in-order-to ((test-op (test-op "cl-dataflow/test"))))

;;; The test system is `cl-dataflow/test` (singular, slash-separated) with
;;; :pathname "t". It is NOT `cl-dataflow-test` and NOT `cl-dataflow/tests`.
(defsystem "cl-dataflow/test"
  :description "Test system for cl-dataflow."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "1.0.0"
  :homepage "https://github.com/nerima-lisp/cl-dataflow"
  :source-control (:git "https://github.com/nerima-lisp/cl-dataflow.git")
  :bug-tracker "https://github.com/nerima-lisp/cl-dataflow/issues"
  :depends-on ("cl-dataflow"
                ;; cl-weave is the org's test framework everywhere.
                "cl-weave"
                ;; Test-only: t/core-runtime-example-test.lisp runs each
                ;; examples/*.lisp script as a subprocess under a timeout and
                ;; asserts on its exit code and captured output, which needs
                ;; real process control. The shipped cl-dataflow system stays
                ;; at its single cl-prolog dependency.
                "cl-process-kit")
  :serial t
  :pathname "t/"
  :components ((:file "package")
                (:file "test-support-assertions")
                (:file "test-support-fixtures")
                (:file "test-runner")
                (:file "core-graph-structure-test")
                (:file "core-graph-api-test")
                (:file "core-model-mutation-test")
                (:file "core-model-state-machine-test")
                (:file "core-model-node-edge-test")
                (:file "core-model-context-event-effect-test")
                (:file "core-model-observability-test")
                (:file "core-model-internal-test")
                (:file "core-runtime-example-test")
                (:file "core-runtime-protocol-test")
                (:file "core-runtime-graph-test")
                (:file "core-runtime-test")
                (:file "events-test")
                (:file "state-machine-dsl-test")
                (:file "state-machine-step-test")
                (:file "state-machine-run-test")
                (:file "state-machine-runtime-node-test")
                (:file "state-machine-runtime-state-test")
                (:file "state-machine-guard-selection-test")
                (:file "state-machine-model-property-test")
                (:file "effects-test")
                (:file "pipeline-dsl-test")
                (:file "pipeline-runtime-contract-test")
                (:file "pipeline-runtime-structure-test")
                (:file "pipeline-runtime-plan-cache-test")
                (:file "pipeline-runtime-execution-test")
                (:file "pipeline-runtime-branching-test")
                (:file "cl-weave-advanced-test")
                (:file "graph-advanced-property-test")
                (:file "graph-algorithms-test")
                (:file "graph-export-test")
                (:file "graph-builders-test")
                (:file "graph-closure-test")
                (:file "graph-paths-test")
                (:file "graph-shortest-path-test")
                (:file "graph-flow-test")
                (:file "graph-eulerian-test")
                (:file "graph-metrics-test")
                (:file "graph-connectivity-test")
                (:file "graph-algebra-test")
                (:file "graph-criticality-test")
                (:file "state-machine-analysis-test")
                (:file "state-machine-execution-test")
                (:file "state-machine-builders-test")
                (:file "combinators-test")
                (:file "contracts-test")
                (:file "streams-test")
                (:file "streams-property-test")
                (:file "stream-extras-test")
                (:file "stream-ops-test")
                (:file "stream-stats-test")
                (:file "stream-search-test")
                (:file "observability-test")
                (:file "effects-ext-test")
                (:file "pipeline-ext-test")
                (:file "pipeline-iteration-test")
                (:file "events-ext-test")
                (:file "introspection-test")
                (:file "context-serialization-test")
                (:file "equality-predicates-test")
                (:file "reactive-test")
                (:file "reactive-ops-test")
                (:file "mutation-test"))
  :perform (test-op (o c)
    (uiop:symbol-call '#:cl-dataflow.test '#:run-tests)))
