#!/bin/sh
# Build the round-trip demo. Run from this directory.
set -eu
cd "$(dirname "$0")"
fpc -Mobjfpc -k-lz demo.pas
echo
echo "built ./demo — run it"
