{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

{ clang.ffi — flat Pascal externals matching libclang_shim.c.

  Everything here is a pointer or a scalar; no records by value.
  Use clang.wrap for an ergonomic OO surface. }
unit clang.ffi;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  bindgen.compat;

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
function pbg_index_create(exclude_pch, display_diag: cint): PPbgIndex; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_index_create';
procedure pbg_index_dispose(p: PPbgIndex); {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_index_dispose';

{ translation unit }
function pbg_parse_tu(p: PPbgIndex; filename: PChar; args: PPCharArray; nargs: cint; out_tu: PPbgTUPtr): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_parse_tu';
procedure pbg_tu_dispose(p: PPbgTU); {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_tu_dispose';
function pbg_tu_num_diagnostics(p: PPbgTU): Cardinal; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_tu_num_diagnostics';
function pbg_tu_diagnostic(p: PPbgTU; i: Cardinal): PChar; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_tu_diagnostic';

{ cursor }
function pbg_tu_cursor(p: PPbgTU): PPbgCursor; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_tu_cursor';
procedure pbg_cursor_dispose(p: PPbgCursor); {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_dispose';
function pbg_cursor_kind(p: PPbgCursor): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_kind';
function pbg_cursor_spelling(p: PPbgCursor): PChar; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_spelling';
function pbg_kind_spelling(kind: cint): PChar; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_spelling';
procedure pbg_cursor_location(p: PPbgCursor; out_file: PPChar; out_line, out_col: PCardinal); {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_location';

function pbg_cursor_in_main_file(p: PPbgCursor): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_in_main_file';
function pbg_cursor_in_system_header(p: PPbgCursor): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_in_system_header';
function pbg_cursor_raw_comment(p: PPbgCursor): PChar; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_raw_comment';
function pbg_cursor_macro_body(p: PPbgCursor): PChar; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_macro_body';

{ stable cursor-kind constants (queried at runtime, not hardcoded) }
function pbg_kind_function_decl: cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_function_decl';
function pbg_kind_struct_decl:   cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_struct_decl';
function pbg_kind_union_decl:    cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_union_decl';
function pbg_kind_enum_decl:     cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_enum_decl';
function pbg_kind_enum_constant: cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_enum_constant';
function pbg_kind_typedef_decl:  cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_typedef_decl';
function pbg_kind_field_decl:    cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_field_decl';
function pbg_kind_macro_def:     cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_macro_def';
function pbg_kind_parm_decl:     cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_parm_decl';
function pbg_kind_var_decl:      cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_kind_var_decl';

{ types }
function pbg_cursor_type(p: PPbgCursor): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_type';
function pbg_cursor_typedef_underlying(p: PPbgCursor): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_typedef_underlying';
function pbg_cursor_enum_integer_type(p: PPbgCursor): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_enum_integer_type';
function pbg_cursor_enum_constant_value(p: PPbgCursor): cint64; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_enum_constant_value';
function pbg_cursor_field_bit_width(p: PPbgCursor): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_field_bit_width';

procedure pbg_type_dispose(p: PPbgType); {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_dispose';
function pbg_type_kind(p: PPbgType): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_kind';
function pbg_type_spelling(p: PPbgType): PChar; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_spelling';
function pbg_type_is_const_qualified(p: PPbgType): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_is_const_qualified';
function pbg_type_pointee(p: PPbgType): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_pointee';
function pbg_type_canonical(p: PPbgType): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_canonical';
function pbg_type_array_element(p: PPbgType): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_array_element';
function pbg_type_array_size(p: PPbgType): cint64; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_array_size';
function pbg_type_size_of(p: PPbgType): cint64; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_size_of';
function pbg_type_result(p: PPbgType): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_result';
function pbg_type_num_args(p: PPbgType): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_num_args';
function pbg_type_arg(p: PPbgType; i: cint): PPbgType; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_arg';
function pbg_type_is_variadic(p: PPbgType): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_is_variadic';
function pbg_type_declaration(p: PPbgType): PPbgCursor; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_type_declaration';

{ stable type-kind constants }
function pbg_typekind_invalid:        cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_invalid';
function pbg_typekind_void:           cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_void';
function pbg_typekind_bool:           cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_bool';
function pbg_typekind_char_s:         cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_char_s';
function pbg_typekind_char_u:         cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_char_u';
function pbg_typekind_schar:          cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_schar';
function pbg_typekind_uchar:          cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_uchar';
function pbg_typekind_short:          cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_short';
function pbg_typekind_ushort:         cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_ushort';
function pbg_typekind_int:            cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_int';
function pbg_typekind_uint:           cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_uint';
function pbg_typekind_long:           cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_long';
function pbg_typekind_ulong:          cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_ulong';
function pbg_typekind_longlong:       cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_longlong';
function pbg_typekind_ulonglong:      cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_ulonglong';
function pbg_typekind_float:          cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_float';
function pbg_typekind_double:         cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_double';
function pbg_typekind_longdouble:     cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_longdouble';
function pbg_typekind_pointer:        cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_pointer';
function pbg_typekind_record:         cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_record';
function pbg_typekind_enum:           cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_enum';
function pbg_typekind_typedef:        cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_typedef';
function pbg_typekind_constantarray:  cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_constantarray';
function pbg_typekind_incompletearray:cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_incompletearray';
function pbg_typekind_functionproto:  cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_functionproto';
function pbg_typekind_functionnoproto:cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_functionnoproto';
function pbg_typekind_elaborated:     cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_typekind_elaborated';

{ child enumeration }
function pbg_cursor_children(p: PPbgCursor): PPbgCursorList; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_cursor_children';
function pbg_children_count(L: PPbgCursorList): cint; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_children_count';
function pbg_children_get(L: PPbgCursorList; i: cint): PPbgCursor; {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_children_get';
procedure pbg_children_dispose(L: PPbgCursorList); {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_children_dispose';

{ string release }
procedure pbg_free_string(s: PChar); {$IFDEF FPC}cdecl; {$ENDIF}external name 'pbg_free_string';

implementation

end.
