#!/bin/sh
set -eu

RAPIDQ=${RAPIDQ:-/tmp/rapidq}
RQROOT=${RQROOT:-/home/andrew/Programming/GroupProjects/RapidQ-ll}

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/demo_rqbasic"

cp "$HERE/sdl2_rqbasic.bas" /tmp/sdl2_rqbasic.bas
cp "$HERE/demo_rqbasic.bas" /tmp/demo_rqbasic_sdl2.bas

"$RAPIDQ" \
  --source /tmp/demo_rqbasic_sdl2.bas \
  --output "$OUT" \
  --link SDL2 \
  --unit-path "$RQROOT/rapidq/runtime" \
  --unit-path "$RQROOT/rapidq/stdlib" \
  --unit-path "$RQROOT/Rapidq/include"

echo "built: $OUT"
