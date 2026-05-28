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
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, Generics.Collections;

{ Type declarations are ordered strictly linearly — Blaise has no
  `TFoo = class;` forward syntax, so every class must be fully
  declared before any other type references it. }
type
  TSourceLoc = record
    FileName: string;
    Line, Col: Cardinal;
  end;

  { Tag for the type hierarchy. Coarse by design — emitter falls back
    to the spelling for anything it can't recognize. }
  TBindingTypeKind = (
    tkUnknown,
    tkPrimitive,
    tkPointer,
    tkArray,
    tkRecordRef,
    tkEnumRef,
    tkTypedefRef,
    tkFunctionPointer,
    { Marker for C `va_list` / `__builtin_va_list` parameters. The
      emitter renders these as a unit-local `va_list` typedef whose
      layout is target-specific (24-byte struct on x86_64 SysV,
      `Pointer` elsewhere) — that's enough for callers who already
      hold a va_list to pass it through, and avoids dropping
      otherwise-useful APIs (gzvprintf, sqlite3_vmprintf, ...). }
    tkVaList
  );

  TBindingTypeList = class;  { forward — TBindingType references it below }

  TBindingType = class
  private
    FKind: TBindingTypeKind;
    FSpelling: string;
    FPointee: TBindingType;   { self-ref allowed inside own class block }
    FArraySize: Int64;
    FByteSize: Int64;   { for tkPrimitive: bytes from clang_Type_getSizeOf;
                          negative = layout error; 0 = unset }
    FCanonicalSpelling: string;  { for tkTypedefRef: canonical C name }
    FFuncReturn: TBindingType;   { for tkFunctionPointer: return type }
    FFuncParams: TBindingTypeList; { for tkFunctionPointer: parameter types }
  public
    constructor Create(AKind: TBindingTypeKind; const ASpelling: string);
    destructor Destroy; override;
    property Kind: TBindingTypeKind read FKind write FKind;
    property Spelling: string read FSpelling write FSpelling;
    property Pointee: TBindingType read FPointee write FPointee;
    property ArraySize: Int64 read FArraySize write FArraySize;
    property ByteSize: Int64 read FByteSize write FByteSize;
    { Populated for tkFunctionPointer. Owned by this TBindingType. }
    property FuncReturn: TBindingType read FFuncReturn write FFuncReturn;
    property FuncParams: TBindingTypeList read FFuncParams write FFuncParams;
    { Populated for tkTypedefRef: the C spelling of the canonical
      underlying type (e.g. 'unsigned long' for 'size_t'). Empty
      string when the typedef points at a non-primitive (record /
      enum / function-proto). The FPC emitter falls back to this
      when the named typedef itself is filtered out as a system-
      header decl, so the binding still references a known type. }
    property CanonicalSpelling: string
             read FCanonicalSpelling write FCanonicalSpelling;
  end;

  TBindingTypeList = class
  private
    FItems: TList<TBindingType>;
    function GetItem(I: Integer): TBindingType;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingType);
    property Items[I: Integer]: TBindingType read GetItem;
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

  TBindingParamList = class
  private
    FItems: TList<TBindingParam>;
    function GetItem(I: Integer): TBindingParam;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingParam);
    property Items[I: Integer]: TBindingParam read GetItem;
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
    property BitWidth: Integer read FBitWidth write FBitWidth;
  end;

  TBindingFieldList = class
  private
    FItems: TList<TBindingField>;
    function GetItem(I: Integer): TBindingField;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingField);
    property Items[I: Integer]: TBindingField read GetItem;
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

  TBindingEnumConstList = class
  private
    FItems: TList<TBindingEnumConst>;
    function GetItem(I: Integer): TBindingEnumConst;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingEnumConst);
    property Items[I: Integer]: TBindingEnumConst read GetItem;
  end;

  TCallingConv = (ccUnknown, ccCdecl, ccStdcall, ccFastcall);
  TMacroKind   = (mkUnknown, mkInteger, mkString, mkFloat);

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

  TBindingMacroConst = class(TBindingDecl)
  private
    FRawValue: string;
    FMacroKind: TMacroKind;
  public
    constructor Create(const AName: string; const ALocation: TSourceLoc);
    property RawValue: string read FRawValue write FRawValue;
    property MacroKind: TMacroKind read FMacroKind write FMacroKind;
  end;

  TBindingDeclList = class
  private
    FItems: TList<TBindingDecl>;
    function GetItem(I: Integer): TBindingDecl;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    procedure Add(Item: TBindingDecl);
    property Items[I: Integer]: TBindingDecl read GetItem;
  end;

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

(* Owned-list implementations. Storage is Generics.Collections.TList<T>
   in both compilers — FPC uses delphi mode so no `specialize` keyword
   is needed; Blaise rejects `specialize` outright. Each list manually
   frees its items in the destructor since TList<T> doesn't own them.
   Backed by TList<T> rather than `array of T` because Blaise currently
   mis-parses indexed-write to an `array of T` class field — see
   docs/blaise_compat.adoc. *)


constructor TBindingDeclList.Create;
begin
  inherited Create;
  FItems := TList<TBindingDecl>.Create;
end;
destructor TBindingDeclList.Destroy;
var I: Integer; obj: TBindingDecl;
begin
  for I := 0 to FItems.Count - 1 do
  begin
{$IFDEF FPC}    obj := FItems[I];{$ELSE}    obj := FItems.Get(I);{$ENDIF}
    obj.Free;
  end;
  FItems.Free;
  inherited Destroy;
end;
function TBindingDeclList.Count: Integer;
begin
  Result := FItems.Count;
end;
function TBindingDeclList.GetItem(I: Integer): TBindingDecl;
begin
{$IFDEF FPC}  Result := FItems[I];{$ELSE}  Result := FItems.Get(I);{$ENDIF}
end;
procedure TBindingDeclList.Add(Item: TBindingDecl);
begin
  FItems.Add(Item);
end;

constructor TBindingTypeList.Create;
begin
  inherited Create;
  FItems := TList<TBindingType>.Create;
end;
destructor TBindingTypeList.Destroy;
var I: Integer; obj: TBindingType;
begin
  for I := 0 to FItems.Count - 1 do
  begin
{$IFDEF FPC}    obj := FItems[I];{$ELSE}    obj := FItems.Get(I);{$ENDIF}
    obj.Free;
  end;
  FItems.Free;
  inherited Destroy;
end;
function TBindingTypeList.Count: Integer;
begin
  Result := FItems.Count;
end;
function TBindingTypeList.GetItem(I: Integer): TBindingType;
begin
{$IFDEF FPC}  Result := FItems[I];{$ELSE}  Result := FItems.Get(I);{$ENDIF}
end;
procedure TBindingTypeList.Add(Item: TBindingType);
begin
  FItems.Add(Item);
end;

constructor TBindingParamList.Create;
begin
  inherited Create;
  FItems := TList<TBindingParam>.Create;
end;
destructor TBindingParamList.Destroy;
var I: Integer; obj: TBindingParam;
begin
  for I := 0 to FItems.Count - 1 do
  begin
{$IFDEF FPC}    obj := FItems[I];{$ELSE}    obj := FItems.Get(I);{$ENDIF}
    obj.Free;
  end;
  FItems.Free;
  inherited Destroy;
end;
function TBindingParamList.Count: Integer;
begin
  Result := FItems.Count;
end;
function TBindingParamList.GetItem(I: Integer): TBindingParam;
begin
{$IFDEF FPC}  Result := FItems[I];{$ELSE}  Result := FItems.Get(I);{$ENDIF}
end;
procedure TBindingParamList.Add(Item: TBindingParam);
begin
  FItems.Add(Item);
end;

constructor TBindingFieldList.Create;
begin
  inherited Create;
  FItems := TList<TBindingField>.Create;
end;
destructor TBindingFieldList.Destroy;
var I: Integer; obj: TBindingField;
begin
  for I := 0 to FItems.Count - 1 do
  begin
{$IFDEF FPC}    obj := FItems[I];{$ELSE}    obj := FItems.Get(I);{$ENDIF}
    obj.Free;
  end;
  FItems.Free;
  inherited Destroy;
end;
function TBindingFieldList.Count: Integer;
begin
  Result := FItems.Count;
end;
function TBindingFieldList.GetItem(I: Integer): TBindingField;
begin
{$IFDEF FPC}  Result := FItems[I];{$ELSE}  Result := FItems.Get(I);{$ENDIF}
end;
procedure TBindingFieldList.Add(Item: TBindingField);
begin
  FItems.Add(Item);
end;

constructor TBindingEnumConstList.Create;
begin
  inherited Create;
  FItems := TList<TBindingEnumConst>.Create;
end;
destructor TBindingEnumConstList.Destroy;
var I: Integer; obj: TBindingEnumConst;
begin
  for I := 0 to FItems.Count - 1 do
  begin
{$IFDEF FPC}    obj := FItems[I];{$ELSE}    obj := FItems.Get(I);{$ENDIF}
    obj.Free;
  end;
  FItems.Free;
  inherited Destroy;
end;
function TBindingEnumConstList.Count: Integer;
begin
  Result := FItems.Count;
end;
function TBindingEnumConstList.GetItem(I: Integer): TBindingEnumConst;
begin
{$IFDEF FPC}  Result := FItems[I];{$ELSE}  Result := FItems.Get(I);{$ENDIF}
end;
procedure TBindingEnumConstList.Add(Item: TBindingEnumConst);
begin
  FItems.Add(Item);
end;

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
  FFuncReturn.Free;
  FFuncParams.Free;
  inherited Destroy;
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
  inherited Destroy;
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
  inherited Destroy;
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
  inherited Destroy;
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
  inherited Destroy;
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
  inherited Destroy;
end;

{ TBindingTypedef }

constructor TBindingTypedef.Create(const AName: string; const ALocation: TSourceLoc);
begin
  inherited Create(AName, ALocation);
end;

destructor TBindingTypedef.Destroy;
begin
  FAliased.Free;
  inherited Destroy;
end;

{ TBindingMacroConst }

constructor TBindingMacroConst.Create(const AName: string; const ALocation: TSourceLoc);
begin
  inherited Create(AName, ALocation);
end;

{ TBindingUnit }

constructor TBindingUnit.Create;
begin
  inherited Create;
  FHeaderPaths := TStringList.Create;
  FDecls := TBindingDeclList.Create;
end;

destructor TBindingUnit.Destroy;
begin
  FHeaderPaths.Free;
  FDecls.Free;
  inherited Destroy;
end;

procedure TBindingUnit.AddHeader(const Path: string);
begin
  FHeaderPaths.Add(Path);
end;

end.
