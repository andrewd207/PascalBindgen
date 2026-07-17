#!/bin/sh
# Build the Blaise ncurses counter demo. Run from this directory.
#
# The binding declares its externs as
#   external 'ncurses' name '<sym>'
# (from `pascal_bindgen --blaise --library ncurses`), so the Blaise
# driver links libncurses and pulls in the RTL automatically — no
# separate clang/cc step, no explicit -l flags.
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

# Debian/Ubuntu ship /usr/lib/<triple>/libncurses.so as a GNU ld script
# (INPUT(libncurses.so.6 ...)), which the runtime loader can't dlopen.
# The binary's NEEDED entry is the bare 'libncurses.so', so point that
# name at the real versioned object via a local dir on the run path.
# (Harmless where libncurses.so is already a proper symlink.)
NC_SO=$(cc -print-file-name=libncurses.so.6 2>/dev/null || echo libncurses.so.6)
mkdir -p .libs
ln -sf "$NC_SO" .libs/libncurses.so

echo "built: ./demo"
echo "run:   LD_LIBRARY_PATH=\$PWD/.libs ./demo   (in a real terminal)"
