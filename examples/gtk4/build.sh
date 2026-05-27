#!/bin/sh
# Build the GTK4 demo. Run from this directory.
set -eu

# Override the 'libgtk-4' name baked into gtk4_fpc.pas externs by
# pre-loading the right SONAMEs via $LINKLIB directives in demo.pas.
# The externs say e.g. "external 'libgtk-4' name 'gtk_window_new'";
# we link libgtk-4.so.1 directly so the dynamic loader resolves
# without needing a 'libgtk-4.so' symlink.

LIBDIR=/usr/lib/x86_64-linux-gnu

fpc -Mobjfpc -O1 -k"-rpath=$LIBDIR" \
    -k"$LIBDIR/libgtk-4.so.1" \
    -k"$LIBDIR/libgio-2.0.so.0" \
    -k"$LIBDIR/libgobject-2.0.so.0" \
    -k"$LIBDIR/libglib-2.0.so.0" \
    demo.pas

echo "built: ./demo  (run it to open a GTK4 window)"
