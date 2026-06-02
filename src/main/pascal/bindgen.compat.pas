{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

{ bindgen.compat — dual-build helper types.

  Under FPC: re-export the bits of `ctypes` we touch.
  Under Blaise: alias the same names onto Blaise's built-in widths
  (`Integer`/`Int64`/`Cardinal`). `cint` etc. then mean the same thing
  in both compilers so `clang.ffi` doesn't need per-line IFDEFs for
  type names. }
unit bindgen.compat;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

{$IFDEF FPC}
uses
  ctypes;

type
  cint   = ctypes.cint;
  cint64 = ctypes.cint64;
  cuint  = ctypes.cuint;
{$ELSE}
type
  { Blaise: 32-bit signed/unsigned ints, 64-bit signed. Sizes match
    libclang's C ABI on x86_64 (where C `int` is 32-bit). }
  cint   = Integer;
  cint64 = Int64;
  cuint  = Cardinal;
{$ENDIF}

implementation

end.
