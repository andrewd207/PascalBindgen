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
  PPbgType       = Pointer;

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

{ types }
function  pbg_cursor_type(p: PPbgCursor): PPbgType; cdecl; external 'clang_shim';
function  pbg_cursor_typedef_underlying(p: PPbgCursor): PPbgType; cdecl; external 'clang_shim';
function  pbg_cursor_enum_integer_type(p: PPbgCursor): PPbgType; cdecl; external 'clang_shim';
function  pbg_cursor_enum_constant_value(p: PPbgCursor): cint64; cdecl; external 'clang_shim';
function  pbg_cursor_field_bit_width(p: PPbgCursor): cint; cdecl; external 'clang_shim';

procedure pbg_type_dispose(p: PPbgType); cdecl; external 'clang_shim';
function  pbg_type_kind(p: PPbgType): cint; cdecl; external 'clang_shim';
function  pbg_type_spelling(p: PPbgType): PChar; cdecl; external 'clang_shim';
function  pbg_type_is_const_qualified(p: PPbgType): cint; cdecl; external 'clang_shim';
function  pbg_type_pointee(p: PPbgType): PPbgType; cdecl; external 'clang_shim';
function  pbg_type_canonical(p: PPbgType): PPbgType; cdecl; external 'clang_shim';
function  pbg_type_array_element(p: PPbgType): PPbgType; cdecl; external 'clang_shim';
function  pbg_type_array_size(p: PPbgType): cint64; cdecl; external 'clang_shim';
function  pbg_type_result(p: PPbgType): PPbgType; cdecl; external 'clang_shim';
function  pbg_type_num_args(p: PPbgType): cint; cdecl; external 'clang_shim';
function  pbg_type_arg(p: PPbgType; i: cint): PPbgType; cdecl; external 'clang_shim';
function  pbg_type_is_variadic(p: PPbgType): cint; cdecl; external 'clang_shim';
function  pbg_type_declaration(p: PPbgType): PPbgCursor; cdecl; external 'clang_shim';

{ stable type-kind constants }
function  pbg_typekind_invalid:        cint; cdecl; external 'clang_shim';
function  pbg_typekind_void:           cint; cdecl; external 'clang_shim';
function  pbg_typekind_bool:           cint; cdecl; external 'clang_shim';
function  pbg_typekind_char_s:         cint; cdecl; external 'clang_shim';
function  pbg_typekind_char_u:         cint; cdecl; external 'clang_shim';
function  pbg_typekind_schar:          cint; cdecl; external 'clang_shim';
function  pbg_typekind_uchar:          cint; cdecl; external 'clang_shim';
function  pbg_typekind_short:          cint; cdecl; external 'clang_shim';
function  pbg_typekind_ushort:         cint; cdecl; external 'clang_shim';
function  pbg_typekind_int:            cint; cdecl; external 'clang_shim';
function  pbg_typekind_uint:           cint; cdecl; external 'clang_shim';
function  pbg_typekind_long:           cint; cdecl; external 'clang_shim';
function  pbg_typekind_ulong:          cint; cdecl; external 'clang_shim';
function  pbg_typekind_longlong:       cint; cdecl; external 'clang_shim';
function  pbg_typekind_ulonglong:      cint; cdecl; external 'clang_shim';
function  pbg_typekind_float:          cint; cdecl; external 'clang_shim';
function  pbg_typekind_double:         cint; cdecl; external 'clang_shim';
function  pbg_typekind_longdouble:     cint; cdecl; external 'clang_shim';
function  pbg_typekind_pointer:        cint; cdecl; external 'clang_shim';
function  pbg_typekind_record:         cint; cdecl; external 'clang_shim';
function  pbg_typekind_enum:           cint; cdecl; external 'clang_shim';
function  pbg_typekind_typedef:        cint; cdecl; external 'clang_shim';
function  pbg_typekind_constantarray:  cint; cdecl; external 'clang_shim';
function  pbg_typekind_incompletearray:cint; cdecl; external 'clang_shim';
function  pbg_typekind_functionproto:  cint; cdecl; external 'clang_shim';
function  pbg_typekind_functionnoproto:cint; cdecl; external 'clang_shim';
function  pbg_typekind_elaborated:     cint; cdecl; external 'clang_shim';

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
