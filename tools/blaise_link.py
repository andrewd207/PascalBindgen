#!/usr/bin/env python3
"""Blaise compile-and-link wrapper that links libclang directly.

STATUS (2026-06-10): currently broken end-to-end. pascal_bindgen uses
SysUtils, which on the live Blaise tree calls Exit(value); the only
Blaise bootstrap binaries that expose --backend llvm have an older
parser that rejects that form. The current compiler/target/blaise
parses Exit(value) but doesn't expose --backend llvm in its driver.
Until a single Blaise binary covers both, this script can't compile
pascal_bindgen.

The libclang FFI itself (src/main/pascal/clang.ffi.pas) is already
LLVM-backend-ready: by-value CXString/CXCursor/CXType round-trips
were verified on a smaller harness. So when the bootstrap catches
up, the only fix needed here will be pointing BLAISE_BIN at it.

Blaise has no `{$linklib}` directive, no `--extra-object` flag, and
no env var to slip extra args into its `cc` invocation — the linker
line is hardcoded in compiler/src/main/pascal/Blaise.pas. So we
sidestep Blaise's link step entirely:

    1. Run blaise with `--backend llvm --emit-ir`, capturing the
       LLVM IR to a temp `.ll` file.
    2. Compile the `.ll` to `.o` ourselves via clang.
    3. Run cc to link the .o against the Blaise RTL, libclang, libm,
       and libstdc++.

The LLVM backend is required: it's the only Blaise backend that
lowers libclang's by-value CXString / CXCursor / CXType records per
the SysV AMD64 ABI. The QBE backend still emits sret-via-hidden-
pointer on return paths, which mismatches libclang's
return-in-registers calls.

We mirror blaisec.py's argv shape (`--source X --output Y
--unit-path D` etc.) so pasbuild's --compiler flag can point at us
directly.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_BLAISE = Path('/home/andrew/Programming/GroupProjects/blaise')
# The shipping compiler/target/blaise on llvm_current is built without
# --backend llvm exposed. Use the pre-built bootstrap snapshot that
# does, along with its matching RTL .a, so we can generate LLVM IR
# for libclang's by-value record ABI.
BLAISE_BIN  = REPO_BLAISE / 'compiler' / 'bootstrap' / 'blaise_llvm_current.ae2901a'
RTL_PATH    = REPO_BLAISE / 'compiler' / 'bootstrap' / 'blaise_rtl_llvm_current.ae2901a.a'

UNIT_PATHS  = [
    REPO_BLAISE / 'compiler' / 'src' / 'main' / 'pascal',
    REPO_BLAISE / 'runtime'  / 'src' / 'main' / 'pascal',
    REPO_BLAISE / 'stdlib'   / 'src' / 'main' / 'pascal',
]

LIBCLANG    = '-l:libclang-17.so.1'


def parse_argv(argv):
    """Pull --source and --output out; pass everything else through to blaise."""
    src, out = None, None
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--source' and i + 1 < len(argv):
            src = argv[i + 1]; i += 2
        elif a == '--output' and i + 1 < len(argv):
            out = argv[i + 1]; i += 2
        else:
            rest.append(a); i += 1
    return src, out, rest


def run(cmd, **kw):
    p = subprocess.run(cmd, **kw)
    if p.returncode != 0:
        sys.exit(p.returncode)
    return p


def main():
    src, out, rest = parse_argv(sys.argv[1:])
    if not src:
        sys.stderr.write('blaise_link: missing --source\n')
        return 2
    if not out:
        sys.stderr.write('blaise_link: missing --output\n')
        return 2
    if not BLAISE_BIN.exists():
        sys.stderr.write(f'blaise_link: blaise binary not found at {BLAISE_BIN}\n')
        return 127

    extra_unit_paths = []
    for p in UNIT_PATHS:
        if p.is_dir():
            extra_unit_paths += ['--unit-path', str(p)]

    with tempfile.TemporaryDirectory(prefix='blaise_link_') as td:
        ll  = Path(td) / 'out.ll'
        obj = Path(td) / 'out.o'

        # 1. Pascal -> LLVM IR (stdout). The bootstrap snapshot defaults
        #    to --backend llvm, so we don't pass it explicitly (some
        #    builds parse --backend strictly; --emit-ir alone is safe).
        cmd = [str(BLAISE_BIN), '--source', src,
               '--emit-ir', *rest, *extra_unit_paths]
        with open(ll, 'wb') as f:
            run(cmd, stdout=f)

        # 2. .ll -> .o
        run(['clang', '-c', '-o', str(obj), str(ll)])

        # 3. .o + RTL + libclang + libs -> binary
        link_cmd = [
            'cc', '-o', out,
            '-no-pie',
            str(obj),
            str(RTL_PATH),
            LIBCLANG,
            '-lm', '-lstdc++',
        ]
        run(link_cmd)

    return 0


if __name__ == '__main__':
    sys.exit(main())
