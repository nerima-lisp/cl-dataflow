# cl-dataflow

`cl-dataflow` is a small Common Lisp library for composable computation
graphs, pipelines, event-driven workflows, guarded state machines, and effect
boundaries. It is dependency-light (`cl-prolog` powers the graph reachability
core), keeps its entire public surface behind a single package, and is
verified on every push with a 100%-branch-coverage test suite.

!!! tip "New to cl-dataflow?"

    Load the system, then run your first pipeline in under a minute:

    ```lisp
    (asdf:load-system :cl-dataflow)
    ```

    Continue with [Installation](installation.md) → [Quick Start](quick-start.md)
    → [Core Concepts](core-concepts.md).

## Explore the docs

<div class="grid cards" markdown>

-   :material-rocket-launch:{ .lg .middle } &nbsp; **Getting Started**

    ---

    Every install path, your first passing pipeline, and the vocabulary
    (nodes, edges, graphs, contexts, workflows) the rest of the docs build on.

    [:octicons-arrow-right-24: Installation](installation.md) ·
    [Quick Start](quick-start.md) ·
    [Core Concepts](core-concepts.md)

-   :material-graph-outline:{ .lg .middle } &nbsp; **Graphs**

    ---

    Build, validate, mutate, and export dependency graphs, then reach for
    thirty-plus algorithms: connectivity, centrality, criticality, flow, and
    weighted shortest paths.

    [:octicons-arrow-right-24: Graphs](graphs.md) ·
    [Graph Algorithms](graph-algorithms.md)

-   :material-sitemap-outline:{ .lg .middle } &nbsp; **Pipelines and State**

    ---

    Sequential and branching pipelines, feedback/fixpoint iteration, guarded
    state machines, and events/effects that let one workflow drive another.

    [:octicons-arrow-right-24: Pipelines and Workflows](pipelines.md) ·
    [State Machines](state-machines.md) ·
    [Events and Effects](events-and-effects.md)

-   :material-waveform:{ .lg .middle } &nbsp; **Streams and Reactive**

    ---

    A lazy pull-based transducer layer and its push-based reactive dual, plus
    handler combinators for retry, fallback, memoization, and contracts.

    [:octicons-arrow-right-24: Streams (Pull)](streams.md) ·
    [Reactive Subjects (Push)](reactive.md) ·
    [Combinators and Resilience](combinators.md)

</div>

## Status

- Core graph, pipeline, event, effect, and state-machine primitives are implemented.
- Runnable examples live under `examples/`; see [Examples](examples.md).
- The canonical test system is `cl-dataflow/test`, and `asdf:test-system :cl-dataflow` dispatches to it.
- The repository verifies cleanly on SBCL with all tests and example scripts passing, on both `x86_64-linux` and `aarch64-darwin` in CI.

The full feature-by-feature status table lives in [Architecture](architecture.md#implementation-status),
and the complete exported-symbol listing lives in [Public API Reference](api-reference.md).

## Design Non-Goals

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

## License

MIT — see [LICENSE](https://github.com/nerima-lisp/cl-dataflow/blob/main/LICENSE).
