#!/bin/sh
# Build the Blaise Win64 demos (cross-compile via Blaise's lld-link path).
# Run from this directory. Requires:
#   - Blaise compiler at /home/andrew/Programming/GroupProjects/blaise
#     with the Win64 RTL built (compiler/target/blaise_rtl_win64.a)
#   - llvm-mingw at /opt/llvm-mingw for libuser32.a / libgdi32.a
#   - Wine64 prefix at ~/.wine64 for running the resulting .exe
set -eu

BLAISE_REPO=/home/andrew/Programming/GroupProjects/blaise
BLAISE_BIN=$BLAISE_REPO/compiler/target/blaise
BLAISE_TARGET_DIR=$BLAISE_REPO/compiler/target
MINGW_LIBS=/opt/llvm-mingw/x86_64-w64-mingw32/lib

if [ ! -x "$BLAISE_BIN" ]; then
  echo "blaise binary not found at $BLAISE_BIN" >&2
  exit 127
fi

# Blaise's built-in link line hardcodes msvcrt + kernel32 + shell32. The
# form demo needs user32 + gdi32 too. Workaround: merge those import
# archives into libshell32.a (additive, safe to re-run).
if ! /opt/llvm-mingw/bin/llvm-nm "$BLAISE_TARGET_DIR/libshell32.a" 2>/dev/null \
       | grep -q ' T CreateWindowExW$'; then
  echo "merging libuser32.a + libgdi32.a into libshell32.a..."
  cp "$BLAISE_TARGET_DIR/libshell32.a" "$BLAISE_TARGET_DIR/libshell32.a.bak"
  /opt/llvm-mingw/bin/llvm-ar -M <<EOF
create $BLAISE_TARGET_DIR/libshell32_plus.a
addlib $BLAISE_TARGET_DIR/libshell32.a.bak
addlib $MINGW_LIBS/libuser32.a
addlib $MINGW_LIBS/libgdi32.a
save
end
EOF
  mv "$BLAISE_TARGET_DIR/libshell32_plus.a" "$BLAISE_TARGET_DIR/libshell32.a"
fi

build() {
  src=$1
  out=$2
  echo "building $out..."
  "$BLAISE_BIN" --backend llvm --target windows-x86_64 \
                --source "$src" --output "$out" --unit-path .
}

build demo.pas      demo.exe
build form_demo.pas form_demo.exe

echo
echo "Run with:"
echo "  WINEPREFIX=\$HOME/.wine64 wine ./demo.exe"
echo "  WINEPREFIX=\$HOME/.wine64 wine ./form_demo.exe"
