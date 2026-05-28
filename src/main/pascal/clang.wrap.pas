{ clang.wrap — Pascal-friendly OO wrappers around the shim FFI.

  Dual-build notes (FPC + Blaise)
  --------------------------------
  * Blaise does not parse forward class declarations in any spelling,
    so the class order is hand-arranged: TClangType is declared before
    TClangCursor, and TClangCursor.Declaration (Type -> Cursor) is
    intentionally absent. Cursor -> Type methods stay on TClangCursor
    because TClangType is already known by then.
  * Blaise does not parse `class function` (records with `static;`),
    so the kind-id holders are plain records-with-fields and a
    unit-level `var TClangKinds: TClangKindIds;` shim preserves the
    `TClangKinds.FunctionDecl` syntax at call sites. Initialized in the
    unit's `initialization` section. }
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
    FHandle: PPbgType;
  public
    constructor Create(AHandle: PPbgType);
    destructor Destroy; override;
    function Kind: Integer;
    function Spelling: string;
    function IsConstQualified: Boolean;
    function IsVariadic: Boolean;
    function Pointee: TClangType;       { nil if not a pointer }
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
    FHandle: PPbgCursor;
    FOwned: Boolean;
  public
    constructor Create(AHandle: PPbgCursor; AOwned: Boolean = True);
    destructor Destroy; override;
    function Kind: Integer;
    function KindSpelling: string;
    function Spelling: string;
    function InMainFile: Boolean;
    function InSystemHeader: Boolean;
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
    FHandle: PPbgTU;
  public
    constructor Create(AHandle: PPbgTU);
    destructor Destroy; override;
    function RootCursor: TClangCursor;
    function DiagnosticCount: Cardinal;
    function Diagnostic(I: Cardinal): string;
  end;

  TClangIndex = class
  private
    FHandle: PPbgIndex;
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
  { Field-of-var sugar so call sites read `TClangKinds.FunctionDecl`.
    Populated in the initialization block below. }
  TClangKinds: TClangKindIds;
  TClangTypeKinds: TClangTypeKindIds;

function CStrOrEmpty(P: PChar): string;

{ Cursor -> child-cursors. Lives as a unit-level helper rather than a
  method because Blaise rejects forward class declarations, and a
  method returning TClangCursorArray would require one. }
function CursorChildren(C: TClangCursor): TClangCursorArray;

implementation

function CStrOrEmpty(P: PChar): string;
begin
  if P = nil then Result := '' else Result := string(P);
end;

{ TClangIndex }

constructor TClangIndex.Create(ExcludePCH, DisplayDiag: Boolean);
begin
  inherited Create;
  FHandle := pbg_index_create(Ord(ExcludePCH), Ord(DisplayDiag));
  if FHandle = nil then
    raise EClangError.Create('pbg_index_create failed');
end;

destructor TClangIndex.Destroy;
begin
  if FHandle <> nil then pbg_index_dispose(FHandle);
  inherited Destroy;
end;

function TClangIndex.Parse(const FileName: string;
                           const ExtraArgs: array of string): TClangTranslationUnit;
var
  argv: array of PChar;
  i, n: Integer;
  rc: cint;
  tu: PPbgTU;
begin
  n := Length(ExtraArgs);
  SetLength(argv, n);
  for i := 0 to n - 1 do
    argv[i] := PChar(ExtraArgs[i]);
  tu := nil;
  if n = 0 then
    rc := pbg_parse_tu(FHandle, PChar(FileName), nil, 0, @tu)
  else
    rc := pbg_parse_tu(FHandle, PChar(FileName), PPCharArray(Pointer(argv)), n, @tu);
  if rc <> 0 then
    { Use Format + Create instead of CreateFmt: Blaise's Exception
      has no CreateFmt overload, but Format itself works. }
    raise EClangError.Create(Format(
      'parseTranslationUnit failed (CXErrorCode=%d) for "%s"',
      [rc, FileName]));
  Result := TClangTranslationUnit.Create(tu);
end;

function TClangIndex.ParseNoArgs(const FileName: string): TClangTranslationUnit;
var
  rc: cint;
  tu: PPbgTU;
begin
  tu := nil;
  rc := pbg_parse_tu(FHandle, PChar(FileName), nil, 0, @tu);
  if rc <> 0 then
    raise EClangError.Create(Format(
      'parseTranslationUnit failed (CXErrorCode=%d) for "%s"',
      [rc, FileName]));
  Result := TClangTranslationUnit.Create(tu);
end;

{ TClangTranslationUnit }

constructor TClangTranslationUnit.Create(AHandle: PPbgTU);
begin
  inherited Create;
  FHandle := AHandle;
end;

destructor TClangTranslationUnit.Destroy;
begin
  if FHandle <> nil then pbg_tu_dispose(FHandle);
  inherited Destroy;
end;

function TClangTranslationUnit.RootCursor: TClangCursor;
begin
  Result := TClangCursor.Create(pbg_tu_cursor(FHandle));
end;

function TClangTranslationUnit.DiagnosticCount: Cardinal;
begin
  Result := pbg_tu_num_diagnostics(FHandle);
end;

function TClangTranslationUnit.Diagnostic(I: Cardinal): string;
var
  P: PChar;
begin
  P := pbg_tu_diagnostic(FHandle, I);
  Result := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

{ TClangCursor }

constructor TClangCursor.Create(AHandle: PPbgCursor; AOwned: Boolean);
begin
  inherited Create;
  FHandle := AHandle;
  FOwned := AOwned;
end;

destructor TClangCursor.Destroy;
begin
  if FOwned and (FHandle <> nil) then pbg_cursor_dispose(FHandle);
  inherited Destroy;
end;

function TClangCursor.Kind: Integer;
begin
  Result := pbg_cursor_kind(FHandle);
end;

function TClangCursor.KindSpelling: string;
var
  P: PChar;
begin
  P := pbg_kind_spelling(Kind);
  Result := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

function TClangCursor.Spelling: string;
var
  P: PChar;
begin
  P := pbg_cursor_spelling(FHandle);
  Result := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

procedure TClangCursor.Location(out FileName: string; out Line, Col: Cardinal);
var
  P: PChar;
  L, C: Cardinal;
begin
  { Stage through locals because Blaise's codegen rejects taking the
    address of an out-parameter ("Unsupported L-value form for var
    argument"). }
  P := nil;
  L := 0;
  C := 0;
  pbg_cursor_location(FHandle, @P, @L, @C);
  FileName := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
  Line := L;
  Col := C;
end;

function TClangCursor.InMainFile: Boolean;
begin
  Result := pbg_cursor_in_main_file(FHandle) <> 0;
end;

function TClangCursor.InSystemHeader: Boolean;
begin
  Result := pbg_cursor_in_system_header(FHandle) <> 0;
end;

function TClangCursor.TypeOf: TClangType;
begin
  Result := TClangType.Create(pbg_cursor_type(FHandle));
end;

function TClangCursor.TypedefUnderlying: TClangType;
begin
  Result := TClangType.Create(pbg_cursor_typedef_underlying(FHandle));
end;

function TClangCursor.EnumIntegerType: TClangType;
begin
  Result := TClangType.Create(pbg_cursor_enum_integer_type(FHandle));
end;

function TClangCursor.EnumConstantValue: Int64;
begin
  Result := pbg_cursor_enum_constant_value(FHandle);
end;

function TClangCursor.FieldBitWidth: Integer;
begin
  Result := pbg_cursor_field_bit_width(FHandle);
end;

function TClangCursor.RawComment: string;
var
  P: PChar;
begin
  P := pbg_cursor_raw_comment(FHandle);
  Result := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

function TClangCursor.MacroBody: string;
var
  P: PChar;
begin
  P := pbg_cursor_macro_body(FHandle);
  Result := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

function CursorChildren(C: TClangCursor): TClangCursorArray;
var
  L: PPbgCursorList;
  n, i: Integer;
begin
  L := pbg_cursor_children(C.FHandle);
  n := pbg_children_count(L);
  SetLength(Result, n);
  for i := 0 to n - 1 do
    Result[i] := TClangCursor.Create(pbg_children_get(L, i));
  pbg_children_dispose(L);
end;

{ TClangType }

constructor TClangType.Create(AHandle: PPbgType);
begin
  inherited Create;
  FHandle := AHandle;
end;

destructor TClangType.Destroy;
begin
  if FHandle <> nil then pbg_type_dispose(FHandle);
  inherited Destroy;
end;

function TClangType.Kind: Integer;
begin
  Result := pbg_type_kind(FHandle);
end;

function TClangType.Spelling: string;
var
  P: PChar;
begin
  P := pbg_type_spelling(FHandle);
  Result := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

function TClangType.IsConstQualified: Boolean;
begin
  Result := pbg_type_is_const_qualified(FHandle) <> 0;
end;

function TClangType.IsVariadic: Boolean;
begin
  Result := pbg_type_is_variadic(FHandle) <> 0;
end;

function TClangType.Pointee: TClangType;
begin
  Result := TClangType.Create(pbg_type_pointee(FHandle));
end;

function TClangType.Canonical: TClangType;
begin
  Result := TClangType.Create(pbg_type_canonical(FHandle));
end;

function TClangType.ArrayElement: TClangType;
begin
  Result := TClangType.Create(pbg_type_array_element(FHandle));
end;

function TClangType.ArraySize: Int64;
begin
  Result := pbg_type_array_size(FHandle);
end;

function TClangType.SizeOf: Int64;
begin
  Result := pbg_type_size_of(FHandle);
end;

function TClangType.ResultType: TClangType;
begin
  Result := TClangType.Create(pbg_type_result(FHandle));
end;

function TClangType.NumArgs: Integer;
begin
  Result := pbg_type_num_args(FHandle);
end;

function TClangType.Arg(I: Integer): TClangType;
begin
  Result := TClangType.Create(pbg_type_arg(FHandle, I));
end;

initialization
  TClangKinds.FunctionDecl := pbg_kind_function_decl;
  TClangKinds.StructDecl   := pbg_kind_struct_decl;
  TClangKinds.UnionDecl    := pbg_kind_union_decl;
  TClangKinds.EnumDecl     := pbg_kind_enum_decl;
  TClangKinds.EnumConstant := pbg_kind_enum_constant;
  TClangKinds.TypedefDecl  := pbg_kind_typedef_decl;
  TClangKinds.FieldDecl    := pbg_kind_field_decl;
  TClangKinds.MacroDef     := pbg_kind_macro_def;
  TClangKinds.ParmDecl     := pbg_kind_parm_decl;
  TClangKinds.VarDecl      := pbg_kind_var_decl;

  TClangTypeKinds.Invalid         := pbg_typekind_invalid;
  TClangTypeKinds.Void            := pbg_typekind_void;
  TClangTypeKinds.Bool            := pbg_typekind_bool;
  TClangTypeKinds.CharS           := pbg_typekind_char_s;
  TClangTypeKinds.CharU           := pbg_typekind_char_u;
  TClangTypeKinds.SChar           := pbg_typekind_schar;
  TClangTypeKinds.UChar           := pbg_typekind_uchar;
  TClangTypeKinds.Short           := pbg_typekind_short;
  TClangTypeKinds.UShort          := pbg_typekind_ushort;
  TClangTypeKinds.Int             := pbg_typekind_int;
  TClangTypeKinds.UInt            := pbg_typekind_uint;
  TClangTypeKinds.Long            := pbg_typekind_long;
  TClangTypeKinds.ULong           := pbg_typekind_ulong;
  TClangTypeKinds.LongLong        := pbg_typekind_longlong;
  TClangTypeKinds.ULongLong       := pbg_typekind_ulonglong;
  TClangTypeKinds.Float           := pbg_typekind_float;
  TClangTypeKinds.Double          := pbg_typekind_double;
  TClangTypeKinds.LongDouble      := pbg_typekind_longdouble;
  TClangTypeKinds.Pointer_        := pbg_typekind_pointer;
  TClangTypeKinds.Record_         := pbg_typekind_record;
  TClangTypeKinds.Enum            := pbg_typekind_enum;
  TClangTypeKinds.Typedef         := pbg_typekind_typedef;
  TClangTypeKinds.ConstantArray   := pbg_typekind_constantarray;
  TClangTypeKinds.IncompleteArray := pbg_typekind_incompletearray;
  TClangTypeKinds.FunctionProto   := pbg_typekind_functionproto;
  TClangTypeKinds.FunctionNoProto := pbg_typekind_functionnoproto;
  TClangTypeKinds.Elaborated      := pbg_typekind_elaborated;

end.
