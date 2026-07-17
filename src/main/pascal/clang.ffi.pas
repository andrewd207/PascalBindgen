{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

{ clang.ffi — direct libclang externs.

  libclang exposes CXCursor/CXType/CXString by value across most of
  its API. We declare matching Pascal records and let the compiler's
  SysV-ABI lowering split/recombine them across calls. Used to need
  a C shim (libclang_shim.c) because earlier Blaise didn't lower
  aggregates correctly; the LLVM backend now does. FPC has always
  been fine here.

  Naming follows libclang's C names so call sites read like the C
  reference. Lifetime rules match libclang's: CXString must be freed
  with clang_disposeString; CXIndex/CXTranslationUnit/CXDiagnostic/
  CXToken arrays have their own dispose calls. clang.wrap wraps all
  of this so consumers don't have to think about it. }
unit clang.ffi;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  bindgen.compat;

type
  CXIndex            = Pointer;
  CXTranslationUnit  = Pointer;
  CXDiagnostic       = Pointer;
  CXFile             = Pointer;
  CXClientData       = Pointer;

  PCXTranslationUnit = ^CXTranslationUnit;
  PCXFile            = ^CXFile;
  PCardinal          = ^Cardinal;

  { 16 bytes; SysV INTEGER+INTEGER -> returned in RAX:RDX, passed in
    two integer registers. }
  CXString = record
    data:          Pointer;
    private_flags: Cardinal;
  end;

  { 32 bytes; SysV memory class -> sret on return, by-ref on pass. }
  CXCursor = record
    kind:    cint;
    xdata:   cint;
    data0:   Pointer;
    data1:   Pointer;
    data2:   Pointer;
  end;

  { 16 bytes total: kind(int) + pad(int) + data[2]. The two-pointer
    payload makes it INTEGER+SSE-class-ish in places; libclang treats
    it as a plain by-value aggregate and the SysV classifier puts it
    in MEMORY because the first 8 bytes mix int+ptr. Either way,
    LLVM's aggregate lowering handles it. }
  CXType = record
    kind:  cint;
    pad:   cint;
    data0: Pointer;
    data1: Pointer;
  end;

  CXSourceLocation = record
    ptr_data0: Pointer;
    ptr_data1: Pointer;
    int_data:  Cardinal;
  end;

  CXSourceRange = record
    ptr_data0:           Pointer;
    ptr_data1:           Pointer;
    begin_int_data:      Cardinal;
    end_int_data:        Cardinal;
  end;

  CXToken = record
    int_data: array [0..3] of Cardinal;
    ptr_data: Pointer;
  end;
  PCXToken = ^CXToken;
  PPCXToken = ^PCXToken;

  { CXChildVisitResult. }
const
  CXChildVisit_Break    = 0;
  CXChildVisit_Continue = 1;
  CXChildVisit_Recurse  = 2;

type
  CXCursorVisitor = function (cursor, parent: CXCursor; data: CXClientData): cint; cdecl;

const
  { CXTranslationUnit_Flags subset we need. }
  CXTranslationUnit_SkipFunctionBodies            = $40;
  CXTranslationUnit_DetailedPreprocessingRecord   = $01;

  { CXErrorCode. }
  CXError_Success = 0;

  { CXCursorKind values used by the emitter. Stable across libclang
    versions; lifted from clang-c/Index.h. }
  CXCursor_StructDecl       = 2;
  CXCursor_UnionDecl        = 3;
  CXCursor_EnumDecl         = 5;
  CXCursor_FieldDecl        = 6;
  CXCursor_EnumConstantDecl = 7;
  CXCursor_FunctionDecl     = 8;
  CXCursor_VarDecl          = 9;
  CXCursor_ParmDecl         = 10;
  CXCursor_TypedefDecl      = 20;
  CXCursor_MacroDefinition  = 501;

  { CXTypeKind values. }
  CXType_Invalid         = 0;
  CXType_Void            = 2;
  CXType_Bool            = 3;
  CXType_Char_U          = 4;
  CXType_UChar           = 5;
  CXType_UShort          = 8;
  CXType_UInt            = 9;
  CXType_ULong           = 10;
  CXType_ULongLong       = 11;
  CXType_Char_S          = 13;
  CXType_SChar           = 14;
  CXType_Short           = 16;
  CXType_Int             = 17;
  CXType_Long            = 18;
  CXType_LongLong        = 19;
  CXType_Float           = 21;
  CXType_Double          = 22;
  CXType_LongDouble      = 23;
  CXType_Pointer         = 101;
  CXType_Record          = 105;
  CXType_Enum            = 106;
  CXType_Typedef         = 107;
  CXType_ConstantArray   = 112;
  CXType_IncompleteArray = 114;
  CXType_FunctionNoProto = 110;
  CXType_FunctionProto   = 111;
  CXType_Elaborated      = 119;

{ --- libclang externs --- }

function clang_createIndex(excludeDeclarationsFromPCH, displayDiagnostics: cint): CXIndex;
  cdecl; external name 'clang_createIndex';
procedure clang_disposeIndex(idx: CXIndex);
  cdecl; external name 'clang_disposeIndex';

function clang_parseTranslationUnit2(
    idx: CXIndex; source_filename: PChar;
    command_line_args: PPChar; num_command_line_args: cint;
    unsaved_files: Pointer; num_unsaved_files: cuint;
    options: cuint; out_tu: PCXTranslationUnit): cint;
  cdecl; external name 'clang_parseTranslationUnit2';
procedure clang_disposeTranslationUnit(tu: CXTranslationUnit);
  cdecl; external name 'clang_disposeTranslationUnit';
function clang_getNumDiagnostics(tu: CXTranslationUnit): Cardinal;
  cdecl; external name 'clang_getNumDiagnostics';
function clang_getDiagnostic(tu: CXTranslationUnit; i: Cardinal): CXDiagnostic;
  cdecl; external name 'clang_getDiagnostic';
procedure clang_disposeDiagnostic(d: CXDiagnostic);
  cdecl; external name 'clang_disposeDiagnostic';
function clang_formatDiagnostic(d: CXDiagnostic; options: Cardinal): CXString;
  cdecl; external name 'clang_formatDiagnostic';
function clang_defaultDiagnosticDisplayOptions: Cardinal;
  cdecl; external name 'clang_defaultDiagnosticDisplayOptions';

function clang_getTranslationUnitCursor(tu: CXTranslationUnit): CXCursor;
  cdecl; external name 'clang_getTranslationUnitCursor';
function clang_getCursorKind(c: CXCursor): cint;
  cdecl; external name 'clang_getCursorKind';
function clang_getCursorSpelling(c: CXCursor): CXString;
  cdecl; external name 'clang_getCursorSpelling';
function clang_getCursorKindSpelling(kind: cint): CXString;
  cdecl; external name 'clang_getCursorKindSpelling';
function clang_getCursorLocation(c: CXCursor): CXSourceLocation;
  cdecl; external name 'clang_getCursorLocation';
function clang_getCursorExtent(c: CXCursor): CXSourceRange;
  cdecl; external name 'clang_getCursorExtent';
function clang_Cursor_getRawCommentText(c: CXCursor): CXString;
  cdecl; external name 'clang_Cursor_getRawCommentText';
function clang_Cursor_getTranslationUnit(c: CXCursor): CXTranslationUnit;
  cdecl; external name 'clang_Cursor_getTranslationUnit';
function clang_Cursor_isMacroFunctionLike(c: CXCursor): cuint;
  cdecl; external name 'clang_Cursor_isMacroFunctionLike';
{ Non-zero when c is itself the definition (a struct/union/enum body),
  as opposed to a forward declaration. }
function clang_isCursorDefinition(c: CXCursor): cuint;
  cdecl; external name 'clang_isCursorDefinition';

procedure clang_getFileLocation(loc: CXSourceLocation;
    out_file: PCXFile; out_line, out_column, out_offset: PCardinal);
  cdecl; external name 'clang_getFileLocation';
function clang_Location_isFromMainFile(loc: CXSourceLocation): cint;
  cdecl; external name 'clang_Location_isFromMainFile';
function clang_Location_isInSystemHeader(loc: CXSourceLocation): cint;
  cdecl; external name 'clang_Location_isInSystemHeader';
function clang_getFileName(file_: CXFile): CXString;
  cdecl; external name 'clang_getFileName';

function clang_getCursorType(c: CXCursor): CXType;
  cdecl; external name 'clang_getCursorType';
function clang_getTypedefDeclUnderlyingType(c: CXCursor): CXType;
  cdecl; external name 'clang_getTypedefDeclUnderlyingType';
function clang_getEnumDeclIntegerType(c: CXCursor): CXType;
  cdecl; external name 'clang_getEnumDeclIntegerType';
function clang_getEnumConstantDeclValue(c: CXCursor): cint64;
  cdecl; external name 'clang_getEnumConstantDeclValue';
function clang_getFieldDeclBitWidth(c: CXCursor): cint;
  cdecl; external name 'clang_getFieldDeclBitWidth';

function clang_getTypeSpelling(t: CXType): CXString;
  cdecl; external name 'clang_getTypeSpelling';
function clang_isConstQualifiedType(t: CXType): cuint;
  cdecl; external name 'clang_isConstQualifiedType';
function clang_getPointeeType(t: CXType): CXType;
  cdecl; external name 'clang_getPointeeType';
function clang_getCanonicalType(t: CXType): CXType;
  cdecl; external name 'clang_getCanonicalType';
function clang_getArrayElementType(t: CXType): CXType;
  cdecl; external name 'clang_getArrayElementType';
function clang_getArraySize(t: CXType): cint64;
  cdecl; external name 'clang_getArraySize';
function clang_Type_getSizeOf(t: CXType): cint64;
  cdecl; external name 'clang_Type_getSizeOf';
function clang_getResultType(t: CXType): CXType;
  cdecl; external name 'clang_getResultType';
function clang_getNumArgTypes(t: CXType): cint;
  cdecl; external name 'clang_getNumArgTypes';
function clang_getArgType(t: CXType; i: cuint): CXType;
  cdecl; external name 'clang_getArgType';
function clang_isFunctionTypeVariadic(t: CXType): cuint;
  cdecl; external name 'clang_isFunctionTypeVariadic';
function clang_getTypeDeclaration(t: CXType): CXCursor;
  cdecl; external name 'clang_getTypeDeclaration';

function clang_visitChildren(parent: CXCursor; visitor: CXCursorVisitor; data: CXClientData): cuint;
  cdecl; external name 'clang_visitChildren';

procedure clang_tokenize(tu: CXTranslationUnit; range: CXSourceRange;
    out_tokens: PPCXToken; out_num: PCardinal);
  cdecl; external name 'clang_tokenize';
function clang_getTokenSpelling(tu: CXTranslationUnit; tok: CXToken): CXString;
  cdecl; external name 'clang_getTokenSpelling';
procedure clang_disposeTokens(tu: CXTranslationUnit; tokens: PCXToken; num: cuint);
  cdecl; external name 'clang_disposeTokens';

function clang_getCString(s: CXString): PChar;
  cdecl; external name 'clang_getCString';
procedure clang_disposeString(s: CXString);
  cdecl; external name 'clang_disposeString';

{ --- helpers --- }

{ Snapshot a Pascal string from a CXString, then dispose it. Returns
  '' if the underlying C string is nil. }
function CXStringToStr(s: CXString): string;

implementation

function CXStringToStr(s: CXString): string;
var
  P: PChar;
begin
  P := clang_getCString(s);
  if P = nil then
    Result := ''
  else
    Result := string(P);
  clang_disposeString(s);
end;

end.
