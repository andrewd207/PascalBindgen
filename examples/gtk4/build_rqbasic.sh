#!/bin/sh
# Build the rqbasic GTK4 demo. Run from anywhere — paths below
# are absolute so the script doesn't care about cwd.
set -eu

RAPIDQ=${RAPIDQ:-/tmp/rapidq}
RQROOT=${RQROOT:-/home/andrew/Programming/GroupProjects/RapidQ-ll}

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/demo_rqbasic.bas"
OUT="$HERE/demo_rqbasic"

# Stage the generated bindings next to the demo so the $INCLUDE
# resolves regardless of the rapidq cwd.
cp "$HERE/gtk4_rqbasic.bas" /tmp/gtk4_rqbasic.bas
cp "$SRC"                    /tmp/demo_rqbasic.bas

"$RAPIDQ" \
  --source /tmp/demo_rqbasic.bas \
  --output "$OUT" \
  --link gtk-4 --link gobject-2.0 --link glib-2.0 \
  --unit-path "$RQROOT/rapidq/runtime" \
  --unit-path "$RQROOT/rapidq/src/main/pascal" \
  --unit-path "$RQROOT/blaise/runtime/src/main/pascal" \
  --unit-path "$RQROOT/blaise/stdlib/src/main/pascal"

echo "built: $OUT"
