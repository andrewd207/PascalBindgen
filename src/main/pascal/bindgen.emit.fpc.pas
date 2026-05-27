{ bindgen.emit.fpc — Free Pascal / Delphi-mode emitter.

  Renders a TBindingUnit to a single .pas source string. Layout:

    {  provenance header
       header source path(s) + clang version
       generator version + DO NOT EDIT  }
    unit <UnitName>;
    {$mode objfpc}{$H+}
    {$PACKRECORDS C}
    interface
    uses ctypes;
    type
      ...records, unions, enums, typedefs...
    const
      ...enum constants flat...
    ...function decls with cdecl; external 'lib'; ...
    implementation
    end.

  Pending (intentional v1 cuts, surfaced via LossReason where needed):
  * Naming-collision detection + renaming
  * Optional TObject class-wrapping per user preference
  * Bit-field width emission
  * Function-pointer typedef synthesis
  * Reserved-word escaping (`&for`, `&end`, ...) }
unit bindgen.emit.fpc;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, bindgen.ir;

type
  TFpcEmitter = class
  private
    FUnitName: string;
    FLibrary: string;
    FOutput: TStringList;
    procedure Line(const S: string = '');
    procedure EmitProvenance(U: TBindingUnit);
    procedure EmitDecl(D: TBindingDecl);
    procedure EmitFunction(F: TBindingFunction);
    procedure EmitRecord(R: TBindingRecord);
    procedure EmitEnum(E: TBindingEnum);
    procedure EmitTypedef(T: TBindingTypedef);
    function  MapType(T: TBindingType): string;
    function  LocComment(const Loc: TSourceLoc): string;
  public
    constructor Create(const AUnitName, ALibrary: string);
    destructor Destroy; override;
    function Emit(U: TBindingUnit): string;
  end;

implementation

constructor TFpcEmitter.Create(const AUnitName, ALibrary: string);
begin
  inherited Create;
  FUnitName := AUnitName;
  FLibrary := ALibrary;
  FOutput := TStringList.Create;
end;

destructor TFpcEmitter.Destroy;
begin
  FOutput.Free;
  inherited;
end;

procedure TFpcEmitter.Line(const S: string);
begin
  FOutput.Add(S);
end;

{ Wrap a raw C comment in Pascal (* *) so FPC accepts it verbatim.
  We keep the original /** ... */ text inside the wrapper so Doxygen
  markup is preserved for any tool that still wants to grep for it. }
function PascalizeComment(const Raw: string): string;
begin
  if Trim(Raw) = '' then Result := ''
  else Result := '(* ' + Raw + ' *)';
end;

function TFpcEmitter.LocComment(const Loc: TSourceLoc): string;
begin
  if Loc.FileName = '' then
    Result := ''
  else
    Result := Format('  { %s:%d }', [ExtractFileName(Loc.FileName), Loc.Line]);
end;

{ C primitive → Pascal mapping. Uses ctypes so widths stay correct on
  every target. Non-primitive kinds fall through to their spelling and
  rely on a matching type already being declared in the unit. }
function MapPrimitive(const Spelling: string): string;
var
  S: string;
begin
  S := Trim(Spelling);
  { Strip 'const ' prefix for the purpose of mapping the underlying
    primitive. Const-qualification is handled at the param level. }
  if Copy(S, 1, 6) = 'const ' then S := Trim(Copy(S, 7, MaxInt));
  if      S = 'void'                  then Result := ''
  else if S = 'bool'                  then Result := 'cbool'
  else if S = '_Bool'                 then Result := 'cbool'
  else if S = 'char'                  then Result := 'cchar'
  else if S = 'signed char'           then Result := 'cschar'
  else if S = 'unsigned char'         then Result := 'cuchar'
  else if S = 'short'                 then Result := 'cshort'
  else if S = 'unsigned short'        then Result := 'cushort'
  else if S = 'int'                   then Result := 'cint'
  else if S = 'unsigned int'          then Result := 'cuint'
  else if S = 'unsigned'              then Result := 'cuint'
  else if S = 'long'                  then Result := 'clong'
  else if S = 'unsigned long'         then Result := 'culong'
  else if S = 'long long'             then Result := 'clonglong'
  else if S = 'unsigned long long'    then Result := 'culonglong'
  else if S = 'float'                 then Result := 'cfloat'
  else if S = 'double'                then Result := 'cdouble'
  else if S = 'long double'           then Result := 'clongdouble'
  else Result := S;  { caller's problem: must be a previously declared type }
end;

function TFpcEmitter.MapType(T: TBindingType): string;
var
  Inner: string;
begin
  if T = nil then begin Result := 'Pointer'; Exit; end;
  case T.Kind of
    tkPointer:
      begin
        if T.Pointee = nil then
          Result := 'Pointer'
        else
        begin
          Inner := MapType(T.Pointee);
          if (Inner = 'cchar') or (Inner = 'cschar') then
            Result := 'PAnsiChar'
          else if Inner = '' then
            Result := 'Pointer'  { void* }
          else
            Result := '^' + Inner;
        end;
      end;
    tkArray:
      begin
        if T.Pointee = nil then
          Result := 'Pointer'
        else if T.ArraySize > 0 then
          Result := Format('array[0..%d] of %s', [T.ArraySize - 1, MapType(T.Pointee)])
        else
          Result := '^' + MapType(T.Pointee);
      end;
    tkRecordRef, tkEnumRef, tkTypedefRef:
      begin
        { Strip 'struct '/'union '/'enum ' prefixes that survive when
          a tag is referenced bare in C. }
        Inner := T.Spelling;
        if Copy(Inner, 1, 7)  = 'struct '  then Delete(Inner, 1, 7)
        else if Copy(Inner, 1, 6) = 'union '  then Delete(Inner, 1, 6)
        else if Copy(Inner, 1, 5) = 'enum '   then Delete(Inner, 1, 5);
        Result := Inner;
      end;
    tkPrimitive:
      Result := MapPrimitive(T.Spelling);
  else
    Result := MapPrimitive(T.Spelling);
  end;
end;

procedure TFpcEmitter.EmitProvenance(U: TBindingUnit);
var
  I: Integer;
begin
  Line('{ DO NOT EDIT — generated by pascal_bindgen.');
  for I := 0 to U.HeaderPaths.Count - 1 do
    Line('  source: ' + U.HeaderPaths[I]);
  if U.CommandLine <> '' then
    Line('  command: ' + U.CommandLine);
  if U.ClangVersion <> '' then
    Line('  clang:   ' + U.ClangVersion);
  Line('}');
end;

procedure TFpcEmitter.EmitFunction(F: TBindingFunction);
var
  I: Integer;
  Params: string;
  P: TBindingParam;
  RetType: string;
  Sig: string;
  Modifiers: string;
  ParamName: string;
begin
  if F.RawComment <> '' then Line(PascalizeComment(F.RawComment));
  Params := '';
  for I := 0 to F.Params.Count - 1 do
  begin
    P := F.Params.Items[I];
    if Params <> '' then Params := Params + '; ';
    ParamName := P.Name;
    if ParamName = '' then ParamName := Format('arg%d', [I + 1]);
    if P.IsConst then
      Params := Params + 'const ' + ParamName + ': ' + MapType(P.ParamType)
    else
      Params := Params + ParamName + ': ' + MapType(P.ParamType);
  end;
  if Params <> '' then Params := '(' + Params + ')';

  RetType := MapType(F.ReturnType);
  Modifiers := 'cdecl';
  if F.IsVarArgs then Modifiers := Modifiers + '; varargs';
  if FLibrary <> '' then
    Modifiers := Modifiers + Format('; external ''%s'' name ''%s''',
                                    [FLibrary, F.Name])
  else
    Modifiers := Modifiers + Format('; external name ''%s''', [F.Name]);

  if RetType = '' then
    Sig := Format('procedure %s%s; %s;', [F.Name, Params, Modifiers])
  else
    Sig := Format('function %s%s: %s; %s;', [F.Name, Params, RetType, Modifiers]);

  Line(Sig + LocComment(F.Location));
end;

procedure TFpcEmitter.EmitRecord(R: TBindingRecord);
var
  I: Integer;
  F: TBindingField;
begin
  if R.RawComment <> '' then Line(PascalizeComment(R.RawComment));
  if R.IsUnion then
  begin
    Line(Format('  %s = record  { union } %s', [R.Name, LocComment(R.Location)]));
    Line('    case Integer of');
    for I := 0 to R.Fields.Count - 1 do
    begin
      F := R.Fields.Items[I];
      Line(Format('      %d: (%s: %s);', [I, F.Name, MapType(F.FieldType)]));
    end;
    Line('  end;');
  end
  else
  begin
    Line(Format('  %s = record%s', [R.Name, LocComment(R.Location)]));
    for I := 0 to R.Fields.Count - 1 do
    begin
      F := R.Fields.Items[I];
      if F.BitWidth >= 0 then
        Line(Format('    %s: %s;  { bit-field: width=%d, best-effort }',
                    [F.Name, MapType(F.FieldType), F.BitWidth]))
      else
        Line(Format('    %s: %s;', [F.Name, MapType(F.FieldType)]));
    end;
    Line('  end;');
  end;
end;

procedure TFpcEmitter.EmitEnum(E: TBindingEnum);
var
  I: Integer;
  Underlying: string;
  C: TBindingEnumConst;
begin
  if E.RawComment <> '' then Line(PascalizeComment(E.RawComment));
  if E.UnderlyingType <> nil then
    Underlying := MapType(E.UnderlyingType)
  else
    Underlying := 'cint';
  if Underlying = '' then Underlying := 'cint';
  Line(Format('  %s = %s;%s', [E.Name, Underlying, LocComment(E.Location)]));
  if E.Constants.Count > 0 then
  begin
    Line('const');
    for I := 0 to E.Constants.Count - 1 do
    begin
      C := E.Constants.Items[I];
      Line(Format('  %s = %d;', [C.Name, C.Value]));
    end;
    Line('type');
  end;
end;

procedure TFpcEmitter.EmitTypedef(T: TBindingTypedef);
var
  Aliased: string;
begin
  if T.RawComment <> '' then Line(PascalizeComment(T.RawComment));
  Aliased := MapType(T.Aliased);
  if Aliased = '' then Aliased := 'Pointer';
  { Skip vacuous self-typedefs: `typedef struct Foo Foo;` produces a
    decl whose spelling is the same as the typedef name. }
  if Aliased = T.Name then Exit;
  Line(Format('  %s = %s;%s', [T.Name, Aliased, LocComment(T.Location)]));
end;

procedure TFpcEmitter.EmitDecl(D: TBindingDecl);
begin
  if D is TBindingFunction then EmitFunction(TBindingFunction(D))
  else if D is TBindingRecord then EmitRecord(TBindingRecord(D))
  else if D is TBindingEnum then EmitEnum(TBindingEnum(D))
  else if D is TBindingTypedef then EmitTypedef(TBindingTypedef(D));
end;

function TFpcEmitter.Emit(U: TBindingUnit): string;
var
  I: Integer;
  D: TBindingDecl;
  HasTypes, HasFuncs: Boolean;
begin
  FOutput.Clear;
  EmitProvenance(U);
  Line;
  Line(Format('unit %s;', [FUnitName]));
  Line;
  Line('{$mode objfpc}{$H+}');
  Line('{$PACKRECORDS C}');
  Line;
  Line('interface');
  Line;
  Line('uses');
  Line('  ctypes;');
  Line;

  HasTypes := False;
  HasFuncs := False;
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if not (D is TBindingFunction) then HasTypes := True
    else HasFuncs := True;
  end;

  if HasTypes then
  begin
    Line('type');
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if not (D is TBindingFunction) then EmitDecl(D);
    end;
    Line;
  end;

  if HasFuncs then
  begin
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if D is TBindingFunction then EmitDecl(D);
    end;
    Line;
  end;

  Line('implementation');
  Line;
  Line('end.');
  Result := FOutput.Text;
end;

end.
