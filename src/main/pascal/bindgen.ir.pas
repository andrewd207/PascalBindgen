{ bindgen.ir — dialect-neutral intermediate representation.

  The parser populates these records from a libclang cursor walk; the
  emitter (one per output dialect) consumes them.

  Design constraints
  ------------------
  * No Blaise-isms, no FPC-isms. Both emitters look at the same IR.
  * No C++ shapes baked in; references / overloads / templates do not
    appear here. When C++ support lands it will be modelled by a
    C-shim layer above this IR — see memory/project_cpp_via_shim.md.
  * Source location + raw doc comment + per-decl LossReason live on the
    base class because every comment-emitter rule in docs/comments.adoc
    needs them. }
unit bindgen.ir;

{$IFDEF FPC}
{$mode objfpc}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils;

type
  TSourceLoc = record
    FileName: string;
    Line, Col: Cardinal;
  end;

  TBindingDecl = class;
  TBindingType = class;
  TBindingParam = class;
  TBindingField = class;
  TBindingEnumConst = class;

  { Five purpose-built owned-list classes — hand-rolled because
    Blaise's Generics.Collections lacks TObjectList<T>, and using
    fgl.TFPGObjectList<...>/specialize bakes in an FPC-only spelling.
    The repetition stays cheap and the cross-compiler portability wins. }

  TBindingDeclList = class
  private
    FList: TList;
    function GetItem(I: Integer): TBindingDecl;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingDecl);
    property Items[I: Integer]: TBindingDecl read GetItem; default;
  end;

  TBindingTypeList = class
  private
    FList: TList;
    function GetItem(I: Integer): TBindingType;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingType);
    property Items[I: Integer]: TBindingType read GetItem; default;
  end;

  TBindingParamList = class
  private
    FList: TList;
    function GetItem(I: Integer): TBindingParam;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingParam);
    property Items[I: Integer]: TBindingParam read GetItem; default;
  end;

  TBindingFieldList = class
  private
    FList: TList;
    function GetItem(I: Integer): TBindingField;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingField);
    property Items[I: Integer]: TBindingField read GetItem; default;
  end;

  TBindingEnumConstList = class
  private
    FList: TList;
    function GetItem(I: Integer): TBindingEnumConst;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingEnumConst);
    property Items[I: Integer]: TBindingEnumConst read GetItem; default;
  end;

  { Base for everything emitted. Owns nothing on its own; subclasses may. }
  TBindingDecl = class
  private
    FName: string;
    FLocation: TSourceLoc;
    FRawComment: string;
    FLossReason: string;
  public
    constructor Create(const AName: string; const ALocation: TSourceLoc);
    property Name: string read FName write FName;
    property Location: TSourceLoc read FLocation write FLocation;
    property RawComment: string read FRawComment write FRawComment;
    property LossReason: string read FLossReason write FLossReason;
  end;

  { Tag for the type hierarchy. We keep types deliberately coarse for
    v1 — the parser will set Spelling to clang's pretty-printed C type
    spelling, and the emitter can either map known primitives or fall
    back to emitting a comment with the raw spelling. }
  TBindingTypeKind = (
    tkUnknown,
    tkPrimitive,
    tkPointer,
    tkArray,
    tkRecordRef,
    tkEnumRef,
    tkTypedefRef,
    tkFunctionPointer
  );

  TBindingType = class
  private
    FKind: TBindingTypeKind;
    FSpelling: string;
    FPointee: TBindingType;
    FArraySize: Int64;
  public
    constructor Create(AKind: TBindingTypeKind; const ASpelling: string);
    destructor Destroy; override;
    property Kind: TBindingTypeKind read FKind write FKind;
    { Clang's pretty-printed type spelling, for emitter fallback and
      for source-loc / loss-reason comments. }
    property Spelling: string read FSpelling write FSpelling;
    { Set when Kind is tkPointer or tkArray; owned. nil otherwise. }
    property Pointee: TBindingType read FPointee write FPointee;
    { Set when Kind is tkArray; -1 for unspecified [] arrays. }
    property ArraySize: Int64 read FArraySize write FArraySize;
  end;

  TBindingParam = class
  private
    FName: string;
    FParamType: TBindingType;
    FIsConst: Boolean;
  public
    constructor Create(const AName: string; AParamType: TBindingType; AIsConst: Boolean);
    destructor Destroy; override;
    property Name: string read FName write FName;
    property ParamType: TBindingType read FParamType;
    property IsConst: Boolean read FIsConst write FIsConst;
  end;

  TCallingConv = (ccUnknown, ccCdecl, ccStdcall, ccFastcall);

  TBindingFunction = class(TBindingDecl)
  private
    FReturnType: TBindingType;
    FParams: TBindingParamList;
    FIsVarArgs: Boolean;
    FCallingConv: TCallingConv;
  public
    constructor Create(const AName: string; const ALocation: TSourceLoc);
    destructor Destroy; override;
    property ReturnType: TBindingType read FReturnType write FReturnType;
    property Params: TBindingParamList read FParams;
    property IsVarArgs: Boolean read FIsVarArgs write FIsVarArgs;
    property CallingConv: TCallingConv read FCallingConv write FCallingConv;
  end;

  TBindingField = class
  private
    FName: string;
    FFieldType: TBindingType;
    FBitWidth: Integer;
  public
    constructor Create(const AName: string; AFieldType: TBindingType);
    destructor Destroy; override;
    property Name: string read FName write FName;
    property FieldType: TBindingType read FFieldType;
    { -1 if this field is not a bit-field. }
    property BitWidth: Integer read FBitWidth write FBitWidth;
  end;

  { struct / union — distinguished by IsUnion. }
  TBindingRecord = class(TBindingDecl)
  private
    FFields: TBindingFieldList;
    FIsUnion: Boolean;
    FIsForwardDecl: Boolean;
  public
    constructor Create(const AName: string; const ALocation: TSourceLoc; AIsUnion: Boolean);
    destructor Destroy; override;
    property Fields: TBindingFieldList read FFields;
    property IsUnion: Boolean read FIsUnion;
    property IsForwardDecl: Boolean read FIsForwardDecl write FIsForwardDecl;
  end;

  TBindingEnumConst = class
  private
    FName: string;
    FValue: Int64;
  public
    constructor Create(const AName: string; AValue: Int64);
    property Name: string read FName;
    property Value: Int64 read FValue;
  end;

  TBindingEnum = class(TBindingDecl)
  private
    FConstants: TBindingEnumConstList;
    FUnderlyingType: TBindingType;
  public
    constructor Create(const AName: string; const ALocation: TSourceLoc);
    destructor Destroy; override;
    property Constants: TBindingEnumConstList read FConstants;
    property UnderlyingType: TBindingType read FUnderlyingType write FUnderlyingType;
  end;

  TBindingTypedef = class(TBindingDecl)
  private
    FAliased: TBindingType;
  public
    constructor Create(const AName: string; const ALocation: TSourceLoc);
    destructor Destroy; override;
    property Aliased: TBindingType read FAliased write FAliased;
  end;

  TMacroKind = (mkUnknown, mkInteger, mkString, mkFloat);

  { #define FOO 42  /  #define BAR "x"  /  #define BAZ 3.14
    Function-like macros are skipped with a LossReason. }
  TBindingMacroConst = class(TBindingDecl)
  private
    FRawValue: string;
    FMacroKind: TMacroKind;
  public
    constructor Create(const AName: string; const ALocation: TSourceLoc);
    property RawValue: string read FRawValue write FRawValue;
    property MacroKind: TMacroKind read FMacroKind write FMacroKind;
  end;

  { Top-level container. One instance per --output file. }
  TBindingUnit = class
  private
    FHeaderPaths: TStringList;
    FDecls: TBindingDeclList;
    FCommandLine: string;
    FClangVersion: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddHeader(const Path: string);
    property HeaderPaths: TStringList read FHeaderPaths;
    property Decls: TBindingDeclList read FDecls;
    property CommandLine: string read FCommandLine write FCommandLine;
    property ClangVersion: string read FClangVersion write FClangVersion;
  end;

function MakeLoc(const FileName: string; Line, Col: Cardinal): TSourceLoc;

implementation

{ Owned-list implementations. Each owns its items and frees them on
  destruction. Five near-identical bodies — fewer than the IFDEF
  + TList<T> + manual cleanup alternative would have been. }

constructor TBindingDeclList.Create;
begin inherited Create; FList := TList.Create; end;
destructor TBindingDeclList.Destroy;
var I: Integer;
begin
  for I := 0 to FList.Count - 1 do TObject(FList[I]).Free;
  FList.Free;
  inherited;
end;
function TBindingDeclList.Count: Integer; begin Result := FList.Count; end;
function TBindingDeclList.GetItem(I: Integer): TBindingDecl;
begin Result := TBindingDecl(FList[I]); end;
procedure TBindingDeclList.Add(Item: TBindingDecl); begin FList.Add(Item); end;

constructor TBindingTypeList.Create;
begin inherited Create; FList := TList.Create; end;
destructor TBindingTypeList.Destroy;
var I: Integer;
begin
  for I := 0 to FList.Count - 1 do TObject(FList[I]).Free;
  FList.Free;
  inherited;
end;
function TBindingTypeList.Count: Integer; begin Result := FList.Count; end;
function TBindingTypeList.GetItem(I: Integer): TBindingType;
begin Result := TBindingType(FList[I]); end;
procedure TBindingTypeList.Add(Item: TBindingType); begin FList.Add(Item); end;

constructor TBindingParamList.Create;
begin inherited Create; FList := TList.Create; end;
destructor TBindingParamList.Destroy;
var I: Integer;
begin
  for I := 0 to FList.Count - 1 do TObject(FList[I]).Free;
  FList.Free;
  inherited;
end;
function TBindingParamList.Count: Integer; begin Result := FList.Count; end;
function TBindingParamList.GetItem(I: Integer): TBindingParam;
begin Result := TBindingParam(FList[I]); end;
procedure TBindingParamList.Add(Item: TBindingParam); begin FList.Add(Item); end;

constructor TBindingFieldList.Create;
begin inherited Create; FList := TList.Create; end;
destructor TBindingFieldList.Destroy;
var I: Integer;
begin
  for I := 0 to FList.Count - 1 do TObject(FList[I]).Free;
  FList.Free;
  inherited;
end;
function TBindingFieldList.Count: Integer; begin Result := FList.Count; end;
function TBindingFieldList.GetItem(I: Integer): TBindingField;
begin Result := TBindingField(FList[I]); end;
procedure TBindingFieldList.Add(Item: TBindingField); begin FList.Add(Item); end;

constructor TBindingEnumConstList.Create;
begin inherited Create; FList := TList.Create; end;
destructor TBindingEnumConstList.Destroy;
var I: Integer;
begin
  for I := 0 to FList.Count - 1 do TObject(FList[I]).Free;
  FList.Free;
  inherited;
end;
function TBindingEnumConstList.Count: Integer; begin Result := FList.Count; end;
function TBindingEnumConstList.GetItem(I: Integer): TBindingEnumConst;
begin Result := TBindingEnumConst(FList[I]); end;
procedure TBindingEnumConstList.Add(Item: TBindingEnumConst); begin FList.Add(Item); end;

function MakeLoc(const FileName: string; Line, Col: Cardinal): TSourceLoc;
begin
  Result.FileName := FileName;
  Result.Line := Line;
  Result.Col := Col;
end;

{ TBindingDecl }

constructor TBindingDecl.Create(const AName: string; const ALocation: TSourceLoc);
begin
  inherited Create;
  FName := AName;
  FLocation := ALocation;
end;

{ TBindingType }

constructor TBindingType.Create(AKind: TBindingTypeKind; const ASpelling: string);
begin
  inherited Create;
  FKind := AKind;
  FSpelling := ASpelling;
  FArraySize := -1;
end;

destructor TBindingType.Destroy;
begin
  FPointee.Free;
  inherited;
end;

{ TBindingParam }

constructor TBindingParam.Create(const AName: string; AParamType: TBindingType; AIsConst: Boolean);
begin
  inherited Create;
  FName := AName;
  FParamType := AParamType;
  FIsConst := AIsConst;
end;

destructor TBindingParam.Destroy;
begin
  FParamType.Free;
  inherited;
end;

{ TBindingFunction }

constructor TBindingFunction.Create(const AName: string; const ALocation: TSourceLoc);
begin
  inherited Create(AName, ALocation);
  FParams := TBindingParamList.Create;
end;

destructor TBindingFunction.Destroy;
begin
  FReturnType.Free;
  FParams.Free;
  inherited;
end;

{ TBindingField }

constructor TBindingField.Create(const AName: string; AFieldType: TBindingType);
begin
  inherited Create;
  FName := AName;
  FFieldType := AFieldType;
  FBitWidth := -1;
end;

destructor TBindingField.Destroy;
begin
  FFieldType.Free;
  inherited;
end;

{ TBindingRecord }

constructor TBindingRecord.Create(const AName: string; const ALocation: TSourceLoc; AIsUnion: Boolean);
begin
  inherited Create(AName, ALocation);
  FFields := TBindingFieldList.Create;
  FIsUnion := AIsUnion;
end;

destructor TBindingRecord.Destroy;
begin
  FFields.Free;
  inherited;
end;

{ TBindingEnumConst }

constructor TBindingEnumConst.Create(const AName: string; AValue: Int64);
begin
  inherited Create;
  FName := AName;
  FValue := AValue;
end;

{ TBindingEnum }

constructor TBindingEnum.Create(const AName: string; const ALocation: TSourceLoc);
begin
  inherited Create(AName, ALocation);
  FConstants := TBindingEnumConstList.Create;
end;

destructor TBindingEnum.Destroy;
begin
  FConstants.Free;
  FUnderlyingType.Free;
  inherited;
end;

{ TBindingTypedef }

constructor TBindingTypedef.Create(const AName: string; const ALocation: TSourceLoc);
begin
  inherited Create(AName, ALocation);
end;

destructor TBindingTypedef.Destroy;
begin
  FAliased.Free;
  inherited;
end;

{ TBindingMacroConst }

constructor TBindingMacroConst.Create(const AName: string; const ALocation: TSourceLoc);
begin
  inherited Create(AName, ALocation);
end;

{ TBindingUnit }

constructor TBindingUnit.Create;
begin
  inherited;
  FHeaderPaths := TStringList.Create;
  FDecls := TBindingDeclList.Create;
end;

destructor TBindingUnit.Destroy;
begin
  FHeaderPaths.Free;
  FDecls.Free;
  inherited;
end;

procedure TBindingUnit.AddHeader(const Path: string);
begin
  FHeaderPaths.Add(Path);
end;

end.
