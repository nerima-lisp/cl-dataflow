(in-package #:cl-dataflow.test)

(defun %repository-root ()
  "The checkout root, resolved through ASDF's own system location rather than
*LOAD-TRUENAME*/*LOAD-PATHNAME* -- those are only bound during a LOAD's dynamic
extent, so a reflection-based lookup breaks once tests actually run instead of
load. ASDF:SYSTEM-SOURCE-DIRECTORY returns the directory holding cl-dataflow.asd
itself (the checkout root), since both systems are declared there."
  (asdf:system-source-directory "cl-dataflow/test"))

(defparameter *example-script-timeout-seconds* 30)
(defparameter *program-probe-timeout-seconds* 10)

(defun %example-smoke-tests-enabled-p ()
  "Return true when tests should spawn external SBCL example processes.

The verification script runs examples as a separate step. Keeping in-suite
example process spawning opt-in avoids implementation-specific run-program
deadlocks in the main test process."
  (string= (uiop:getenv "CL_DATAFLOW_RUN_EXAMPLE_SMOKE") "1"))

(defun %program-available-p (program)
  "Return true when PROGRAM can be launched on this machine.

Used to decide whether the example smoke tests can spawn an SBCL runner. A
launch failure (e.g. the binary is absent from PATH) is treated as
unavailable rather than a test failure, so the suite stays green on CI images
that build under a non-SBCL implementation."
  (handler-case
      (progn
        (run program (list "--version")
             :timeout-seconds *program-probe-timeout-seconds*
             :on-timeout :return)
        t)
    (error () nil)))

(defun %run-example-script (relative-path)
  "Run the example script at RELATIVE-PATH and return (VALUES OUTPUT RAN-P).

RAN-P is true only when an SBCL runner was available and the script was
actually executed; when it is false the caller should skip its smoke
assertions. Prefers a system SBCL, then falls back to `nix run nixpkgs#sbcl`."
  (unless (%example-smoke-tests-enabled-p)
    (return-from %run-example-script (values nil nil)))
  (let ((script (namestring (merge-pathnames relative-path (%repository-root)))))
    (labels ((run-with (program arguments)
               (run program (append arguments (list script))
                    :timeout-seconds *example-script-timeout-seconds*
                    :on-timeout :return))
             (check (result)
               (is (not (process-result-timed-out-p result))
                   (format nil "Example script timed out after ~D seconds: ~A"
                           *example-script-timeout-seconds*
                           relative-path))
               (is (eql (process-result-exit-code result) 0))
               (is (stringp (process-result-stderr result)))
               (values (process-result-stdout result) t)))
      (cond
        ((%program-available-p "sbcl")
         (check (run-with "sbcl" '("--script"))))
        ((%program-available-p "nix")
         (check (run-with "nix" '("run" "nixpkgs#sbcl" "--" "--script"))))
        (t
         (values nil nil))))))

(define-example-script-tests
  (example-simple-pipeline-script-runs
   "examples/simple-pipeline.lisp"
   "Simple pipeline result: rendered: 70")
  (example-event-workflow-script-runs
   "examples/event-workflow.lisp"
   "Workflow state: order-confirmed"
   "reserve-inventory"
   "order-confirmed")
  (example-state-machine-script-runs
   "examples/state-machine.lisp"
   "Final state: completed"
   "Transition count: 2")
  (example-graph-analysis-script-runs
   "examples/graph-analysis.lisp"
   "Downstream of parse"
   "Shortest path ingest -> load"
   "Sources: (\"ingest\")")
  (example-graph-toolkit-script-runs
   "examples/graph-toolkit.lisp"
   "Order: 4  Size: 4"
   "Distance a -> d: 2"
   "Strongly connected components: ((\"x\" \"y\" \"z\"))"
   "digraph deps {")
  (example-state-machine-visualization-script-runs
   "examples/state-machine-visualization.lisp"
   "Unreachable states: (\"archived\")"
   "Terminal states: (\"cancelled\" \"shipped\")"
   "stateDiagram-v2")
  (example-resilient-pipeline-script-runs
   "examples/resilient-pipeline.lisp"
   "Retry result: 70 (after 3 attempts)"
   "Fallback on odd 3: -1"
   "Sequenced (double then increment) of 20: 41")
  (example-streams-script-runs
   "examples/streams.lisp"
   "First 3 even squares: (4 16 36)"
   "Running totals: (0 1 3 6 10)"
   "Sum of distinct values: 10")
  (example-graph-analysis-advanced-script-runs
   "examples/graph-analysis-advanced.lisp"
   "Critical path: (\"fetch\" \"compile\" \"lint\" \"package\")"
   "Edges after transitive reduction: 5 (was 6)"
   "Round-trips to an equal graph? T")
  (example-stream-analytics-script-runs
   "examples/stream-analytics.lisp"
   "Frequencies: ((:CLICK . 3) (:VIEW . 3) (:PURCHASE . 1))"
   "Window averages: (2 3 4 5)"
   "Mean of 1..100: 101/2")
  (example-integration-script-runs
   "examples/integration.lisp"
   "Priced orders: (30 70 120)"
   "High-value alerts (> 50): (70 120)"
   "Context round-trips through a plist: T"))
