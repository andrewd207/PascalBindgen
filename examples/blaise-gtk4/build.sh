#!/bin/sh
# Build the Blaise GTK4 countdown demo. Run from this directory.
#
# The binding declares its externs as
#   external 'gtk-4' name '<sym>'
# (from `pascal_bindgen --blaise --library gtk-4`), so the Blaise
# driver links libgtk-4 and pulls in the RTL itself — one driver call,
# no separate clang/cc step. The loader brings in gtk's glib/gobject/
# gio dependency closure at load time, which resolves the g_* symbols
# the demo also calls.
#
# Requires a Blaise with `external '<lib>'` link support. Override the
# binary with BLAISE_BIN=/path/to/blaise if yours lives elsewhere.
set -eu

BLAISE_REPO=/home/andrew/Programming/GroupProjects/blaise
BLAISE_BIN=${BLAISE_BIN:-$BLAISE_REPO/compiler/target/blaise}

if [ ! -x "$BLAISE_BIN" ]; then
  echo "blaise binary not found at $BLAISE_BIN" >&2
  exit 127
fi

"$BLAISE_BIN" --source demo.pas --output demo --unit-path .

echo "built: ./demo   (needs a display: ./demo   — or headless: xvfb-run ./demo)"
