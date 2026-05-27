#!/bin/sh
# Build the Blaise Vulkan demo. Run from this directory.
#
# Mirrors tools/blaise_link.py but links libvulkan instead of
# pascal_bindgen's libclang_shim — Blaise has no $LINKLIB-equivalent
# yet so we drive the link step manually.
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

TMPDIR=$(mktemp -d -t blaise_vk_XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

LL=$TMPDIR/demo.ll
OBJ=$TMPDIR/demo.o

# 1. Pascal -> LLVM IR (stdout).
"$BLAISE_BIN" --source demo.pas --emit-ir \
  --unit-path "$BLAISE_REPO/compiler/src/main/pascal" \
  --unit-path "$BLAISE_REPO/runtime/src/main/pascal" \
  --unit-path "$BLAISE_REPO/stdlib/src/main/pascal" \
  --unit-path . \
  > "$LL"

# 2. .ll -> .o
clang -c -o "$OBJ" "$LL"

# 3. link with RTL + libvulkan
cc -o demo -no-pie \
   "$OBJ" \
   "$BLAISE_RTL" \
   "$LIBDIR/libvulkan.so.1" \
   "-Wl,-rpath=$LIBDIR" \
   -lm -lstdc++

echo "built: ./demo"
