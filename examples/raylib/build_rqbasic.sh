#!/bin/sh
# Build the rqbasic raylib spinning-cube demo.
set -eu

RAPIDQ=${RAPIDQ:-/tmp/rapidq}
RQROOT=${RQROOT:-/home/andrew/Programming/GroupProjects/RapidQ-ll}

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/demo_rqbasic"

cp "$HERE/raylib_rqbasic.bas" /tmp/raylib_rqbasic.bas
cp "$HERE/demo_rqbasic.bas"   /tmp/demo_rqbasic_raylib.bas

"$RAPIDQ" \
  --source /tmp/demo_rqbasic_raylib.bas \
  --output "$OUT" \
  --link raylib \
  --unit-path "$RQROOT/rapidq/runtime" \
  --unit-path "$RQROOT/rapidq/stdlib" \
  --unit-path "$RQROOT/Rapidq/include"

echo "built: $OUT"
