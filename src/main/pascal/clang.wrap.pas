{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

{ clang.wrap — Pascal-friendly OO wrappers around the libclang FFI.

  Holds CXCursor / CXType by value inside each wrapper object; the
  underlying CXTranslationUnit keeps the backing AST alive, so we
  just need to copy the small 16/32-byte handle records into our
  fields.

  Dual-build notes (FPC + Blaise)
  --------------------------------
  * Blaise does not parse forward class declarations in any spelling,
    so the class order is hand-arranged: TClangType is declared before
    TClangCursor.
  * Blaise does not parse `class function` (records with `static;`),
    so kind-id holders are plain records-with-fields, populated in
    the unit's `initialization` section. }
unit clang.wrap;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, bindgen.compat, clang.ffi;

type
  EClangError = class(Exception);

  TClangType = class
  private
    FHandle: CXType;
  public
    constructor Create(const AHandle: CXType);
    function Kind: Integer;
    function Spelling: string;
    function IsConstQualified: Boolean;
    function IsVariadic: Boolean;
    function Pointee: TClangType;       { kind = Invalid if not a pointer }
    function Canonical: TClangType;
    function ArrayElement: TClangType;
    function ArraySize: Int64;          { -1 if not a constant-size array }
    function SizeOf: Int64;             { bytes; negative = CXTypeLayoutError }
    function ResultType: TClangType;    { for function-proto types }
    function NumArgs: Integer;          { -1 if not a function }
    function Arg(I: Integer): TClangType;
  end;

  TClangCursor = class
  private
    FHandle: CXCursor;
  public
    constructor Create(const AHandle: CXCursor);
    function Kind: Integer;
    function KindSpelling: string;
    function Spelling: string;
    function InMainFile: Boolean;
    function InSystemHeader: Boolean;
    { True when this cursor is the record/enum body, not a forward decl. }
    function IsDefinition: Boolean;
    function RawComment: string;
    function MacroBody: string;  { joined by LF; '' for func-like / empty }
    function TypeOf: TClangType;
    function TypedefUnderlying: TClangType;
    function EnumIntegerType: TClangType;
    function EnumConstantValue: Int64;
    function FieldBitWidth: Integer;
    procedure Location(out FileName: string; out Line, Col: Cardinal);
  end;

  TClangCursorArray = array of TClangCursor;

  TClangKindIds = record
    FunctionDecl: Integer;
    StructDecl:   Integer;
    UnionDecl:    Integer;
    EnumDecl:     Integer;
    EnumConstant: Integer;
    TypedefDecl:  Integer;
    FieldDecl:    Integer;
    MacroDef:     Integer;
    ParmDecl:     Integer;
    VarDecl:      Integer;
  end;

  TClangTypeKindIds = record
    Invalid:         Integer;
    Void:            Integer;
    Bool:            Integer;
    CharS:           Integer;
    CharU:           Integer;
    SChar:           Integer;
    UChar:           Integer;
    Short:           Integer;
    UShort:          Integer;
    Int:             Integer;
    UInt:            Integer;
    Long:            Integer;
    ULong:           Integer;
    LongLong:        Integer;
    ULongLong:       Integer;
    Float:           Integer;
    Double:          Integer;
    LongDouble:      Integer;
    Pointer_:        Integer;
    Record_:         Integer;
    Enum:            Integer;
    Typedef:         Integer;
    ConstantArray:   Integer;
    IncompleteArray: Integer;
    FunctionProto:   Integer;
    FunctionNoProto: Integer;
    Elaborated:      Integer;
  end;

  TClangTranslationUnit = class
  private
    FHandle: CXTranslationUnit;
  public
    constructor Create(AHandle: CXTranslationUnit);
    destructor Destroy; override;
    function RootCursor: TClangCursor;
    function DiagnosticCount: Cardinal;
    function Diagnostic(I: Cardinal): string;
  end;

  TClangIndex = class
  private
    FHandle: CXIndex;
  public
    constructor Create(ExcludePCH: Boolean; DisplayDiag: Boolean);
    destructor Destroy; override;
    function Parse(const FileName: string;
                   const ExtraArgs: array of string): TClangTranslationUnit;
    { Convenience: Blaise rejects empty array literals (`[]`) and does
      not support class-method overloads, so the no-args path lives
      under a distinct name. }
    function ParseNoArgs(const FileName: string): TClangTranslationUnit;
  end;

var
  { Field-of-var sugar so call sites read `TClangKinds.FunctionDecl`. }
  TClangKinds: TClangKindIds;
  TClangTypeKinds: TClangTypeKindIds;

{ Cursor -> direct child cursors. Snapshots into an array. Lives as a
  unit-level helper rather than a method because Blaise rejects
  forward class declarations, and a method returning TClangCursorArray
  would require one. }
function CursorChildren(C: TClangCursor): TClangCursorArray;

implementation

{ TClangIndex }

constructor TClangIndex.Create(ExcludePCH, DisplayDiag: Boolean);
begin
  inherited Create;
  FHandle := clang_createIndex(Ord(ExcludePCH), Ord(DisplayDiag));
  if FHandle = nil then
    raise EClangError.Create('clang_createIndex failed');
end;

destructor TClangIndex.Destroy;
begin
  if FHandle <> nil then clang_disposeIndex(FHandle);
  inherited Destroy;
end;

function TClangIndex.Parse(const FileName: string;
                           const ExtraArgs: array of string): TClangTranslationUnit;
const
  ParseFlags = CXTranslationUnit_SkipFunctionBodies or
               CXTranslationUnit_DetailedPreprocessingRecord;
var
  argv: array of PChar;
  i, n: Integer;
  rc: cint;
  tu: CXTranslationUnit;
  argp: PPChar;
begin
  n := Length(ExtraArgs);
  SetLength(argv, n);
  for i := 0 to n - 1 do
    argv[i] := PChar(ExtraArgs[i]);
  tu := nil;
  if n = 0 then
    argp := nil
  else
    argp := PPChar(Pointer(argv));
  rc := clang_parseTranslationUnit2(
    FHandle, PChar(FileName), argp, n, nil, 0, ParseFlags, @tu);
  if rc <> CXError_Success then
    { Use Format + Create instead of CreateFmt for Blaise compatibility
      with older snapshots; harmless on newer ones. }
    raise EClangError.Create(Format(
      'parseTranslationUnit failed (CXErrorCode=%d) for "%s"',
      [rc, FileName]));
  Result := TClangTranslationUnit.Create(tu);
end;

function TClangIndex.ParseNoArgs(const FileName: string): TClangTranslationUnit;
const
  ParseFlags = CXTranslationUnit_SkipFunctionBodies or
               CXTranslationUnit_DetailedPreprocessingRecord;
var
  rc: cint;
  tu: CXTranslationUnit;
begin
  tu := nil;
  rc := clang_parseTranslationUnit2(
    FHandle, PChar(FileName), nil, 0, nil, 0, ParseFlags, @tu);
  if rc <> CXError_Success then
    raise EClangError.Create(Format(
      'parseTranslationUnit failed (CXErrorCode=%d) for "%s"',
      [rc, FileName]));
  Result := TClangTranslationUnit.Create(tu);
end;

{ TClangTranslationUnit }

constructor TClangTranslationUnit.Create(AHandle: CXTranslationUnit);
begin
  inherited Create;
  FHandle := AHandle;
end;

destructor TClangTranslationUnit.Destroy;
begin
  if FHandle <> nil then clang_disposeTranslationUnit(FHandle);
  inherited Destroy;
end;

function TClangTranslationUnit.RootCursor: TClangCursor;
begin
  Result := TClangCursor.Create(clang_getTranslationUnitCursor(FHandle));
end;

function TClangTranslationUnit.DiagnosticCount: Cardinal;
begin
  Result := clang_getNumDiagnostics(FHandle);
end;

function TClangTranslationUnit.Diagnostic(I: Cardinal): string;
var
  d: CXDiagnostic;
begin
  d := clang_getDiagnostic(FHandle, I);
  Result := CXStringToStr(clang_formatDiagnostic(d, clang_defaultDiagnosticDisplayOptions));
  clang_disposeDiagnostic(d);
end;

{ TClangCursor }

constructor TClangCursor.Create(const AHandle: CXCursor);
begin
  inherited Create;
  FHandle := AHandle;
end;

function TClangCursor.Kind: Integer;
begin
  Result := clang_getCursorKind(FHandle);
end;

function TClangCursor.KindSpelling: string;
begin
  Result := CXStringToStr(clang_getCursorKindSpelling(Kind));
end;

function TClangCursor.Spelling: string;
begin
  Result := CXStringToStr(clang_getCursorSpelling(FHandle));
end;

procedure TClangCursor.Location(out FileName: string; out Line, Col: Cardinal);
var
  loc: CXSourceLocation;
  f: CXFile;
  l, c, off: Cardinal;
begin
  { Stage through locals because earlier Blaise codegen rejected
    taking the address of an out-parameter. The newer compiler
    accepts it, but the staged form costs nothing and keeps the
    dual-build clean. }
  l := 0; c := 0; off := 0; f := nil;
  loc := clang_getCursorLocation(FHandle);
  clang_getFileLocation(loc, @f, @l, @c, @off);
  if f <> nil then
    FileName := CXStringToStr(clang_getFileName(f))
  else
    FileName := '';
  Line := l;
  Col := c;
end;

function TClangCursor.InMainFile: Boolean;
begin
  Result := clang_Location_isFromMainFile(clang_getCursorLocation(FHandle)) <> 0;
end;

function TClangCursor.InSystemHeader: Boolean;
begin
  Result := clang_Location_isInSystemHeader(clang_getCursorLocation(FHandle)) <> 0;
end;

function TClangCursor.IsDefinition: Boolean;
begin
  Result := clang_isCursorDefinition(FHandle) <> 0;
end;

function TClangCursor.TypeOf: TClangType;
begin
  Result := TClangType.Create(clang_getCursorType(FHandle));
end;

function TClangCursor.TypedefUnderlying: TClangType;
begin
  Result := TClangType.Create(clang_getTypedefDeclUnderlyingType(FHandle));
end;

function TClangCursor.EnumIntegerType: TClangType;
begin
  Result := TClangType.Create(clang_getEnumDeclIntegerType(FHandle));
end;

function TClangCursor.EnumConstantValue: Int64;
begin
  Result := clang_getEnumConstantDeclValue(FHandle);
end;

function TClangCursor.FieldBitWidth: Integer;
begin
  Result := clang_getFieldDeclBitWidth(FHandle);
end;

function TClangCursor.RawComment: string;
begin
  Result := CXStringToStr(clang_Cursor_getRawCommentText(FHandle));
end;

function TClangCursor.MacroBody: string;
var
  tu: CXTranslationUnit;
  range: CXSourceRange;
  tokens: PCXToken;
  ntok: Cardinal;
  i: Cardinal;
  tok: CXToken;
  spelling: string;
  parts: TStringList;
  ptok: PCXToken;
  offset: PtrUInt;
begin
  Result := '';
  if clang_Cursor_isMacroFunctionLike(FHandle) <> 0 then Exit;
  tu := clang_Cursor_getTranslationUnit(FHandle);
  range := clang_getCursorExtent(FHandle);
  tokens := nil;
  ntok := 0;
  clang_tokenize(tu, range, @tokens, @ntok);
  if ntok <= 1 then
  begin
    if tokens <> nil then clang_disposeTokens(tu, tokens, ntok);
    Exit;
  end;
  parts := TStringList.Create;
  try
    { Skip the first token (the macro name itself). Walk tokens by
      pointer arithmetic on raw bytes to stay portable across Pascal
      dialects — Blaise rejects `[]` indexing on typed pointers, and
      the FPC array-of-T pointer form differs subtly. }
    for i := 1 to ntok - 1 do
    begin
      offset := PtrUInt(i) * SizeOf(CXToken);
      ptok := PCXToken(PtrUInt(tokens) + offset);
      tok := ptok^;
      spelling := CXStringToStr(clang_getTokenSpelling(tu, tok));
      parts.Add(spelling);
    end;
    { Join with LF, matching the shim's behavior. }
    Result := parts.Text;
    { TStringList.Text appends a trailing newline; strip it. }
    if (Result <> '') and (Result[Length(Result)] = #10) then
      SetLength(Result, Length(Result) - 1);
  finally
    parts.Free;
  end;
  clang_disposeTokens(tu, tokens, ntok);
end;

{ TClangType }

constructor TClangType.Create(const AHandle: CXType);
begin
  inherited Create;
  FHandle := AHandle;
end;

function TClangType.Kind: Integer;
begin
  Result := FHandle.kind;
end;

function TClangType.Spelling: string;
begin
  Result := CXStringToStr(clang_getTypeSpelling(FHandle));
end;

function TClangType.IsConstQualified: Boolean;
begin
  Result := clang_isConstQualifiedType(FHandle) <> 0;
end;

function TClangType.IsVariadic: Boolean;
begin
  Result := clang_isFunctionTypeVariadic(FHandle) <> 0;
end;

function TClangType.Pointee: TClangType;
begin
  Result := TClangType.Create(clang_getPointeeType(FHandle));
end;

function TClangType.Canonical: TClangType;
begin
  Result := TClangType.Create(clang_getCanonicalType(FHandle));
end;

function TClangType.ArrayElement: TClangType;
begin
  Result := TClangType.Create(clang_getArrayElementType(FHandle));
end;

function TClangType.ArraySize: Int64;
begin
  Result := clang_getArraySize(FHandle);
end;

function TClangType.SizeOf: Int64;
begin
  Result := clang_Type_getSizeOf(FHandle);
end;

function TClangType.ResultType: TClangType;
begin
  Result := TClangType.Create(clang_getResultType(FHandle));
end;

function TClangType.NumArgs: Integer;
begin
  Result := clang_getNumArgTypes(FHandle);
end;

function TClangType.Arg(I: Integer): TClangType;
begin
  Result := TClangType.Create(clang_getArgType(FHandle, cuint(I)));
end;

{ Child enumeration.

  clang_visitChildren takes a callback receiving CXCursor by value.
  We accumulate raw handles into a dynamic array and let the caller
  wrap them in TClangCursor instances. The CXClientData payload is
  a pointer to a heap-allocated list record so the callback can
  mutate the array. }

type
  TCursorBuf = record
    items: array of CXCursor;
    count: Integer;
  end;
  PCursorBuf = ^TCursorBuf;

function ChildVisitor(cursor, parent: CXCursor; data: CXClientData): cint; cdecl;
var
  buf: PCursorBuf;
begin
  buf := PCursorBuf(data);
  if buf^.count >= Length(buf^.items) then
  begin
    if Length(buf^.items) = 0 then
      SetLength(buf^.items, 16)
    else
      SetLength(buf^.items, Length(buf^.items) * 2);
  end;
  buf^.items[buf^.count] := cursor;
  Inc(buf^.count);
  Result := CXChildVisit_Continue;
end;

function CursorChildren(C: TClangCursor): TClangCursorArray;
var
  buf: TCursorBuf;
  i: Integer;
begin
  buf.count := 0;
  SetLength(buf.items, 0);
  clang_visitChildren(C.FHandle, ChildVisitor, @buf);
  SetLength(Result, buf.count);
  for i := 0 to buf.count - 1 do
    Result[i] := TClangCursor.Create(buf.items[i]);
end;

initialization
  TClangKinds.FunctionDecl := CXCursor_FunctionDecl;
  TClangKinds.StructDecl   := CXCursor_StructDecl;
  TClangKinds.UnionDecl    := CXCursor_UnionDecl;
  TClangKinds.EnumDecl     := CXCursor_EnumDecl;
  TClangKinds.EnumConstant := CXCursor_EnumConstantDecl;
  TClangKinds.TypedefDecl  := CXCursor_TypedefDecl;
  TClangKinds.FieldDecl    := CXCursor_FieldDecl;
  TClangKinds.MacroDef     := CXCursor_MacroDefinition;
  TClangKinds.ParmDecl     := CXCursor_ParmDecl;
  TClangKinds.VarDecl      := CXCursor_VarDecl;

  TClangTypeKinds.Invalid         := CXType_Invalid;
  TClangTypeKinds.Void            := CXType_Void;
  TClangTypeKinds.Bool            := CXType_Bool;
  TClangTypeKinds.CharS           := CXType_Char_S;
  TClangTypeKinds.CharU           := CXType_Char_U;
  TClangTypeKinds.SChar           := CXType_SChar;
  TClangTypeKinds.UChar           := CXType_UChar;
  TClangTypeKinds.Short           := CXType_Short;
  TClangTypeKinds.UShort          := CXType_UShort;
  TClangTypeKinds.Int             := CXType_Int;
  TClangTypeKinds.UInt            := CXType_UInt;
  TClangTypeKinds.Long            := CXType_Long;
  TClangTypeKinds.ULong           := CXType_ULong;
  TClangTypeKinds.LongLong        := CXType_LongLong;
  TClangTypeKinds.ULongLong       := CXType_ULongLong;
  TClangTypeKinds.Float           := CXType_Float;
  TClangTypeKinds.Double          := CXType_Double;
  TClangTypeKinds.LongDouble      := CXType_LongDouble;
  TClangTypeKinds.Pointer_        := CXType_Pointer;
  TClangTypeKinds.Record_         := CXType_Record;
  TClangTypeKinds.Enum            := CXType_Enum;
  TClangTypeKinds.Typedef         := CXType_Typedef;
  TClangTypeKinds.ConstantArray   := CXType_ConstantArray;
  TClangTypeKinds.IncompleteArray := CXType_IncompleteArray;
  TClangTypeKinds.FunctionProto   := CXType_FunctionProto;
  TClangTypeKinds.FunctionNoProto := CXType_FunctionNoProto;
  TClangTypeKinds.Elaborated      := CXType_Elaborated;

end.
