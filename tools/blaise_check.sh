#!/bin/sh
# Smoke-check a Blaise unit by trying to emit LLVM IR.
# Returns 0 on success, nonzero on parse / type errors.
set -eu

BLAISE_REPO=/home/andrew/Programming/GroupProjects/blaise
BLAISE_BIN=$BLAISE_REPO/compiler/bootstrap/blaise_unit_source

if [ ! -x "$BLAISE_BIN" ]; then
  echo "blaise_check: blaise binary not found at $BLAISE_BIN" >&2
  exit 127
fi
if [ $# -lt 1 ]; then
  echo "usage: $0 <file.pas>" >&2
  exit 2
fi

SRC="$1"
shift  # any further args are passed through (e.g. extra --unit-path entries)
exec "$BLAISE_BIN" --source "$SRC" --emit-ir \
  --unit-path "$BLAISE_REPO/compiler/src/main/pascal" \
  --unit-path "$BLAISE_REPO/runtime/src/main/pascal" \
  --unit-path "$BLAISE_REPO/stdlib/src/main/pascal" \
  "$@" \
  > /dev/null
