# Core Concepts

`cl-dataflow` is built from a small number of composable primitives. Every
other page in this guide builds on these definitions.

| Concept | Definition |
| --- | --- |
| **Node** | A named computation with input ports, output ports, and a handler. |
| **Edge** | A connection from one node's output port to another node's input port. |
| **Graph** | A collection of nodes and edges with validation and topological ordering. |
| **Context** | Runtime state for events, effects, trace data, and workflow metadata. |
| **Pipeline** | An executable graph or ordered stage list. |
| **Event** | A recorded workflow occurrence with a payload and trace position. |
| **Effect** | A tracked side effect with handler lookup and result capture. |
| **State Machine** | A small transition model with guards and actions. |
| **Workflow** | A pipeline that emits events, triggers effects, and drives a state machine. |

## Nodes, edges, and graphs

A `node` is created with `make-node` and carries a `:handler` — a function of
`(input context)` that returns the value passed downstream. `graph`s hold
nodes and edges (`add-node`/`add-edge`), validate structural invariants
(`validate-graph`), and provide `topological-sort` for deterministic execution
order. Node names are unique within a graph, and edges are unique by
`(from-node from-port to-node to-port)`, so `add-node`/`add-edge` reject
duplicates rather than silently retargeting or double-counting a connection.
See [Graphs](graphs.md) for the full construction, mutation, and export API,
and [Graph Algorithms](graph-algorithms.md) /
[Graph Analysis](graph-analysis.md) for the analysis layer built on top of
it.

## Context

A `context` carries everything a pipeline run accumulates: per-node result
values, an ordered event log, an ordered effect log, a unified trace across
node/event/effect/transition entries, arbitrary metadata, the registered
effect-handler table, the current state-machine state (`context-state`), and
the final `context-result`. Every collection reader — `context-values`,
`context-events`, `context-effects`, `context-trace`, and
`context-effect-handlers` included — returns an independent snapshot, so
inspecting a running context never risks mutating it by accident. The event,
effect, and trace logs are stored newest-first; the `-in-order` readers
(`context-events-in-order`, `context-effects-in-order`,
`context-trace-in-order`, and the filtered `context-trace-of-kind`) return
them chronologically. Because the handler table is readable only as a
snapshot, handlers are registered through `register-effect-handler` — or
scoped with `with-effect-handler-scope` — rather than by mutating what
`context-effect-handlers` hands back. `copy-context` clones the handler table
too, so a forked context can register different handlers without cross-talk
with the original.

## Pipelines and workflows

A `pipeline` wraps a `graph` (or a plain ordered stage list) and executes it
against a context with `run-pipeline`/`run-pipeline-with-context`. Node
handlers receive structured input normalized from hash tables, alists,
plists, or scalars, and their structured output is normalized back into the
context and the sink's result. `define-pipeline`, `define-state-machine`, and
`define-workflow` are declarative macro entry points that keep graph
structure and transition data separate from handler logic — see
[Pipelines and Workflows](pipelines.md).

## Events, effects, and state machines

`event`s (`make-event`/`emit-event`) and `effect`s (`make-effect`/`perform-effect`)
are how a pipeline stage records a workflow occurrence or a tracked side
effect. A `state-machine` (`make-state-machine`/`step-state-machine`) is a
guarded transition model: `step-state-machine` advances the machine in place
and returns it, with a transition record as a second value; when given a
`context` it also updates `context-state` and appends the transition to
`context-trace` — so a state machine can be stepped from inside pipeline and
workflow handlers. `make-state-machine-node` turns a state machine into an
ordinary pipeline stage, and `define-workflow` unifies graph
edges, transitions, and embedded machine nodes in one macro expansion while
still returning plain `pipeline` and `state-machine` values. See
[State Machines](state-machines.md) and [Events and Effects](events-and-effects.md).

## Copying and equality

Explicit clone helpers — `copy-context`, `copy-event`, `copy-effect`,
`copy-pipeline`, `copy-state-machine`, `copy-graph` — exist for every mutable
runtime value, so derived runs can evolve independently from the value they
were copied from. Structural equality predicates (`pipeline-equal-p`,
`state-machine-equal-p`, `context-equal-p`, `graph-equal-p`) compare values
through their deterministic plist serialization, ignoring runtime closures
such as handlers, guards, and actions.

## Protocols

`flow-name`, `flow-metadata`, and `flow-kind` provide consistent introspection
across every flow object — nodes, edges, graphs, contexts, events, effects,
transitions, state machines, and pipelines all implement the same protocol,
so generic tooling (like the observability layer) can treat them uniformly.
See [Observability and Serialization](observability.md).
