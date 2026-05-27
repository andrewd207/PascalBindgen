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
