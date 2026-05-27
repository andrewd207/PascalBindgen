#!/bin/sh
# Build the Vulkan demo. Run from this directory.
set -eu

LIBDIR=/usr/lib/x86_64-linux-gnu

# The bindings' externs say "external 'libvulkan'"; link the SONAME
# directly so we don't need a libvulkan.so symlink at runtime.
fpc -Mobjfpc -O1 -k"-rpath=$LIBDIR" \
    -k"$LIBDIR/libvulkan.so.1" \
    demo.pas

echo "built: ./demo"
