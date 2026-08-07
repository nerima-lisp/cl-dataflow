#!/usr/bin/env sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

OUTPUT=${COVERAGE_OUTPUT:-cl-dataflow.coverage}
REPORT_DIR=${COVERAGE_REPORT_DIR:-coverage/}
MIN_EXPRESSION=${COVERAGE_MIN_EXPRESSION:-84}
MIN_BRANCH=${COVERAGE_MIN_BRANCH:-100}

if command -v nix >/dev/null 2>&1; then
  exec nix run . -- \
    --coverage \
    --coverage-system cl-dataflow \
    --coverage-min-expression "$MIN_EXPRESSION" \
    --coverage-min-branch "$MIN_BRANCH" \
    --coverage-output "$OUTPUT" \
    --coverage-report-directory "$REPORT_DIR" \
    "$@"
fi

if command -v cl-weave >/dev/null 2>&1; then
  exec cl-weave run cl-dataflow/test \
    --coverage \
    --coverage-system cl-dataflow \
    --coverage-min-expression "$MIN_EXPRESSION" \
    --coverage-min-branch "$MIN_BRANCH" \
    --coverage-output "$OUTPUT" \
    --coverage-report-directory "$REPORT_DIR" \
    "$@"
fi

printf '%s\n' "cl-weave or nix is required but neither was found on PATH." >&2
exit 1
