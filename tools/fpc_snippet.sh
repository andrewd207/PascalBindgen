#!/bin/sh
# Compile a Pascal snippet with FPC for ad-hoc dialect / syntax probes.
#
#   tools/fpc_snippet.sh foo.pas               # default: -Cn (no link)
#   tools/fpc_snippet.sh foo.pas --link        # link too (drop -Cn)
#   tools/fpc_snippet.sh foo.pas --link -lz    # link with extra libs
#
# Output goes to the system tempdir so it does not litter the tree.
set -eu

if [ $# -lt 1 ]; then
  echo "usage: $0 <source.pas> [--link] [extra fpc args...]" >&2
  exit 2
fi
src="$1"
shift
flags="-Cn -Mobjfpc -vbq -O-"
out_dir="$(mktemp -d)"
trap 'rm -rf "$out_dir"' EXIT
if [ "${1:-}" = "--link" ]; then
  shift
  flags="-Mobjfpc -vbq -O-"
fi
fpc $flags -FE"$out_dir" "$@" "$src"
