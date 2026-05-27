{ clang.wrap — Pascal-friendly OO wrappers around the shim FFI. }
unit clang.wrap;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, ctypes, clang.ffi;

type
  EClangError = class(Exception);

  TClangCursor = class;
  TClangCursorArray = array of TClangCursor;

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
    function ResultType: TClangType;    { for function-proto types }
    function NumArgs: Integer;          { -1 if not a function }
    function Arg(I: Integer): TClangType;
    function Declaration: TClangCursor; { decl behind record/enum/typedef ref }
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
    function RawComment: string;
    function TypeOf: TClangType;
    function TypedefUnderlying: TClangType;
    function EnumIntegerType: TClangType;
    function EnumConstantValue: Int64;
    function FieldBitWidth: Integer;
    procedure Location(out FileName: string; out Line, Col: Cardinal);
    function Children: TClangCursorArray;
  end;

  TClangKinds = record
  public
    class function FunctionDecl: Integer; static;
    class function StructDecl: Integer; static;
    class function UnionDecl: Integer; static;
    class function EnumDecl: Integer; static;
    class function EnumConstant: Integer; static;
    class function TypedefDecl: Integer; static;
    class function FieldDecl: Integer; static;
    class function MacroDef: Integer; static;
    class function ParmDecl: Integer; static;
    class function VarDecl: Integer; static;
  end;

  TClangTypeKinds = record
  public
    class function Invalid: Integer; static;
    class function Void: Integer; static;
    class function Bool: Integer; static;
    class function CharS: Integer; static;
    class function CharU: Integer; static;
    class function SChar: Integer; static;
    class function UChar: Integer; static;
    class function Short: Integer; static;
    class function UShort: Integer; static;
    class function Int: Integer; static;
    class function UInt: Integer; static;
    class function Long: Integer; static;
    class function ULong: Integer; static;
    class function LongLong: Integer; static;
    class function ULongLong: Integer; static;
    class function Float: Integer; static;
    class function Double: Integer; static;
    class function LongDouble: Integer; static;
    class function Pointer_: Integer; static;
    class function Record_: Integer; static;
    class function Enum: Integer; static;
    class function Typedef: Integer; static;
    class function ConstantArray: Integer; static;
    class function IncompleteArray: Integer; static;
    class function FunctionProto: Integer; static;
    class function FunctionNoProto: Integer; static;
    class function Elaborated: Integer; static;
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
    constructor Create(ExcludePCH: Boolean = False; DisplayDiag: Boolean = False);
    destructor Destroy; override;
    { Parses a header. ExtraArgs are clang command-line args (e.g. "-Isome/path",
      "-DFOO=1"). Raises EClangError on failure. }
    function Parse(const FileName: string;
                   const ExtraArgs: array of string): TClangTranslationUnit;
  end;

function CStrOrEmpty(P: PChar): string;

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
  inherited;
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
    rc := pbg_parse_tu(FHandle, PChar(FileName), PPCharArray(@argv[0]), n, @tu);
  if rc <> 0 then
    raise EClangError.CreateFmt('parseTranslationUnit failed (CXErrorCode=%d) for "%s"',
                                [rc, FileName]);
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
  inherited;
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
  inherited;
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
begin
  P := nil; Line := 0; Col := 0;
  pbg_cursor_location(FHandle, @P, @Line, @Col);
  FileName := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

function TClangCursor.InMainFile: Boolean;
begin
  Result := pbg_cursor_in_main_file(FHandle) <> 0;
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

{ TClangType }

constructor TClangType.Create(AHandle: PPbgType);
begin
  inherited Create;
  FHandle := AHandle;
end;

destructor TClangType.Destroy;
begin
  if FHandle <> nil then pbg_type_dispose(FHandle);
  inherited;
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

function TClangType.Declaration: TClangCursor;
begin
  Result := TClangCursor.Create(pbg_type_declaration(FHandle));
end;

class function TClangTypeKinds.Invalid: Integer;        begin Result := pbg_typekind_invalid; end;
class function TClangTypeKinds.Void: Integer;           begin Result := pbg_typekind_void; end;
class function TClangTypeKinds.Bool: Integer;           begin Result := pbg_typekind_bool; end;
class function TClangTypeKinds.CharS: Integer;          begin Result := pbg_typekind_char_s; end;
class function TClangTypeKinds.CharU: Integer;          begin Result := pbg_typekind_char_u; end;
class function TClangTypeKinds.SChar: Integer;          begin Result := pbg_typekind_schar; end;
class function TClangTypeKinds.UChar: Integer;          begin Result := pbg_typekind_uchar; end;
class function TClangTypeKinds.Short: Integer;          begin Result := pbg_typekind_short; end;
class function TClangTypeKinds.UShort: Integer;         begin Result := pbg_typekind_ushort; end;
class function TClangTypeKinds.Int: Integer;            begin Result := pbg_typekind_int; end;
class function TClangTypeKinds.UInt: Integer;           begin Result := pbg_typekind_uint; end;
class function TClangTypeKinds.Long: Integer;           begin Result := pbg_typekind_long; end;
class function TClangTypeKinds.ULong: Integer;          begin Result := pbg_typekind_ulong; end;
class function TClangTypeKinds.LongLong: Integer;       begin Result := pbg_typekind_longlong; end;
class function TClangTypeKinds.ULongLong: Integer;      begin Result := pbg_typekind_ulonglong; end;
class function TClangTypeKinds.Float: Integer;          begin Result := pbg_typekind_float; end;
class function TClangTypeKinds.Double: Integer;         begin Result := pbg_typekind_double; end;
class function TClangTypeKinds.LongDouble: Integer;     begin Result := pbg_typekind_longdouble; end;
class function TClangTypeKinds.Pointer_: Integer;       begin Result := pbg_typekind_pointer; end;
class function TClangTypeKinds.Record_: Integer;        begin Result := pbg_typekind_record; end;
class function TClangTypeKinds.Enum: Integer;           begin Result := pbg_typekind_enum; end;
class function TClangTypeKinds.Typedef: Integer;        begin Result := pbg_typekind_typedef; end;
class function TClangTypeKinds.ConstantArray: Integer;  begin Result := pbg_typekind_constantarray; end;
class function TClangTypeKinds.IncompleteArray: Integer;begin Result := pbg_typekind_incompletearray; end;
class function TClangTypeKinds.FunctionProto: Integer;  begin Result := pbg_typekind_functionproto; end;
class function TClangTypeKinds.FunctionNoProto: Integer;begin Result := pbg_typekind_functionnoproto; end;
class function TClangTypeKinds.Elaborated: Integer;     begin Result := pbg_typekind_elaborated; end;

function TClangCursor.RawComment: string;
var
  P: PChar;
begin
  P := pbg_cursor_raw_comment(FHandle);
  Result := CStrOrEmpty(P);
  if P <> nil then pbg_free_string(P);
end;

class function TClangKinds.FunctionDecl: Integer; begin Result := pbg_kind_function_decl; end;
class function TClangKinds.StructDecl:   Integer; begin Result := pbg_kind_struct_decl;   end;
class function TClangKinds.UnionDecl:    Integer; begin Result := pbg_kind_union_decl;    end;
class function TClangKinds.EnumDecl:     Integer; begin Result := pbg_kind_enum_decl;     end;
class function TClangKinds.EnumConstant: Integer; begin Result := pbg_kind_enum_constant; end;
class function TClangKinds.TypedefDecl:  Integer; begin Result := pbg_kind_typedef_decl;  end;
class function TClangKinds.FieldDecl:    Integer; begin Result := pbg_kind_field_decl;    end;
class function TClangKinds.MacroDef:     Integer; begin Result := pbg_kind_macro_def;     end;
class function TClangKinds.ParmDecl:     Integer; begin Result := pbg_kind_parm_decl;     end;
class function TClangKinds.VarDecl:      Integer; begin Result := pbg_kind_var_decl;      end;

function TClangCursor.Children: TClangCursorArray;
var
  L: PPbgCursorList;
  n, i: Integer;
begin
  L := pbg_cursor_children(FHandle);
  n := pbg_children_count(L);
  SetLength(Result, n);
  for i := 0 to n - 1 do
    Result[i] := TClangCursor.Create(pbg_children_get(L, i));
  pbg_children_dispose(L);
end;

end.
