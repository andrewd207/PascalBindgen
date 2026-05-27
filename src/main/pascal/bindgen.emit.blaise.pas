(* bindgen.emit.blaise — Blaise-dialect emitter.

  Diverges from the FPC emitter in three ways:

  1. No `{$mode}` / `{$H+}` / `{$PACKRECORDS}` directives, no
     `uses ctypes` — Blaise does not ship those.
  2. Primitive mapping targets Blaise's built-in types (`Integer`,
     `Cardinal`, `Int64`, `AnsiChar`, ...) rather than ctypes
     aliases.
  3. `external` declarations carry only `name '...'`. No `cdecl`,
     no library directive — Blaise hasn't grown that syntax yet, so
     a `--library` value is recorded as a provenance comment instead.

  Shares no code with the FPC emitter yet; mild duplication beats
  premature abstraction while both emitters are still settling.
  Pending v1 cuts mirror the FPC emitter (naming collisions, optional
  TObject class-wrapping, bit-fields, function-pointer synthesis). *)
unit bindgen.emit.blaise;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, bindgen.ir;

type
  TBlaiseEmitter = class
  private
    FUnitName: string;
    FLibrary: string;
    FOutput: TStringList;
    FEmittedTypes: TStringList;
    procedure Line(const S: string = '');
    procedure EmitProvenance(U: TBindingUnit);
    procedure EmitDecl(D: TBindingDecl);
    procedure EmitFunction(F: TBindingFunction);
    procedure EmitRecord(R: TBindingRecord);
    procedure EmitEnum(E: TBindingEnum);
    procedure EmitTypedef(T: TBindingTypedef);
    procedure EmitMacro(M: TBindingMacroConst);
    function  MapType(T: TBindingType): string;
    function  MapPrimitive(const Spelling: string): string;
    function  LocComment(const Loc: TSourceLoc): string;
    function  PascalizeComment(const Raw: string): string;
  public
    constructor Create(const AUnitName, ALibrary: string);
    destructor Destroy; override;
    function Emit(U: TBindingUnit): string;
  end;

implementation

function TBlaiseEmitter.PascalizeComment(const Raw: string): string;
var
  S: string;
begin
  if Trim(Raw) = '' then begin Result := ''; Exit; end;
  S := StringReplace(Raw, '(*', '( *', [rfReplaceAll]);
  S := StringReplace(S, '*)', '* )', [rfReplaceAll]);
  S := StringReplace(S, #123, '[', [rfReplaceAll]);
  S := StringReplace(S, #125, ']', [rfReplaceAll]);
  Result := '(* ' + S + ' *)';
end;

constructor TBlaiseEmitter.Create(const AUnitName, ALibrary: string);
begin
  inherited Create;
  FUnitName := AUnitName;
  FLibrary := ALibrary;
  FOutput := TStringList.Create;
  FEmittedTypes := TStringList.Create;
  FEmittedTypes.Sorted := True;
  FEmittedTypes.Duplicates := dupIgnore;
end;

destructor TBlaiseEmitter.Destroy;
begin
  FOutput.Free;
  FEmittedTypes.Free;
  inherited Destroy;
end;

procedure TBlaiseEmitter.Line(const S: string);
begin
  FOutput.Add(S);
end;

function TBlaiseEmitter.LocComment(const Loc: TSourceLoc): string;
begin
  if Loc.FileName = '' then
    Result := ''
  else
    Result := Format('  { %s:%d }', [ExtractFileName(Loc.FileName), Loc.Line]);
end;

{ C primitive → Blaise built-in type. Width choices target the Blaise
  Linux x86_64 platform (where `long` is 64-bit); when Blaise grows
  cross-target support the mapping for `long`/`unsigned long` may need
  to depend on the target triple. }
function TBlaiseEmitter.MapPrimitive(const Spelling: string): string;
var
  S: string;
begin
  S := Trim(Spelling);
  if Copy(S, 1, 6) = 'const ' then S := Trim(Copy(S, 7, MaxInt));
  if Copy(S, 1, 9) = 'volatile ' then S := Trim(Copy(S, 10, MaxInt));
  if Copy(S, 1, 6) = 'const ' then S := Trim(Copy(S, 7, MaxInt));
  if      S = 'void'                  then Result := ''
  else if S = 'bool'                  then Result := 'Boolean'
  else if S = '_Bool'                 then Result := 'Boolean'
  else if S = 'char'                  then Result := 'AnsiChar'
  else if S = 'signed char'           then Result := 'ShortInt'
  else if S = 'unsigned char'         then Result := 'Byte'
  else if S = 'short'                 then Result := 'SmallInt'
  else if S = 'unsigned short'        then Result := 'Word'
  else if S = 'int'                   then Result := 'Integer'
  else if S = 'unsigned int'          then Result := 'Cardinal'
  else if S = 'unsigned'              then Result := 'Cardinal'
  else if S = 'long'                  then Result := 'Int64'
  else if S = 'unsigned long'         then Result := 'UInt64'
  else if S = 'long long'             then Result := 'Int64'
  else if S = 'unsigned long long'    then Result := 'UInt64'
  else if S = 'float'                 then Result := 'Single'
  else if S = 'double'                then Result := 'Double'
  else if S = 'long double'           then Result := 'Double'  { Blaise lacks 80-bit }
  else Result := S;
end;

function TBlaiseEmitter.MapType(T: TBindingType): string;
var
  Inner, Params, Ret: string;
  J: Integer;
begin
  if T = nil then begin Result := 'Pointer'; Exit; end;
  case T.Kind of
    tkPointer:
      begin
        if T.Pointee = nil then
          Result := 'Pointer'
        else if T.Pointee.Kind = tkFunctionPointer then
          Result := 'Pointer'
        else
        begin
          Inner := MapType(T.Pointee);
          if Inner = 'AnsiChar' then
            Result := 'PChar'  { Blaise spelling }
          else if Inner = '' then
            Result := 'Pointer'
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
        Inner := T.Spelling;
        if Copy(Inner, 1, 6) = 'const ' then Delete(Inner, 1, 6);
        if Copy(Inner, 1, 9) = 'volatile ' then Delete(Inner, 1, 9);
        if      Copy(Inner, 1, 7) = 'struct '  then Delete(Inner, 1, 7)
        else if Copy(Inner, 1, 6) = 'union '   then Delete(Inner, 1, 6)
        else if Copy(Inner, 1, 5) = 'enum '    then Delete(Inner, 1, 5);
        Result := Inner;
      end;
    tkFunctionPointer:
      begin
        Params := '';
        if T.FuncParams <> nil then
          for J := 0 to T.FuncParams.Count - 1 do
          begin
            if Params <> '' then Params := Params + '; ';
            Params := Params + Format('arg%d: %s',
              [J + 1, MapType(T.FuncParams.Items[J])]);
          end;
        if Params <> '' then Params := '(' + Params + ')';
        if T.FuncReturn = nil then Ret := ''
        else Ret := MapType(T.FuncReturn);
        if Ret = '' then
          Result := Format('procedure%s', [Params])
        else
          Result := Format('function%s: %s', [Params, Ret]);
      end;
    tkPrimitive:
      Result := MapPrimitive(T.Spelling);
  else
    Result := MapPrimitive(T.Spelling);
  end;
end;

procedure TBlaiseEmitter.EmitProvenance(U: TBindingUnit);
var
  I: Integer;
begin
  Line('{ DO NOT EDIT — generated by pascal_bindgen (Blaise dialect).');
  for I := 0 to U.HeaderPaths.Count - 1 do
    Line('  source: ' + U.HeaderPaths.Strings[I]);
  if FLibrary <> '' then
    Line('  library: ' + FLibrary + '   -- informational; Blaise resolves externs at link time');
  if U.CommandLine <> '' then
    Line('  command: ' + U.CommandLine);
  if U.ClangVersion <> '' then
    Line('  clang:   ' + U.ClangVersion);
  Line('}');
end;

procedure TBlaiseEmitter.EmitFunction(F: TBindingFunction);
var
  I: Integer;
  Params: string;
  P: TBindingParam;
  RetType, Sig, ParamName, Modifiers: string;
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
  Modifiers := Format('external name ''%s''', [F.Name]);
  if F.IsVarArgs then
    Modifiers := Modifiers +
      '  { varargs — Blaise has no varargs syntax yet, call via wrapper }';

  if RetType = '' then
    Sig := Format('procedure %s%s; %s;', [F.Name, Params, Modifiers])
  else
    Sig := Format('function %s%s: %s; %s;', [F.Name, Params, RetType, Modifiers]);

  Line(Sig + LocComment(F.Location));
end;

procedure TBlaiseEmitter.EmitRecord(R: TBindingRecord);
var
  I: Integer;
  F: TBindingField;
begin
  if R.RawComment <> '' then Line(PascalizeComment(R.RawComment));
  if R.IsUnion then
  begin
    { Blaise has no variant-part records. For v1 we represent a union
      as a record holding only its first alternative — enough to pass
      through FFI by reference, but the other alternatives need a
      hand-written reinterpret cast. Surfaced via a loss comment. }
    Line(Format('  %s = record  { union — using first alternative; size may differ from C } %s',
                [R.Name, LocComment(R.Location)]));
    if R.Fields.Count > 0 then
    begin
      F := R.Fields.Items[0];
      Line(Format('    %s: %s;', [F.Name, MapType(F.FieldType)]));
      for I := 1 to R.Fields.Count - 1 do
        Line(Format('    { alt %d: %s: %s }',
             [I, R.Fields.Items[I].Name, MapType(R.Fields.Items[I].FieldType)]));
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

procedure TBlaiseEmitter.EmitEnum(E: TBindingEnum);
var
  I: Integer;
  Underlying: string;
  C: TBindingEnumConst;
begin
  if E.RawComment <> '' then Line(PascalizeComment(E.RawComment));
  if E.UnderlyingType <> nil then
    Underlying := MapType(E.UnderlyingType)
  else
    Underlying := 'Integer';
  if Underlying = '' then Underlying := 'Integer';
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

procedure TBlaiseEmitter.EmitTypedef(T: TBindingTypedef);
var
  Aliased: string;
begin
  if T.RawComment <> '' then Line(PascalizeComment(T.RawComment));
  Aliased := MapType(T.Aliased);
  if Aliased = '' then Aliased := 'Pointer';
  if Aliased = T.Name then Exit;
  Line(Format('  %s = %s;%s', [T.Name, Aliased, LocComment(T.Location)]));
end;

procedure TBlaiseEmitter.EmitMacro(M: TBindingMacroConst);
begin
  if M.RawComment <> '' then Line(PascalizeComment(M.RawComment));
  Line(Format('  %s = %s;%s', [M.Name, M.RawValue, LocComment(M.Location)]));
end;

procedure TBlaiseEmitter.EmitDecl(D: TBindingDecl);
begin
  if D is TBindingFunction then
  begin
    EmitFunction(TBindingFunction(D));
    Exit;
  end;
  if FEmittedTypes.IndexOf(D.Name) >= 0 then Exit;
  FEmittedTypes.Add(D.Name);
  if      D is TBindingRecord  then EmitRecord(TBindingRecord(D))
  else if D is TBindingEnum    then EmitEnum(TBindingEnum(D))
  else if D is TBindingTypedef then EmitTypedef(TBindingTypedef(D));
end;

function TBlaiseEmitter.Emit(U: TBindingUnit): string;
var
  I: Integer;
  D: TBindingDecl;
  HasTypes, HasFuncs, HasMacros: Boolean;
begin
  FOutput.Clear;
  FEmittedTypes.Clear;
  EmitProvenance(U);
  Line;
  Line(Format('unit %s;', [FUnitName]));
  Line;
  Line('interface');
  Line;

  HasTypes := False;
  HasFuncs := False;
  HasMacros := False;
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if D is TBindingFunction then HasFuncs := True
    else if D is TBindingMacroConst then HasMacros := True
    else HasTypes := True;
  end;

  if HasTypes then
  begin
    Line('type');
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if (not (D is TBindingFunction))
         and (not (D is TBindingMacroConst)) then
        EmitDecl(D);
    end;
    Line;
  end;

  if HasMacros then
  begin
    Line('const');
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if D is TBindingMacroConst then
        EmitMacro(TBindingMacroConst(D));
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
