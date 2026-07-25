(in-package #:cl-dataflow.test)

(defmacro with-traffic-light ((machine) &body body)
  "A small cyclic machine: green -> yellow -> red -> green, plus an unreachable
'broken' state and a terminal 'off' state reachable via a power event."
  `(with-state-machine-fixture (,machine
                                :state "green"
                                :transitions ((g->y "green" "tick" "yellow")
                                              (y->r "yellow" "tick" "red")
                                              (r->g "red" "tick" "green")
                                              (g->off "green" "power" "off")
                                              (broken->g "broken" "reset" "green")))
     ,@body))

(deftest state-machine-states-and-events-are-sorted
  (with-traffic-light (machine)
    (is (equal (state-machine-states machine)
               '("broken" "green" "off" "red" "yellow")))
    (is (equal (state-machine-event-types machine)
               '("power" "reset" "tick")))))

(deftest state-machine-reachable-states-from-initial
  (with-traffic-light (machine)
    ;; 'broken' only points into the cycle; nothing points into it.
    (is (equal (state-machine-reachable-states machine)
               '("green" "off" "red" "yellow")))
    (is (equal (state-machine-reachable-states machine :from "red")
               '("green" "off" "red" "yellow")))
    (is (equal (state-machine-reachable-states machine :from "missing") '()))))

(deftest state-machine-unreachable-states-are-detected
  (with-traffic-light (machine)
    (is (equal (state-machine-unreachable-states machine) '("broken")))))

(deftest state-machine-terminal-states-are-detected
  (with-traffic-light (machine)
    ;; 'off' has no outgoing transition.
    (is (equal (state-machine-terminal-states machine) '("off")))))

(deftest state-machine-determinism-checks-from-event-pairs
  (with-traffic-light (machine)
    (is (state-machine-deterministic-p machine)))
  (with-state-machine-fixture (machine
                               :state "idle"
                               :transitions ((a "idle" "go" "left")
                                             (b "idle" "go" "right")))
    ;; Two transitions share (idle, go), so the machine is not structurally deterministic.
    (is (not (state-machine-deterministic-p machine)))))

(deftest state-machine->dot-renders-initial-marker-and-transitions
  (with-state-machine-fixture (machine
                               :state "idle"
                               :transitions ((start "idle" "start" "running")))
    (let ((dot (state-machine->dot machine :name "sm")))
      (is (search "digraph sm {" dot))
      (is (search "__start -> \"idle\";" dot))
      (is (search "\"idle\" -> \"running\" [label=\"start\"];" dot))
      (is (equal dot
                 (with-output-to-string (out)
                   (is (eq machine (write-state-machine-dot machine out :name "sm")))))))))

(deftest state-machine->mermaid-renders-state-diagram
  (with-state-machine-fixture (machine
                               :state "idle"
                               :transitions ((start "idle" "start" "running")))
    (let ((mermaid (state-machine->mermaid machine)))
      (is (search "stateDiagram-v2" mermaid))
      (is (search "[*] --> " mermaid))
      ;; idle sorts before running, so idle is s0 and running is s1.
      (is (search "state \"idle\" as s0" mermaid))
      (is (search "s0 --> s1: start" mermaid))
      (is (equal mermaid
                 (with-output-to-string (out)
                   (is (eq machine (write-state-machine-mermaid machine out)))))))))

(deftest state-machine-renderers-escape-control-characters
  (let* ((spoof (format nil "spoof~%tab~Creturn~Cdel~Cend"
                        #\Tab #\Return (code-char 127)))
         (machine (make-state-machine
                   :state (format nil "idle-~A" spoof)
                   :transitions (list (make-transition (format nil "idle-~A" spoof)
                                                       (format nil "start-~A" spoof)
                                                       (format nil "running-~A" spoof))))))
    (dolist (rendered (list (state-machine->dot machine
                                                :name (format nil "sm-~A" spoof))
                            (state-machine->mermaid machine)))
      (is (search "\\ntab" rendered))
      (is (search "\\treturn" rendered))
      (is (search "\\rdel" rendered))
      (is (search "\\x7F;end" rendered))
      (is (not (search (format nil "~%tab") rendered)))
      (is (not (search (format nil "~Creturn" #\Tab) rendered)))
      (is (not (search (format nil "~Cdel" #\Return) rendered)))
      (is (not (search (format nil "~Cend" (code-char 127)) rendered))))))

(deftest state-machine-successor-table-deduplicates-parallel-transitions
  ;; Two transitions go draft -> review on different events; reachability must
  ;; treat draft -> review as a single successor edge, not double-count it.
  (with-state-machine-fixture (machine
                               :state "draft"
                               :transitions ((submit "draft" "submit" "review")
                                             (resubmit "draft" "resubmit" "review")
                                             (approve "review" "approve" "done")))
    (is (equal (state-machine-reachable-states machine) '("done" "draft" "review")))
    ;; Distinct events on parallel draft -> review edges keep it structurally
    ;; deterministic (the (from, event) pairs differ).
    (is (state-machine-deterministic-p machine))))

(deftest state-machine-rendering-orders-multiple-transitions
  ;; Exercises the transition-sort path with several transitions to render.
  (with-state-machine-fixture (machine
                               :state "a"
                               :transitions ((t1 "a" "go" "b")
                                             (t2 "b" "go" "c")
                                             (t3 "a" "skip" "c")))
    (let ((dot (state-machine->dot machine)))
      ;; Sorted by (from, event, to): a/go/b, a/skip/c, b/go/c.
      (is (< (search "\"a\" -> \"b\"" dot)
             (search "\"a\" -> \"c\"" dot)))
      (is (< (search "\"a\" -> \"c\"" dot)
             (search "\"b\" -> \"c\"" dot))))
    ;; a=s0, b=s1, c=s2; the b -> c transition renders as s1 --> s2.
    (is (search "s1 --> s2: go" (state-machine->mermaid machine)))))
