#!/usr/bin/env sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if command -v nix >/dev/null 2>&1; then
  exec nix run . -- "$@"
fi

if command -v cl-weave >/dev/null 2>&1; then
  exec cl-weave run cl-dataflow/test "$@"
fi

printf '%s\n' "cl-weave or nix is required but neither was found on PATH." >&2
exit 1
