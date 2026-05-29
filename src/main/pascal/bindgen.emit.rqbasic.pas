(* bindgen.emit.rqbasic — RapidQ BASIC emitter.

  Output target: RapidQ-ll (rqbasic). Surface differences vs the
  Pascal emitters:

  1. No `unit`/`interface`/`implementation` wrapping; rqbasic source
     is a flat sequence of TYPE blocks, CONSTs and DECLAREs.
  2. Comments are single-line `'...`. Block comments not available.
  3. Functions are `DECLARE FUNCTION name LIB "lib" ALIAS "csym"
     (param AS T, ...) AS RT`; SUBs are the void-return form.
  4. Records are `TYPE Name ... END TYPE`; fields are `name AS T`.
     No nested records-in-record beyond a named TYPE reference.
  5. Typed pointer aliases use the rqbasic single-line form
     `TYPE PFoo AS Foo Ptr` (no END TYPE). Aliases are collected
     during a prepass and emitted up front; rqbasic treats an
     undeclared pointee as a forward declaration, so ordering
     doesn't matter. `void*` and `char*` stay as bare POINTER —
     callers cast char strings via `PCHAR(...)` at the use site.
     Function-pointer params also collapse to POINTER (no typed
     procedural form in rqbasic yet). All P-aliases are
     assignment-compatible with POINTER, mirroring how GObject
     polymorphism works at the C ABI level.
  6. Constants emit one per line as `CONST NAME = VALUE` — no
     grouped CONST block in this dialect.
  7. Reserved-word collisions resolve to a `_` suffix.
  8. C calling convention is set globally with `$CALLING CDECL`;
     LIB-tagged DECLAREs override per call when needed for stdcall
     (Win32). We pick CDECL by default; user can switch later. *)
unit bindgen.emit.rqbasic;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, bindgen.ir, bindgen.parser;

type
  TRqBasicEmitter = class
  private
    FUnitName: string;
    FLibrary: string;
    FOutput: TStringList;
    FEmittedTypes: TStringList;
    FDeclaredTypeNames: TStringList;
    { name=replacement — when a field/param type references a name
      that we never emit as a TYPE (typedef aliases, enum typedefs),
      MapType substitutes the recorded replacement. }
    FTypedefAliases: TStringList;
    { Set of pointee names that need a `TYPE P<X> AS X Ptr` alias
      emitted up front. Populated as a side effect of MapType /
      AliasPointer during the prepass and main emit pass. }
    FPointerAliases: TStringList;
    function  AliasPointer(const Pointee: string): string;
    procedure WalkTypeForAliases(T: TBindingType);
    procedure CollectPointerAliases(U: TBindingUnit);
    procedure Line(const S: string = '');
    procedure EmitProvenance(U: TBindingUnit);
    procedure EmitDecl(D: TBindingDecl);
    procedure EmitFunction(F: TBindingFunction);
    procedure EmitRecord(R: TBindingRecord);
    procedure EmitEnum(E: TBindingEnum);
    procedure EmitTypedef(T: TBindingTypedef);
    procedure EmitMacro(M: TBindingMacroConst);
    function  MapType(T: TBindingType): string;
    function  MapTypeForSig(T: TBindingType): string;
    function  MapPrimitive(const Spelling: string; SizeBytes: Int64 = 0): string;
    function  EscapeIdent(const S: string): string;
    function  DisambiguateIdent(const CName: string): string;
    function  RawComment(const Raw: string): string;
    function  LibClause: string;
  public
    constructor Create(const AUnitName, ALibrary: string);
    destructor Destroy; override;
    function Emit(U: TBindingUnit): string;
  end;

implementation

{ Loose superset of rqbasic reserved tokens — collisions just get a
  '_' suffix, so over-listing is harmless. }
const
  RQBASIC_RESERVED: array[0..92] of string = (
    'alias','and','as','base','bind','byref','byval','call','case',
    'class','color','const','constructor','create','declare','define',
    'delete','dim','do','else','elseif','end','endif','eof','eol','eqv',
    'erase','event','exit','extends','for','function','functioni','get',
    'gosub','goto','if','ifdef','ifndef','imp','include','input','lib',
    'locate','loop','me','mod','new','next','not','or','preserve',
    'print','private','property','protected','public','redim','return',
    'select','set','shl','shr','step','sub','subi','super','swap','then',
    'this','to','type','undef','until','wend','while','with','xor',
    { Type names — not strictly keywords but reserve to avoid shadowing }
    'byte','word','short','integer','dword','long','int64','uint64',
    'single','double','string','pointer','ptrint','bool','boolean'
  );

constructor TRqBasicEmitter.Create(const AUnitName, ALibrary: string);
begin
  inherited Create;
  FUnitName := AUnitName;
  FLibrary := ALibrary;
  FOutput := TStringList.Create;
  FEmittedTypes := TStringList.Create;
  FEmittedTypes.Sorted := True;
  FEmittedTypes.Duplicates := dupIgnore;
  FDeclaredTypeNames := TStringList.Create;
  FDeclaredTypeNames.Sorted := True;
  FDeclaredTypeNames.Duplicates := dupIgnore;
  FTypedefAliases := TStringList.Create;
  { Not sorted: Values[name] := newvalue replacements on a sorted
    list raise EStringListError, and headers commonly re-typedef the
    same name multiple times. }
  FTypedefAliases.Duplicates := dupIgnore;
  FPointerAliases := TStringList.Create;
  FPointerAliases.Sorted := True;
  FPointerAliases.Duplicates := dupIgnore;
end;

destructor TRqBasicEmitter.Destroy;
begin
  FOutput.Free;
  FEmittedTypes.Free;
  FDeclaredTypeNames.Free;
  FTypedefAliases.Free;
  FPointerAliases.Free;
  inherited Destroy;
end;

procedure TRqBasicEmitter.Line(const S: string);
begin
  FOutput.Add(S);
end;

function TRqBasicEmitter.EscapeIdent(const S: string): string;
var
  I: Integer;
  Lower: string;
begin
  if S = '' then begin Result := S; Exit; end;
  Lower := LowerCase(S);
  for I := Low(RQBASIC_RESERVED) to High(RQBASIC_RESERVED) do
    if Lower = RQBASIC_RESERVED[I] then
    begin
      Result := S + '_';
      Exit;
    end;
  Result := S;
end;

function TRqBasicEmitter.DisambiguateIdent(const CName: string): string;
begin
  Result := EscapeIdent(CName);
  while (FDeclaredTypeNames.IndexOf(LowerCase(Result)) >= 0)
     or (FEmittedTypes.IndexOf('fn:' + LowerCase(Result)) >= 0) do
    Result := Result + '_';
end;

function TRqBasicEmitter.RawComment(const Raw: string): string;
var
  S: string;
  Lines: TStringList;
  I: Integer;
begin
  if Trim(Raw) = '' then begin Result := ''; Exit; end;
  S := StringReplace(Raw, #13#10, #10, [rfReplaceAll]);
  Lines := TStringList.Create;
  try
    Lines.Text := S;
    Result := '';
    for I := 0 to Lines.Count - 1 do
    begin
      if Result <> '' then Result := Result + sLineBreak;
      Result := Result + ''''  + Lines.Strings[I];
    end;
  finally
    Lines.Free;
  end;
end;

function TRqBasicEmitter.LibClause: string;
begin
  if FLibrary <> '' then
    Result := Format('LIB "%s" ', [FLibrary])
  else
    Result := '';
end;

{ C primitive → rqbasic built-in. Width choices honour the active
  clang target's `long` size (LP64=8, LLP64=4) via SizeBytes. }
function TRqBasicEmitter.MapPrimitive(const Spelling: string; SizeBytes: Int64): string;
var
  S: string;
begin
  S := Trim(Spelling);
  if Copy(S, 1, 6) = 'const ' then S := Trim(Copy(S, 7, MaxInt));
  if Copy(S, 1, 9) = 'volatile ' then S := Trim(Copy(S, 10, MaxInt));
  if Copy(S, 1, 6) = 'const ' then S := Trim(Copy(S, 7, MaxInt));
  if Copy(S, 1, 7) = 'struct ' then S := Trim(Copy(S, 8, MaxInt))
  else if Copy(S, 1, 6) = 'union '  then S := Trim(Copy(S, 7, MaxInt))
  else if Copy(S, 1, 5) = 'enum '   then S := Trim(Copy(S, 6, MaxInt));
  if (Pos('(', S) > 0) or (Pos('__attribute', S) > 0)
     or (Pos('__vector', S) > 0) then
  begin
    Result := 'POINTER';
    Exit;
  end;
  if      S = 'void'                  then Result := ''
  else if S = 'bool'                  then Result := 'BYTE'
  else if S = '_Bool'                 then Result := 'BYTE'
  else if S = 'char'                  then Result := 'BYTE'
  else if S = 'signed char'           then Result := 'BYTE'
  else if S = 'unsigned char'         then Result := 'BYTE'
  else if S = 'short'                 then Result := 'SHORT'
  else if S = 'unsigned short'        then Result := 'WORD'
  else if S = 'int'                   then Result := 'INTEGER'
  else if S = 'unsigned int'          then Result := 'DWORD'
  else if S = 'unsigned'              then Result := 'DWORD'
  else if S = 'long'                  then
  begin
    if SizeBytes = 4 then Result := 'INTEGER' else Result := 'INT64';
  end
  else if S = 'unsigned long'         then
  begin
    if SizeBytes = 4 then Result := 'DWORD' else Result := 'UINT64';
  end
  else if S = 'long long'             then Result := 'INT64'
  else if S = 'unsigned long long'    then Result := 'UINT64'
  else if S = 'float'                 then Result := 'SINGLE'
  else if S = 'double'                then Result := 'DOUBLE'
  else if S = 'long double'           then Result := 'DOUBLE'
  else Result := S;
end;

{ Given a mapped pointee name, register a `TYPE P<X> AS X Ptr` alias
  and return its Pascal-side name. Primitives, POINTER, PCHAR, and
  empty (void) collapse to bare POINTER — those aren't aliasable. }
function TRqBasicEmitter.AliasPointer(const Pointee: string): string;
var
  L: string;
begin
  if Pointee = '' then begin Result := 'POINTER'; Exit; end;
  L := LowerCase(Pointee);
  if (L = 'byte') or (L = 'word') or (L = 'short') or (L = 'integer')
     or (L = 'dword') or (L = 'long') or (L = 'int64') or (L = 'uint64')
     or (L = 'single') or (L = 'double') or (L = 'string')
     or (L = 'pointer') or (L = 'pchar') or (L = 'ptrint')
     or (L = 'bool') or (L = 'boolean') then
  begin
    Result := 'POINTER';
    Exit;
  end;
  { Reject anything that doesn't look like a bare identifier — e.g.
    array-decoration `Foo(N)` or stray spaces — so we don't emit a
    syntactically broken alias. }
  if (Pos('(', Pointee) > 0) or (Pos(' ', Pointee) > 0)
     or (Pos(',', Pointee) > 0) then
  begin
    Result := 'POINTER';
    Exit;
  end;
  FPointerAliases.Add(Pointee);
  Result := 'P' + Pointee;
end;

{ Recursively touch every pointer-bearing position in T so that
  AliasPointer registers each pointee before the main emit pass.
  The result of MapType is discarded; the side effects on
  FPointerAliases / FTypedefAliases are what matter. }
procedure TRqBasicEmitter.WalkTypeForAliases(T: TBindingType);
var
  J: Integer;
  Discard: string;
begin
  if T = nil then Exit;
  Discard := MapType(T);
  if Discard = '' then ;
  if T.Pointee <> nil then WalkTypeForAliases(T.Pointee);
  if T.FuncReturn <> nil then WalkTypeForAliases(T.FuncReturn);
  if T.FuncParams <> nil then
    for J := 0 to T.FuncParams.Count - 1 do
      WalkTypeForAliases(T.FuncParams.Items[J]);
end;

procedure TRqBasicEmitter.CollectPointerAliases(U: TBindingUnit);
var
  I, J: Integer;
  D: TBindingDecl;
  F: TBindingFunction;
  R: TBindingRecord;
  Td: TBindingTypedef;
begin
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if D is TBindingFunction then
    begin
      F := TBindingFunction(D);
      WalkTypeForAliases(F.ReturnType);
      for J := 0 to F.Params.Count - 1 do
        WalkTypeForAliases(F.Params.Items[J].ParamType);
    end
    else if D is TBindingRecord then
    begin
      R := TBindingRecord(D);
      for J := 0 to R.Fields.Count - 1 do
        WalkTypeForAliases(R.Fields.Items[J].FieldType);
    end
    else if D is TBindingTypedef then
    begin
      Td := TBindingTypedef(D);
      WalkTypeForAliases(Td.Aliased);
    end;
  end;
end;

{ Map a C type to its rqbasic equivalent. Pointer-to-T becomes the
  typed alias `PT` (via AliasPointer), with char*/void*/function-
  pointer/va_list staying as plain POINTER. }
function TRqBasicEmitter.MapType(T: TBindingType): string;
var
  Inner: string;
begin
  if T = nil then begin Result := 'POINTER'; Exit; end;
  if (Pos('(unnamed ', T.Spelling) > 0)
     or (Pos('(anonymous ', T.Spelling) > 0)
     or (Pos('__va_list_tag', T.Spelling) > 0)
     or (Pos('__builtin_va_list', T.Spelling) > 0)
     or (Pos('__attribute__', T.Spelling) > 0) then
  begin
    Result := 'POINTER';
    Exit;
  end;
  case T.Kind of
    tkFunctionPointer, tkVaList:
      Result := 'POINTER';
    tkPointer:
      begin
        if T.Pointee = nil then
          Result := 'POINTER'
        else if T.Pointee.Kind in [tkFunctionPointer, tkVaList] then
          Result := 'POINTER'
        else if T.Pointee.Kind = tkPointer then
          { Double-indirection (e.g. sqlite3**) can't be typed in
            rqbasic: `TYPE PPFoo AS PFoo Ptr` forward-declares PFoo,
            but the rapidq compiler requires the forward to land on a
            `TYPE PFoo ... END TYPE` body — a `TYPE PFoo AS Foo Ptr`
            alias doesn't satisfy. Collapse to POINTER. }
          Result := 'POINTER'
        else if (T.Pointee.Kind = tkPrimitive)
                and ((Trim(T.Pointee.Spelling) = 'char')
                     or (Trim(T.Pointee.Spelling) = 'const char')
                     or (Trim(T.Pointee.Spelling) = 'void')) then
          Result := 'POINTER'
        else
          Result := AliasPointer(MapType(T.Pointee));
      end;
    tkArray:
      begin
        if T.Pointee = nil then
          Result := 'POINTER'
        else if T.ArraySize > 0 then
          Result := Format('%s(%d)', [MapType(T.Pointee), T.ArraySize - 1])
        else
          Result := 'POINTER';
      end;
    tkRecordRef, tkEnumRef, tkTypedefRef:
      begin
        Inner := T.Spelling;
        if Copy(Inner, 1, 6) = 'const ' then Delete(Inner, 1, 6);
        if Copy(Inner, 1, 9) = 'volatile ' then Delete(Inner, 1, 9);
        if      Copy(Inner, 1, 7) = 'struct '  then Delete(Inner, 1, 7)
        else if Copy(Inner, 1, 6) = 'union '   then Delete(Inner, 1, 6)
        else if Copy(Inner, 1, 5) = 'enum '    then Delete(Inner, 1, 5);
        if (T.Kind = tkTypedefRef)
           and (FTypedefAliases.IndexOfName(Inner) >= 0) then
          Result := FTypedefAliases.Values[Inner]
        else if (T.Kind = tkTypedefRef)
           and (FDeclaredTypeNames.IndexOf(Inner) < 0)
           and (T.CanonicalSpelling <> '') then
        begin
          if Copy(T.CanonicalSpelling, 1, 5) = 'enum ' then
            Result := 'INTEGER'
          else
            Result := MapPrimitive(T.CanonicalSpelling, T.ByteSize);
        end
        else if (T.Kind = tkEnumRef)
                and (FDeclaredTypeNames.IndexOf(Inner) < 0) then
          Result := 'INTEGER'
        else if (FDeclaredTypeNames.IndexOf(Inner) < 0) then
          { Last-resort: an unknown typedef/record name with no
            canonical hint -> POINTER (opaque). Beats emitting a name
            that rqbasic can't resolve at semantic-analysis time. }
          Result := 'POINTER'
        else
          Result := Inner;
      end;
    tkPrimitive:
      Result := MapPrimitive(T.Spelling, T.ByteSize);
  else
    Result := MapPrimitive(T.Spelling, T.ByteSize);
  end;
end;

function TRqBasicEmitter.MapTypeForSig(T: TBindingType): string;
begin
  Result := MapType(T);
  if Result = '' then Result := 'POINTER';
end;

procedure TRqBasicEmitter.EmitProvenance(U: TBindingUnit);
var
  I: Integer;
begin
  Line('''DO NOT EDIT — generated by pascal_bindgen (RapidQ BASIC dialect).');
  for I := 0 to U.HeaderPaths.Count - 1 do
    Line('''  source: ' + U.HeaderPaths.Strings[I]);
  if FLibrary <> '' then
    Line('''  library: ' + FLibrary);
  if U.CommandLine <> '' then
    Line('''  command: ' + U.CommandLine);
  if U.ClangVersion <> '' then
    Line('''  clang:   ' + U.ClangVersion);
end;

procedure TRqBasicEmitter.EmitFunction(F: TBindingFunction);
var
  I: Integer;
  Params: string;
  P: TBindingParam;
  RetType, ParamName, PascalName, Kind, Sig: string;
begin
  if F.RawComment <> '' then Line(RawComment(F.RawComment));
  PascalName := DisambiguateIdent(F.Name);
  Params := '';
  for I := 0 to F.Params.Count - 1 do
  begin
    P := F.Params.Items[I];
    if Params <> '' then Params := Params + ', ';
    ParamName := P.Name;
    if ParamName = '' then ParamName := Format('arg%d', [I + 1]);
    ParamName := EscapeIdent(ParamName);
    Params := Params + ParamName + ' AS ' + MapTypeForSig(P.ParamType);
  end;
  if Params <> '' then Params := '(' + Params + ')'
  else Params := '()';

  RetType := MapTypeForSig(F.ReturnType);
  if RetType = 'POINTER' then  { void in MapType -> '' -> 'POINTER' override }
  begin
    if F.ReturnType = nil then RetType := ''
    else if (F.ReturnType.Kind = tkPrimitive)
            and (Trim(F.ReturnType.Spelling) = 'void') then RetType := '';
  end;

  { Pad SUB to FUNCTION's width so the routine name column aligns
    across both kinds — a stretch of mixed DECLAREs stays scannable. }
  if RetType = '' then Kind := 'SUB     ' else Kind := 'FUNCTION';
  Sig := Format('DECLARE %s %s %sALIAS "%s" %s',
                [Kind, PascalName, LibClause, F.Name, Params]);
  if RetType <> '' then Sig := Sig + ' AS ' + RetType;
  if F.IsVarArgs then
    Sig := Sig + '  '' varargs — call via wrapper';
  FEmittedTypes.Add('fn:' + LowerCase(PascalName));
  Line(Sig);
end;

procedure TRqBasicEmitter.EmitRecord(R: TBindingRecord);
var
  I: Integer;
  F: TBindingField;
  Mapped: string;
begin
  if R.RawComment <> '' then Line(RawComment(R.RawComment));
  if R.IsUnion then
    Line(Format('TYPE %s  '' union — first alternative only',
                [EscapeIdent(R.Name)]))
  else
    Line(Format('TYPE %s', [EscapeIdent(R.Name)]));
  if R.IsUnion and (R.Fields.Count > 0) then
  begin
    F := R.Fields.Items[0];
    Mapped := MapType(F.FieldType);
    if Mapped = '' then Mapped := 'POINTER';
    Line(Format('  %s AS %s', [EscapeIdent(F.Name), Mapped]));
    for I := 1 to R.Fields.Count - 1 do
      Line(Format('  '' alt %d: %s AS %s',
           [I, R.Fields.Items[I].Name, MapType(R.Fields.Items[I].FieldType)]));
  end
  else if not R.IsUnion then
    for I := 0 to R.Fields.Count - 1 do
    begin
      F := R.Fields.Items[I];
      Mapped := MapType(F.FieldType);
      if Mapped = '' then Mapped := 'POINTER';
      Line(Format('  %s AS %s', [EscapeIdent(F.Name), Mapped]));
    end;
  Line('END TYPE');
end;

procedure TRqBasicEmitter.EmitEnum(E: TBindingEnum);
var
  J: Integer;
  EC: TBindingEnumConst;
begin
  { rqbasic has no enum type; surface each constant as CONST. The
    enum name itself maps to INTEGER at call sites via MapType. }
  if E.RawComment <> '' then Line(RawComment(E.RawComment));
  for J := 0 to E.Constants.Count - 1 do
  begin
    EC := E.Constants.Items[J];
    if FEmittedTypes.IndexOf('c:' + LowerCase(EC.Name)) >= 0 then Continue;
    FEmittedTypes.Add('c:' + LowerCase(EC.Name));
    Line(Format('CONST %s = %d', [EscapeIdent(EC.Name), EC.Value]));
  end;
end;

procedure TRqBasicEmitter.EmitTypedef(T: TBindingTypedef);
var
  Aliased: string;
begin
  if T.RawComment <> '' then Line(RawComment(T.RawComment));
  Aliased := MapType(T.Aliased);
  if Aliased = '' then Aliased := 'POINTER';
  if LowerCase(Aliased) = LowerCase(T.Name) then Exit;
  { rqbasic has no `TYPE A = B` alias form. We can express
    record-shaped aliases via TYPE...END TYPE (single field) but
    primitive aliases collapse: emit as a comment and let MapType
    look through the canonical spelling at call sites. }
  Line(Format('''typedef %s = %s  ('' aliased — referenced inline)',
              [EscapeIdent(T.Name), Aliased]));
end;

{ Pascal-style hex `$ABCD` -> rqbasic `&HABCD`. The IR parser
  normalises C `0x...` to `$...`; rqbasic's lexer rejects `$` as a
  hex prefix (it's a directive marker), so we rewrite per emit. }
function RqHexLit(const Raw: string): string;
var
  S: string;
begin
  S := Trim(Raw);
  if (S <> '') and (S[1] = '-') and (Length(S) > 1) and (S[2] = '$') then
    Result := '-&H' + Copy(S, 3, MaxInt)
  else if (S <> '') and (S[1] = '$') then
    Result := '&H' + Copy(S, 2, MaxInt)
  else
    Result := Raw;
end;

procedure TRqBasicEmitter.EmitMacro(M: TBindingMacroConst);
begin
  if M.RawComment <> '' then Line(RawComment(M.RawComment));
  Line(Format('CONST %s = %s', [EscapeIdent(M.Name), RqHexLit(M.RawValue)]));
end;

function BlaiseRejectsMacro(const RawValue: string): Boolean;
begin
  Result := ExceedsInt64Hex(RawValue);
end;

procedure TRqBasicEmitter.EmitDecl(D: TBindingDecl);
begin
  if D is TBindingFunction then
  begin
    if FEmittedTypes.IndexOf('cfn:' + D.Name) >= 0 then Exit;
    FEmittedTypes.Add('cfn:' + D.Name);
    EmitFunction(TBindingFunction(D));
    Exit;
  end;
  if (Pos('(', D.Name) > 0) or (Pos(' ', D.Name) > 0) then Exit;
  { Vacuous self-typedef (`typedef struct sqlite3 sqlite3;`) — don't
    claim the name in FEmittedTypes so the matching StructDecl can
    still emit. EmitTypedef would otherwise Exit early after the
    name was already reserved, masking the real record body. }
  if (D is TBindingTypedef)
     and (LowerCase(MapType(TBindingTypedef(D).Aliased)) = LowerCase(D.Name)) then
    Exit;
  if FEmittedTypes.IndexOf(D.Name) >= 0 then Exit;
  FEmittedTypes.Add(D.Name);
  if      D is TBindingRecord  then EmitRecord(TBindingRecord(D))
  else if D is TBindingEnum    then EmitEnum(TBindingEnum(D))
  else if D is TBindingTypedef then EmitTypedef(TBindingTypedef(D));
end;

function TRqBasicEmitter.Emit(U: TBindingUnit): string;
var
  I: Integer;
  D: TBindingDecl;
  Td: TBindingTypedef;
  AT: TBindingType;
  Mapped: string;
begin
  FOutput.Clear;
  FEmittedTypes.Clear;
  FDeclaredTypeNames.Clear;
  FTypedefAliases.Clear;
  FPointerAliases.Clear;
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if D is TBindingFunction then Continue;
    if D is TBindingMacroConst then Continue;
    { Enums don't synthesise a TYPE in rqbasic — only their constants.
      Skip the name so MapType falls back to INTEGER at use sites. }
    if D is TBindingEnum then Continue;
    { Typedefs are emitted as comment-only notes (rqbasic has no
      `TYPE A = B` alias form). Skip so references resolve via
      canonical primitive mapping. }
    if D is TBindingTypedef then Continue;
    FDeclaredTypeNames.Add(D.Name);
  end;
  { Build the typedef -> primitive replacement table so MapType can
    substitute references in field/param positions. Only handles the
    cases rqbasic actually needs: typedef-of-primitive, typedef-of-
    enum, typedef-of-pointer-shape (collapse to POINTER), and typedef
    chains that resolve through CanonicalSpelling. Records / unions
    keep their name and are looked up via FDeclaredTypeNames. }
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if not (D is TBindingTypedef) then Continue;
    Td := TBindingTypedef(D);
    AT := Td.Aliased;
    if AT = nil then Continue;
    Mapped := '';
    case AT.Kind of
      tkPrimitive:
        Mapped := MapPrimitive(AT.Spelling, AT.ByteSize);
      tkPointer, tkFunctionPointer, tkArray, tkVaList:
        Mapped := 'POINTER';
      tkEnumRef:
        Mapped := 'INTEGER';
      tkTypedefRef, tkRecordRef:
        begin
          if (AT.Kind = tkTypedefRef) and (AT.CanonicalSpelling <> '') then
          begin
            if Copy(AT.CanonicalSpelling, 1, 5) = 'enum ' then
              Mapped := 'INTEGER'
            else if Copy(AT.CanonicalSpelling, 1, 7) = 'struct ' then
              Mapped := ''  { keep struct name reachable via canonical }
            else
              Mapped := MapPrimitive(AT.CanonicalSpelling, AT.ByteSize);
          end
          else if AT.Kind = tkRecordRef then
          begin
            { typedef-of-struct (`typedef struct _GdkPixbuf GdkPixbuf;`)
              — the parser doesn't fill CanonicalSpelling for record
              typedefs, so we route through the record's stripped name
              if it's actually declared. That makes `GdkPixbuf*` map to
              `_GdkPixbuf` -> AliasPointer -> `P_GdkPixbuf` at the
              pointer level. }
            Mapped := AT.Spelling;
            if Copy(Mapped, 1, 7) = 'struct ' then Delete(Mapped, 1, 7)
            else if Copy(Mapped, 1, 6) = 'union '  then Delete(Mapped, 1, 6);
            if FDeclaredTypeNames.IndexOf(Mapped) < 0 then Mapped := '';
          end;
        end;
    end;
    if Mapped <> '' then
      FTypedefAliases.Values[Td.Name] := Mapped;
  end;

  { Walk every type position to populate FPointerAliases ahead of
    emit — rqbasic accepts forward-declared pointees, so we can dump
    all aliases at the top regardless of declaration order. }
  CollectPointerAliases(U);

  EmitProvenance(U);
  Line;
  Line('$CALLING CDECL');
  Line;

  { Typed pointer aliases: `TYPE PFoo AS Foo Ptr`. Foo may not be
    declared yet — rqbasic treats it as a forward declaration when
    the alias precedes the TYPE block. }
  if FPointerAliases.Count > 0 then
  begin
    for I := 0 to FPointerAliases.Count - 1 do
      Line(Format('TYPE P%s AS %s Ptr',
                  [FPointerAliases[I], EscapeIdent(FPointerAliases[I])]));
    Line;
  end;

  { Types first (TYPE blocks, enum CONSTs, typedef notes). }
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if (D is TBindingFunction) or (D is TBindingMacroConst) then Continue;
    EmitDecl(D);
  end;
  Line;

  { #define-style integer macros. }
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if not (D is TBindingMacroConst) then Continue;
    if FEmittedTypes.IndexOf('c:' + LowerCase(D.Name)) >= 0 then Continue;
    if BlaiseRejectsMacro(TBindingMacroConst(D).RawValue) then Continue;
    FEmittedTypes.Add('c:' + LowerCase(D.Name));
    EmitMacro(TBindingMacroConst(D));
  end;
  Line;

  { Functions. }
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if D is TBindingFunction then EmitDecl(D);
  end;

  Result := FOutput.Text;
end;

end.
