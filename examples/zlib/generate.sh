#!/bin/sh
# Regenerate the zlib bindings from /usr/include/zlib.h.
# Run from the repository root.
set -eu

BIN=./target/pascal_bindgen
HEADER=/usr/include/zlib.h
OUT_DIR=examples/zlib

if [ ! -x "$BIN" ]; then
  echo "no binary at $BIN — run 'pasbuild compile' first" >&2
  exit 1
fi
if [ ! -f "$HEADER" ]; then
  echo "no header at $HEADER — install zlib1g-dev (or equivalent)" >&2
  exit 1
fi

"$BIN" --header "$HEADER" --fpc    --library libz --unit-name zlib \
       --output "$OUT_DIR/zlib_fpc.pas"
"$BIN" --header "$HEADER" --blaise --library libz --unit-name zlib \
       --output "$OUT_DIR/zlib_blaise.pas"

echo "wrote $OUT_DIR/zlib_fpc.pas and $OUT_DIR/zlib_blaise.pas"
