#!/bin/sh
# Build the Blaise GTK4 countdown demo. Run from this directory.
set -eu

BLAISE_REPO=/home/andrew/Programming/GroupProjects/blaise
BLAISE_BIN=$BLAISE_REPO/compiler/bootstrap/blaise_unit_source
BLAISE_RTL=$BLAISE_REPO/compiler/bootstrap/blaise_rtl_unit_source.a
LIBDIR=/usr/lib/x86_64-linux-gnu

if [ ! -x "$BLAISE_BIN" ]; then
  echo "blaise binary not found at $BLAISE_BIN" >&2
  exit 127
fi
if [ ! -f "$BLAISE_RTL" ]; then
  echo "blaise RTL not found at $BLAISE_RTL" >&2
  exit 127
fi

TMPDIR=$(mktemp -d -t blaise_gtk4_XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

LL=$TMPDIR/demo.ll
OBJ=$TMPDIR/demo.o

"$BLAISE_BIN" --source demo.pas --emit-ir \
  --unit-path "$BLAISE_REPO/compiler/src/main/pascal" \
  --unit-path "$BLAISE_REPO/runtime/src/main/pascal" \
  --unit-path "$BLAISE_REPO/stdlib/src/main/pascal" \
  --unit-path . \
  > "$LL"

clang -c -o "$OBJ" "$LL"

cc -o demo -no-pie \
   "$OBJ" \
   "$BLAISE_RTL" \
   "$LIBDIR/libgtk-4.so.1" \
   "$LIBDIR/libgio-2.0.so.0" \
   "$LIBDIR/libgobject-2.0.so.0" \
   "$LIBDIR/libglib-2.0.so.0" \
   "-Wl,-rpath=$LIBDIR" \
   -lm -lstdc++

echo "built: ./demo"
