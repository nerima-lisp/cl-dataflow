# cl-dataflow

`cl-dataflow` is a Common Lisp library for composable computation graphs:
pipelines, event-driven workflows, guarded state machines, effect boundaries,
lazy streams, and their push-based reactive dual. It targets SBCL, keeps its
entire public surface behind a single package, and takes exactly one runtime
dependency — [`cl-prolog`](https://nerima-lisp.github.io/cl-prolog/), which
backs the graph edge relation. Where a general-purpose graph library gives you
data structures, `cl-dataflow` gives you a runtime: graphs that execute, carry
a context, record a trace, and hand control to a state machine.

```lisp
(asdf:load-system "cl-dataflow")

(cl-dataflow:run-pipeline *pipeline* :input 10)
;; => 22
```

## Where to go next

**New here?** [Installation](installation.md) →
[Quick Start](quick-start.md) → [Core Concepts](core-concepts.md).
Those three pages get you from an empty REPL to a running pipeline, plus the
vocabulary the rest of the site assumes.

**Building graphs.** [Graphs](graphs.md) covers construction, validation,
mutation, and export; [Graph Algorithms](graph-algorithms.md) and
[Graph Analysis](graph-analysis.md) cover the thirty or so analyses on top —
connectivity, centrality, criticality, flow, and weighted shortest paths.

**Running work through them.** [Pipelines and Workflows](pipelines.md) for
sequential, branching, and fixpoint execution;
[State Machines](state-machines.md) for guarded transitions;
[Events and Effects](events-and-effects.md) for the boundaries that let one
workflow drive another.

**Processing sequences.** [Streams (Pull)](streams.md) is a lazy transducer
layer, [Reactive Subjects (Push)](reactive.md) is its producer-driven dual, and
[Combinators and Resilience](combinators.md) adds retry, fallback,
memoization, and contracts around handlers.
[Observability and Serialization](observability.md) covers rendering and
round-tripping what ran.

**Looking something up.** [Public API Reference](api-reference.md) lists every
exported symbol. [Architecture](architecture.md) explains how the runtime is
split and carries the feature-by-feature status table.
[Development](development.md) has the build, test, and coverage commands.

## Design non-goals

`cl-dataflow` is intentionally not:

- a CLI framework
- parser combinators
- terminal or TTY handling
- a Prolog engine
- an HTTP server
- a database adapter
- a distributed execution runtime
- an async runtime
- a large dependency injection framework
- a generic utility package

## Project

Contribution guidelines, the security policy, and the code of conduct are
org-wide and live in
[nerima-lisp/.github](https://github.com/nerima-lisp/.github).

MIT licensed — see
[LICENSE](https://github.com/nerima-lisp/cl-dataflow/blob/main/LICENSE).
