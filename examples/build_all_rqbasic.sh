#!/bin/sh
# build_all_rqbasic.sh — smoke-build every rqbasic example.
#
# Runs each example's build_*.sh and reports pass/fail. Doesn't
# launch any GUI (we just want to know the binary links cleanly).
# Use whenever the rqbasic emitter or the rapidq compiler changes
# to confirm nothing regressed.
#
# Exit code: 0 if every example builds, non-zero with a count
# otherwise.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# Each entry is "dir/script.sh".
TARGETS="
gtk4/build_rqbasic.sh
sqlite/build_rqbasic.sh
opengl/build_rqbasic.sh
raylib/build_rqbasic.sh
raylib/build_pong.sh
sdl2/build_rqbasic.sh
"

pad() { printf '%-32s' "$1"; }

passes=0
fails=0
fail_list=""

for t in $TARGETS; do
  pad "$t"
  log="/tmp/build_$(echo "$t" | tr '/' '_').log"
  if bash "$t" >"$log" 2>&1; then
    echo "ok"
    passes=$((passes + 1))
  else
    echo "FAIL  (see $log)"
    fails=$((fails + 1))
    fail_list="$fail_list $t"
  fi
done

echo
echo "summary: $passes passed, $fails failed"
if [ "$fails" -gt 0 ]; then
  echo "failures:$fail_list"
  exit 1
fi
