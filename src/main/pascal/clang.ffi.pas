{ clang.ffi — flat Pascal externals matching libclang_shim.c.

  Everything here is a pointer or a scalar; no records by value.
  Use clang.wrap for an ergonomic OO surface. }
unit clang.ffi;

{$mode objfpc}{$H+}

interface

uses
  ctypes;

type
  PPbgIndex      = Pointer;
  PPbgTU         = Pointer;
  PPbgCursor     = Pointer;
  PPbgCursorList = Pointer;

  PPbgTUPtr = ^PPbgTU;

  PPCharArray = ^PChar;
  PPChar      = ^PChar;
  PCardinal   = ^Cardinal;

{ index }
function  pbg_index_create(exclude_pch, display_diag: cint): PPbgIndex;
  cdecl; external 'clang_shim';
procedure pbg_index_dispose(p: PPbgIndex);
  cdecl; external 'clang_shim';

{ translation unit }
function  pbg_parse_tu(p: PPbgIndex; filename: PChar;
                       args: PPCharArray; nargs: cint;
                       out_tu: PPbgTUPtr): cint;
  cdecl; external 'clang_shim';
procedure pbg_tu_dispose(p: PPbgTU);
  cdecl; external 'clang_shim';
function  pbg_tu_num_diagnostics(p: PPbgTU): Cardinal;
  cdecl; external 'clang_shim';
function  pbg_tu_diagnostic(p: PPbgTU; i: Cardinal): PChar;
  cdecl; external 'clang_shim';

{ cursor }
function  pbg_tu_cursor(p: PPbgTU): PPbgCursor;
  cdecl; external 'clang_shim';
procedure pbg_cursor_dispose(p: PPbgCursor);
  cdecl; external 'clang_shim';
function  pbg_cursor_kind(p: PPbgCursor): cint;
  cdecl; external 'clang_shim';
function  pbg_cursor_spelling(p: PPbgCursor): PChar;
  cdecl; external 'clang_shim';
function  pbg_kind_spelling(kind: cint): PChar;
  cdecl; external 'clang_shim';
procedure pbg_cursor_location(p: PPbgCursor; out_file: PPChar;
                              out_line, out_col: PCardinal);
  cdecl; external 'clang_shim';

function  pbg_cursor_in_main_file(p: PPbgCursor): cint;
  cdecl; external 'clang_shim';
function  pbg_cursor_raw_comment(p: PPbgCursor): PChar;
  cdecl; external 'clang_shim';

{ stable cursor-kind constants (queried at runtime, not hardcoded) }
function  pbg_kind_function_decl: cint; cdecl; external 'clang_shim';
function  pbg_kind_struct_decl:   cint; cdecl; external 'clang_shim';
function  pbg_kind_union_decl:    cint; cdecl; external 'clang_shim';
function  pbg_kind_enum_decl:     cint; cdecl; external 'clang_shim';
function  pbg_kind_enum_constant: cint; cdecl; external 'clang_shim';
function  pbg_kind_typedef_decl:  cint; cdecl; external 'clang_shim';
function  pbg_kind_field_decl:    cint; cdecl; external 'clang_shim';
function  pbg_kind_macro_def:     cint; cdecl; external 'clang_shim';
function  pbg_kind_parm_decl:     cint; cdecl; external 'clang_shim';
function  pbg_kind_var_decl:      cint; cdecl; external 'clang_shim';

{ child enumeration }
function  pbg_cursor_children(p: PPbgCursor): PPbgCursorList;
  cdecl; external 'clang_shim';
function  pbg_children_count(L: PPbgCursorList): cint;
  cdecl; external 'clang_shim';
function  pbg_children_get(L: PPbgCursorList; i: cint): PPbgCursor;
  cdecl; external 'clang_shim';
procedure pbg_children_dispose(L: PPbgCursorList);
  cdecl; external 'clang_shim';

{ string release }
procedure pbg_free_string(s: PChar);
  cdecl; external 'clang_shim';

implementation

end.
