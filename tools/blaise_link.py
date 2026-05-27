#!/usr/bin/env python3
"""Blaise compile-and-link wrapper that injects the libclang_shim
object file at link time.

Blaise currently has no `{$linklib}` directive, no `--extra-object`
flag, and no env var to slip extra args into its `cc` invocation —
the linker line is hardcoded in compiler/src/main/pascal/Blaise.pas
(see CompileToNativeLLVM). So we sidestep Blaise's link step
entirely:

    1. Run blaise with `--emit-ir` instead of `--output`, capturing
       the LLVM IR to a temp `.ll` file.
    2. Compile the `.ll` to `.o` ourselves via clang.
    3. Run cc to link the .o against the Blaise RTL, libclang_shim,
       libm, and libstdc++ — the same shape Blaise would use, plus
       our shim.

We mirror blaisec.py's argv shape (`--source X --output Y --unit-path D`
etc.) so pasbuild's --compiler flag can point at us directly.
"""

import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_BLAISE = Path('/home/andrew/Programming/GroupProjects/blaise')
BLAISE_BIN  = REPO_BLAISE / 'compiler' / 'bootstrap' / 'blaise_unit_source'
RTL_PATH    = REPO_BLAISE / 'compiler' / 'bootstrap' / 'blaise_rtl_unit_source.a'

UNIT_PATHS  = [
    REPO_BLAISE / 'compiler' / 'src' / 'main' / 'pascal',
    REPO_BLAISE / 'runtime'  / 'src' / 'main' / 'pascal',
    REPO_BLAISE / 'stdlib'   / 'src' / 'main' / 'pascal',
]

REPO_PBG    = Path(__file__).resolve().parent.parent
SHIM_SO     = REPO_PBG / 'src' / 'main' / 'c' / 'libclang_shim.so'


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
    if not SHIM_SO.exists():
        sys.stderr.write(
            f'blaise_link: libclang_shim.so not found at {SHIM_SO}\n'
            '             (run: gcc -shared -fPIC -O2 -I vendor '
            '-o src/main/c/libclang_shim.so src/main/c/libclang_shim.c '
            '-l:libclang-17.so.1)\n')
        return 127

    env = os.environ.copy()
    if RTL_PATH.exists():
        env['BLAISE_RTL'] = str(RTL_PATH)

    extra_unit_paths = []
    for p in UNIT_PATHS:
        if p.is_dir():
            extra_unit_paths += ['--unit-path', str(p)]

    with tempfile.TemporaryDirectory(prefix='blaise_link_') as td:
        ll = Path(td) / 'out.ll'
        obj = Path(td) / 'out.o'

        # 1. Pascal -> LLVM IR, captured from stdout.
        cmd = [str(BLAISE_BIN), '--source', src, '--emit-ir', *rest, *extra_unit_paths]
        with open(ll, 'wb') as f:
            run(cmd, stdout=f, env=env)

        # 2. .ll -> .o
        run(['clang', '-c', '-o', str(obj), str(ll)])

        # 3. .o + RTL + shim + libs -> binary
        link_cmd = [
            'cc', '-o', out,
            '-no-pie',
            str(obj),
            str(RTL_PATH),
            str(SHIM_SO),
            f'-Wl,-rpath,{SHIM_SO.parent}',  # so the binary finds libclang at runtime
            '-lm', '-lstdc++',
        ]
        run(link_cmd)

    return 0


if __name__ == '__main__':
    sys.exit(main())
