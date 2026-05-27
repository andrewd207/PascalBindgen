#!/bin/sh
# Build the headless OpenGL+EGL demo. Run from this directory.
set -eu

LIBDIR=/usr/lib/x86_64-linux-gnu

fpc -Mobjfpc -O1 -k"-rpath=$LIBDIR" \
    -k"$LIBDIR/libEGL.so.1" \
    -k"$LIBDIR/libGL.so.1" \
    demo.pas

echo "built: ./demo"
