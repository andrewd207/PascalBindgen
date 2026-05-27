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

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl;

type
  TSourceLoc = record
    FileName: string;
    Line, Col: Cardinal;
  end;

  TBindingDecl = class;
  TBindingType = class;

  TBindingDeclList = specialize TFPGObjectList<TBindingDecl>;
  TBindingTypeList = specialize TFPGObjectList<TBindingType>;

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

  TBindingParamList = specialize TFPGObjectList<TBindingParam>;

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

  TBindingFieldList = specialize TFPGObjectList<TBindingField>;

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

  TBindingEnumConstList = specialize TFPGObjectList<TBindingEnumConst>;

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
  FParams := TBindingParamList.Create(True);
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
  FFields := TBindingFieldList.Create(True);
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
  FConstants := TBindingEnumConstList.Create(True);
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
  FDecls := TBindingDeclList.Create(True);
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
