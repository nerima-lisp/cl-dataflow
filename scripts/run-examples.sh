#!/usr/bin/env sh

# Runs every examples/*.lisp script as a plain, standalone subprocess, each
# under its own timeout. This is deliberately NOT the same path as
# t/core-runtime-example-test.lisp's own smoke tests: those spawn examples
# through cl-process-kit's `run` from inside the running cl-weave test
# process, which is exactly the "implementation-specific run-program
# deadlock" that file's own docstring warns about and stays opt-in
# (CL_DATAFLOW_RUN_EXAMPLE_SMOKE) to avoid -- confirmed by reproducing the
# hang directly. Running each script as its own top-level `sbcl` process from
# a plain shell loop has no such parent-process entanglement, so it is the
# safe way to actually exercise every example on a schedule (CI/local),
# rather than leaving them permanently unverified.
#
# CL_SOURCE_REGISTRY must already resolve cl-dataflow and cl-prolog; the
# devShell and flake checks set it.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# The first example pays a full from-scratch ASDF compile of every src/*.lisp
# file; every example after it reuses the now-warm fasl cache and finishes
# in a fraction of that. 60s gives the cold compile headroom without letting
# a genuinely hung script run indefinitely.
TIMEOUT_SECONDS=${EXAMPLE_TIMEOUT_SECONDS:-60}

run_with_timeout() {
  # Plain `timeout N` only sends SIGTERM once and then waits for the child to
  # actually exit -- a process that doesn't respond promptly (or at all) to
  # SIGTERM keeps running past the deadline with `timeout` itself still
  # blocked on it, which defeats the point of a timeout. `--kill-after`
  # forces a SIGKILL escalation if SIGTERM hasn't worked within the grace
  # period, so the deadline is real regardless of what the child does.
  #
  # GNU coreutils' `timeout` isn't on PATH by default on macOS. `gtimeout`
  # covers a Homebrew coreutils install; the `perl` fallback forks a watchdog
  # that SIGKILLs the child if it outlives the deadline, needing nothing
  # beyond what every target platform already ships.
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=5 "$TIMEOUT_SECONDS" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=5 "$TIMEOUT_SECONDS" "$@"
  else
    perl -e '
      my $timeout_seconds = shift @ARGV;
      my $pid = fork;
      if ($pid == 0) { exec @ARGV or die "exec failed: $!"; }
      local $SIG{ALRM} = sub {
        kill "TERM", $pid;
        sleep 5;
        kill "KILL", $pid;
      };
      alarm($timeout_seconds);
      waitpid($pid, 0);
      exit($? >> 8);
    ' "$TIMEOUT_SECONDS" "$@"
  fi
}

failures=0
count=0
for script in examples/*.lisp; do
  count=$((count + 1))
  output=$(mktemp)
  printf 'running %s ... ' "$script"
  if run_with_timeout sbcl --script "$script" >"$output" 2>&1; then
    printf 'ok\n'
  else
    status=$?
    printf 'FAILED (exit %d)\n' "$status"
    cat "$output"
    failures=$((failures + 1))
  fi
  rm -f "$output"
done

if [ "$failures" -gt 0 ]; then
  printf '%d of %d example(s) failed\n' "$failures" "$count" >&2
  exit 1
fi

printf 'all %d examples ran successfully\n' "$count"
