#!/bin/sh
# Build the rqbasic raylib pong demo.
set -eu

RAPIDQ=${RAPIDQ:-/tmp/rapidq}
RQROOT=${RQROOT:-/home/andrew/Programming/GroupProjects/RapidQ-ll}

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/pong_rqbasic"

cp "$HERE/raylib_rqbasic.bas" /tmp/raylib_rqbasic.bas
cp "$HERE/pong_rqbasic.bas"   /tmp/pong_rqbasic.bas

"$RAPIDQ" \
  --source /tmp/pong_rqbasic.bas \
  --output "$OUT" \
  --link raylib \
  --unit-path "$RQROOT/rapidq/runtime" \
  --unit-path "$RQROOT/rapidq/stdlib" \
  --unit-path "$RQROOT/Rapidq/include"

echo "built: $OUT"
