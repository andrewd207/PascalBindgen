#!/bin/sh
# Build the rqbasic OpenGL spinning-triangle demo.
set -eu

RAPIDQ=${RAPIDQ:-/tmp/rapidq}
RQROOT=${RQROOT:-/home/andrew/Programming/GroupProjects/RapidQ-ll}

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/demo_rqbasic"

cp "$HERE/gl_rqbasic.bas"   /tmp/gl_rqbasic.bas
cp "$HERE/glut_rqbasic.bas" /tmp/glut_rqbasic.bas
cp "$HERE/demo_rqbasic.bas" /tmp/demo_rqbasic_opengl.bas

"$RAPIDQ" \
  --source /tmp/demo_rqbasic_opengl.bas \
  --output "$OUT" \
  --link GL \
  --unit-path "$RQROOT/rapidq/runtime" \
  --unit-path "$RQROOT/rapidq/src/main/pascal" \
  --unit-path "$RQROOT/blaise/runtime/src/main/pascal" \
  --unit-path "$RQROOT/blaise/stdlib/src/main/pascal"

echo "built: $OUT"
