#!/bin/sh
# Build the rqbasic sqlite demo. Mirrors examples/gtk4/build_rqbasic.sh.
set -eu

RAPIDQ=${RAPIDQ:-/tmp/rapidq}
RQROOT=${RQROOT:-/home/andrew/Programming/GroupProjects/RapidQ-ll}

export BLAISE_RTL="$RQROOT/rapidq/bootstrap/blaise_rtl_unit_source.a"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/demo_rqbasic"

cp "$HERE/sqlite3_rqbasic.bas" /tmp/sqlite3_rqbasic.bas
cp "$HERE/demo_rqbasic.bas"    /tmp/demo_rqbasic_sqlite.bas

"$RAPIDQ" \
  --source /tmp/demo_rqbasic_sqlite.bas \
  --output "$OUT" \
  --link sqlite3 \
  --unit-path "$RQROOT/rapidq/src/main/pascal" \
  --unit-path "$RQROOT/blaise/runtime/src/main/pascal" \
  --unit-path "$RQROOT/blaise/stdlib/src/main/pascal"

echo "built: $OUT"
