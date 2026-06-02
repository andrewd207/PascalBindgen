{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

(* bindgen.emit.fpc — Free Pascal / Delphi-mode emitter.

  Renders a TBindingUnit to a single .pas source string. Layout:

    -- provenance header
    --   header source path(s) + clang version
    --   generator version + DO NOT EDIT
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
  * Reserved-word escaping (`&for`, `&end`, ...) *)
unit bindgen.emit.fpc;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, bindgen.ir;

type
  TFpcEmitter = class
  private
    FUnitName: string;
    FLibrary: string;
    FOutput: TStringList;
    FEmittedTypes: TStringList;
    FDeclaredTypeNames: TStringList;
    FPointerAliases: TStringList;
    FOpaqueTypedefs: TStringList;
    FNeedsVaList: Boolean;
    procedure Line(const S: string = '');
    procedure EmitProvenance(U: TBindingUnit);
    procedure EmitDecl(D: TBindingDecl);
    procedure EmitFunction(F: TBindingFunction);
    procedure EmitRecord(R: TBindingRecord);
    procedure EmitEnum(E: TBindingEnum);
    procedure EmitTypedef(T: TBindingTypedef);
    procedure EmitMacro(M: TBindingMacroConst);
    function  MapType(T: TBindingType): string;
    { Like MapType, but if the result is an inline pointer ('^X')
      it registers and returns a named alias 'PX = ^X' — required
      because FPC rejects '^X' as a parameter or return type. }
    function  MapTypeForSig(T: TBindingType): string;
    function  AliasPointer(const Raw: string): string;
    function  LocComment(const Loc: TSourceLoc): string;
    function  EscapeIdent(const S: string): string;
    function  DisambiguateIdent(const CName: string): string;
    procedure CollectFunctionPointerAliases(U: TBindingUnit);
    procedure WalkTypeForAliases(T: TBindingType);
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
  FEmittedTypes := TStringList.Create;
  FEmittedTypes.Sorted := True;
  FEmittedTypes.Duplicates := dupIgnore;
  FPointerAliases := TStringList.Create;
  FPointerAliases.Sorted := True;
  FPointerAliases.Duplicates := dupIgnore;
  FOpaqueTypedefs := TStringList.Create;
  FOpaqueTypedefs.Sorted := True;
  FOpaqueTypedefs.Duplicates := dupIgnore;
  FDeclaredTypeNames := TStringList.Create;
  FDeclaredTypeNames.Sorted := True;
  FDeclaredTypeNames.Duplicates := dupIgnore;
end;

{ FPC reserved-word table (objfpc + delphi modes). Identifiers
  coming from the C source that collide get a '_' suffix — a
  legal identifier that is portable across Pascal dialects (Blaise
  has no '&' escape, so the same convention works for both).
  Lowercased before comparison since Pascal is case-insensitive
  but the table only stores the canonical form. }
const
  FPC_RESERVED: array[0..67] of string = (
    'absolute','and','array','as','asm','begin','case','class',
    'const','constructor','destructor','div','do','downto','else',
    'end','except','exports','external','file','finalization','finally',
    'for','function','goto','if','implementation','in','inherited',
    'initialization','inline','interface','is','label','library','mod',
    'nil','not','object','of','on','operator','or','out','packed',
    'procedure','program','property','raise','record','repeat',
    'resourcestring','set','shl','shr','string','then',
    'threadvar','to','try','type','unit','until','uses','var',
    'while','with','xor'
  );

function TFpcEmitter.EscapeIdent(const S: string): string;
var
  I: Integer;
  Lower: string;
begin
  if S = '' then begin Result := S; Exit; end;
  Lower := LowerCase(S);
  for I := Low(FPC_RESERVED) to High(FPC_RESERVED) do
    if Lower = FPC_RESERVED[I] then
    begin
      Result := S + '_';
      Exit;
    end;
  Result := S;
end;

destructor TFpcEmitter.Destroy;
begin
  FOutput.Free;
  FEmittedTypes.Free;
  FPointerAliases.Free;
  FOpaqueTypedefs.Free;
  FDeclaredTypeNames.Free;
  inherited Destroy;
end;

procedure TFpcEmitter.Line(const S: string);
begin
  FOutput.Add(S);
end;

{ Wrap a raw C comment in Pascal (* *) so FPC accepts it verbatim.
  We keep the original /** ... */ text inside the wrapper so Doxygen
  markup is preserved for any tool that still wants to grep for it. }
function PascalizeComment(const Raw: string): string;
var
  S: string;
begin
  if Trim(Raw) = '' then begin Result := ''; Exit; end;
  { Both Pascal comment forms can nest inside a Doxygen body
    (regex examples, brace-style struct literals). Rewrite them so
    the wrapper (* ... *) stays balanced. }
  S := StringReplace(Raw, '(*', '( *', [rfReplaceAll]);
  S := StringReplace(S, '*)', '* )', [rfReplaceAll]);
  S := StringReplace(S, '{', '[', [rfReplaceAll]);
  S := StringReplace(S, '}', ']', [rfReplaceAll]);
  Result := '(* ' + S + ' *)';
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
  { Reject any spelling that doesn't look like a plain identifier
    chain — libclang occasionally surfaces __attribute__/vector
    forms that no Pascal compiler will accept. }
  if (Pos('(', S) > 0) or (Pos('__attribute', S) > 0)
     or (Pos('__vector', S) > 0) then
  begin
    Result := 'Pointer';
    Exit;
  end;
  { Strip 'const ' prefix for the purpose of mapping the underlying
    primitive. Const-qualification is handled at the param level. }
  if Copy(S, 1, 6) = 'const ' then S := Trim(Copy(S, 7, MaxInt));
  if Copy(S, 1, 9) = 'volatile ' then S := Trim(Copy(S, 10, MaxInt));
  if Copy(S, 1, 6) = 'const ' then S := Trim(Copy(S, 7, MaxInt));
  if Copy(S, 1, 7) = 'struct ' then S := Trim(Copy(S, 8, MaxInt))
  else if Copy(S, 1, 6) = 'union '  then S := Trim(Copy(S, 7, MaxInt))
  else if Copy(S, 1, 5) = 'enum '   then S := Trim(Copy(S, 6, MaxInt));
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

{ Recursively name an inline pointer type. '^X' becomes 'PX' (with
  'PX = ^X' registered); '^^X' becomes 'PPX' (with 'PPX = ^PX' and
  'PX = ^X' both registered). The result is always a single Pascal
  identifier safe to use as a parameter or return type. }
function TFpcEmitter.AliasPointer(const Raw: string): string;
var
  Pointee, InnerAlias: string;
begin
  if (Length(Raw) >= 2) and (Raw[1] = '^') then
  begin
    Pointee := Copy(Raw, 2, MaxInt);
    if (Length(Pointee) >= 1) and (Pointee[1] = '^') then
    begin
      InnerAlias := AliasPointer(Pointee);
      Result := 'P' + InnerAlias;
      FPointerAliases.Add(InnerAlias);
    end
    else
    begin
      Result := 'P' + Pointee;
      FPointerAliases.Add(Pointee);
    end;
  end
  else
    Result := Raw;
end;

function TFpcEmitter.MapTypeForSig(T: TBindingType): string;
begin
  { Inline function pointers can't appear mid-parameter-list in FPC
    (the trailing `cdecl;` collides with the next param's separator).
    Typedef'd ones come through as tkTypedefRef and stay readable;
    anonymous ones degrade to Pointer. }
  if (T <> nil) and (T.Kind = tkFunctionPointer) then
  begin
    Result := 'Pointer';
    Exit;
  end;
  { C array parameter (`float foo[4]`) decays to a pointer at the
    ABI level. Render as a pointer alias so FPC accepts the param. }
  if (T <> nil) and (T.Kind = tkArray) and (T.Pointee <> nil) then
  begin
    Result := AliasPointer('^' + MapType(T.Pointee));
    Exit;
  end;
  Result := AliasPointer(MapType(T));
end;

{ Recursively touch every type position to populate FPointerAliases.
  Mirrors what real emission does, so the aliases can be declared
  once at the top of the `type` section — FPC will not forward-resolve
  a 'P<X>' identifier inside a procedural-type body in a typedef RHS,
  so the aliases must already be in scope when those typedefs are
  emitted. }
procedure TFpcEmitter.WalkTypeForAliases(T: TBindingType);
var
  J: Integer;
  Discard, RefName: string;
begin
  if T = nil then Exit;
  Discard := AliasPointer(MapType(T));
  if Discard = '' then ;
  { Collect any typedef-ref name that isn't a declared local type and
    has no usable canonical primitive — these need an opaque stub
    so the unit links. Covers system typedefs that leaked into a
    field type (pthread_mutex_t, etc.). }
  if (T.Kind = tkTypedefRef) then
  begin
    RefName := T.Spelling;
    if Copy(RefName, 1, 7) = 'struct ' then Delete(RefName, 1, 7)
    else if Copy(RefName, 1, 6) = 'union '  then Delete(RefName, 1, 6)
    else if Copy(RefName, 1, 5) = 'enum '   then Delete(RefName, 1, 5);
    if Copy(RefName, 1, 6) = 'const '   then Delete(RefName, 1, 6);
    if (FDeclaredTypeNames.IndexOf(LowerCase(RefName)) < 0)
       and (T.CanonicalSpelling = '')
       and (RefName <> '')
       { Filter out pathological libclang spellings — GCC vector
         attributes, va_list internals, anything with parens or
         commas (not a legal Pascal identifier). }
       and (Pos('(', RefName) = 0)
       and (Pos(')', RefName) = 0)
       and (Pos(',', RefName) = 0)
       and (Pos(' ', RefName) = 0)
       and (Pos('*', RefName) = 0)
       and (Pos('__va_list_tag', RefName) = 0)
       and (RefName <> 'va_list')
       and (Copy(RefName, 1, 2) <> '__') then
      FOpaqueTypedefs.Add(RefName);
  end;
  if T.Pointee <> nil then WalkTypeForAliases(T.Pointee);
  if T.FuncReturn <> nil then WalkTypeForAliases(T.FuncReturn);
  if T.FuncParams <> nil then
    for J := 0 to T.FuncParams.Count - 1 do
      WalkTypeForAliases(T.FuncParams.Items[J]);
end;

procedure TFpcEmitter.CollectFunctionPointerAliases(U: TBindingUnit);
  procedure DoClear;
  begin
    FPointerAliases.Clear;
    FOpaqueTypedefs.Clear;
  end;
var
  I, J: Integer;
  D: TBindingDecl;
  F: TBindingFunction;
  R: TBindingRecord;
  Td: TBindingTypedef;
begin
  DoClear;
  FNeedsVaList := False;
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

function TFpcEmitter.MapType(T: TBindingType): string;
var
  Inner: string;
  J: Integer;
  Params, Ret: string;
begin
  if T = nil then begin Result := 'Pointer'; Exit; end;
  { Anonymous nested records ('(unnamed union at ...)') and other
    libclang-internal spellings collapse to Pointer-sized blobs. }
  if (Pos('(unnamed ', T.Spelling) > 0)
     or (Pos('(anonymous ', T.Spelling) > 0)
     or (Pos('__va_list_tag', T.Spelling) > 0)
     or (Pos('__builtin_va_list', T.Spelling) > 0)
     or (Pos('__attribute__', T.Spelling) > 0)
     or (Pos('__WIDL_', T.Spelling) > 0) then  { MIDL anonymous-union names }
  begin
    Result := 'Pointer';
    Exit;
  end;
  case T.Kind of
    tkPointer:
      begin
        if T.Pointee = nil then
          Result := 'Pointer'
        else if T.Pointee.Kind = tkFunctionPointer then
          { Pointer-to-function-pointer collapses to Pointer — Pascal
            procedural types are already handle-shaped. }
          Result := 'Pointer'
        else if T.Pointee.Kind = tkPointer then
          { Multi-level pointer (^^X) — FPC won't forward-resolve the
            inner '^X' in this position, so route through AliasPointer
            which registers 'PX = ^X' and returns 'PPX'. }
          Result := AliasPointer('^' + MapType(T.Pointee))
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
        if Copy(Inner, 1, 6) = 'const ' then Delete(Inner, 1, 6);
        if Copy(Inner, 1, 9) = 'volatile ' then Delete(Inner, 1, 9);
        if Copy(Inner, 1, 7)  = 'struct '  then Delete(Inner, 1, 7)
        else if Copy(Inner, 1, 6) = 'union '  then Delete(Inner, 1, 6)
        else if Copy(Inner, 1, 5) = 'enum '   then Delete(Inner, 1, 5);
        { Chase the canonical when the typedef itself is not in the
          unit (filtered out as a system-header decl). 'z_size_t =
          size_t;' would otherwise reference an undeclared name. }
        if (T.Kind = tkTypedefRef)
           and (FDeclaredTypeNames.IndexOf(LowerCase(Inner)) < 0)
           and (T.CanonicalSpelling <> '') then
        begin
          { Canonical-is-enum (e.g. Vulkan's StdVideo*Idc typedefs
            whose enum body lives in vk_video/ — admitted as system) }
          if Copy(T.CanonicalSpelling, 1, 5) = 'enum ' then
            Result := 'cuint'
          else
            Result := MapPrimitive(T.CanonicalSpelling);
        end
        else if (T.Kind = tkEnumRef)
                and (FDeclaredTypeNames.IndexOf(LowerCase(Inner)) < 0) then
          { C enums default to int; if the enum decl is in a header
            we filtered out (vk_video, ...) emit cuint as fallback. }
          Result := 'cuint'
        else
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
              [J + 1, MapTypeForSig(T.FuncParams.Items[J])]);
          end;
        if Params <> '' then Params := '(' + Params + ')';
        if T.FuncReturn = nil then Ret := ''
        else Ret := MapTypeForSig(T.FuncReturn);
        if Ret = '' then
          Result := Format('procedure%s; cdecl', [Params])
        else
          Result := Format('function%s: %s; cdecl', [Params, Ret]);
      end;
    tkVaList:
      begin
        FNeedsVaList := True;
        Result := 'va_list';
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
    Line('  source: ' + U.HeaderPaths.Strings[I]);
  if U.CommandLine <> '' then
    Line('  command: ' + U.CommandLine);
  if U.ClangVersion <> '' then
    Line('  clang:   ' + U.ClangVersion);
  Line('}');
end;

{ Resolve a C identifier to a Pascal identifier that doesn't clash
  with anything we've already emitted. Windows headers ship many
  name pairs that look distinct in C but collide under Pascal's
  case-insensitive rule — 'STRETCHBLT' const + 'StretchBlt' API,
  'GetProcessId' API + a same-named typedef, etc. The Pascal-side
  name picks up a '_' suffix; the linker symbol (via 'external
  name ...') stays untouched. }
function TFpcEmitter.DisambiguateIdent(const CName: string): string;
begin
  Result := EscapeIdent(CName);
  while (FDeclaredTypeNames.IndexOf(LowerCase(Result)) >= 0)
     or (FEmittedTypes.IndexOf('fn:' + LowerCase(Result)) >= 0) do
    Result := Result + '_';
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
  PascalName: string;
begin
  if F.RawComment <> '' then Line(PascalizeComment(F.RawComment));
  PascalName := DisambiguateIdent(F.Name);
  Params := '';
  for I := 0 to F.Params.Count - 1 do
  begin
    P := F.Params.Items[I];
    if Params <> '' then Params := Params + '; ';
    ParamName := P.Name;
    if ParamName = '' then ParamName := Format('arg%d', [I + 1]);
    ParamName := EscapeIdent(ParamName);
    if P.IsConst then
      Params := Params + 'const ' + ParamName + ': ' + MapTypeForSig(P.ParamType)
    else
      Params := Params + ParamName + ': ' + MapTypeForSig(P.ParamType);
  end;
  if Params <> '' then Params := '(' + Params + ')';

  RetType := MapTypeForSig(F.ReturnType);
  Modifiers := 'cdecl';
  if F.IsVarArgs then Modifiers := Modifiers + '; varargs';
  if FLibrary <> '' then
    Modifiers := Modifiers + Format('; external ''%s'' name ''%s''',
                                    [FLibrary, F.Name])
  else
    Modifiers := Modifiers + Format('; external name ''%s''', [F.Name]);

  if RetType = '' then
    Sig := Format('procedure %s%s; %s;', [PascalName, Params, Modifiers])
  else
    Sig := Format('function %s%s: %s; %s;', [PascalName, Params, RetType, Modifiers]);
  { Reserve the Pascal-side identifier so later decls dedup
    against it case-insensitively. }
  FEmittedTypes.Add('fn:' + LowerCase(PascalName));

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
    Line(Format('  %s = record  { union } %s', [EscapeIdent(R.Name), LocComment(R.Location)]));
    if R.Fields.Count > 0 then
    begin
      Line('    case Integer of');
      for I := 0 to R.Fields.Count - 1 do
      begin
        F := R.Fields.Items[I];
        Line(Format('      %d: (%s: %s);', [I, EscapeIdent(F.Name), MapType(F.FieldType)]));
      end;
    end;
    Line('  end;');
  end
  else
  begin
    Line(Format('  %s = record%s', [EscapeIdent(R.Name), LocComment(R.Location)]));
    for I := 0 to R.Fields.Count - 1 do
    begin
      F := R.Fields.Items[I];
      if F.BitWidth >= 0 then
        Line(Format('    %s: %s;  { bit-field: width=%d, best-effort }',
                    [EscapeIdent(F.Name), MapType(F.FieldType), F.BitWidth]))
      else
        Line(Format('    %s: %s;', [EscapeIdent(F.Name), MapType(F.FieldType)]));
    end;
    Line('  end;');
  end;
end;

procedure TFpcEmitter.EmitEnum(E: TBindingEnum);
var
  Underlying: string;
begin
  if E.RawComment <> '' then Line(PascalizeComment(E.RawComment));
  if E.UnderlyingType <> nil then
    Underlying := MapType(E.UnderlyingType)
  else
    Underlying := 'cint';
  if Underlying = '' then Underlying := 'cint';
  Line(Format('  %s = %s;%s', [EscapeIdent(E.Name), Underlying, LocComment(E.Location)]));
  { Enum constants land in a unified const block emitted after the
    entire type section so forward `^X` references stay resolvable
    across the whole section. }
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
  { Pascal is case-insensitive, so 'CCHAR = cchar' is a self-typedef
    (the same identifier on both sides). Skip lowered. }
  if LowerCase(Aliased) = LowerCase(T.Name) then Exit;
  Line(Format('  %s = %s;%s', [EscapeIdent(T.Name), Aliased, LocComment(T.Location)]));
end;

procedure TFpcEmitter.EmitMacro(M: TBindingMacroConst);
begin
  if M.RawComment <> '' then Line(PascalizeComment(M.RawComment));
  Line(Format('  %s = %s;%s',
              [EscapeIdent(M.Name), M.RawValue, LocComment(M.Location)]));
end;

procedure TFpcEmitter.EmitDecl(D: TBindingDecl);
begin
  if D is TBindingFunction then
  begin
    { C has no overloads. Multiple FunctionDecl cursors with the
      same exact C name are redeclarations; emit only the first.
      Pascal-side collisions (case-folded vs another decl) are
      handled inside EmitFunction by appending '_' to the Pascal
      identifier; the linker symbol stays as F.Name. }
    if FEmittedTypes.IndexOf('cfn:' + D.Name) >= 0 then Exit;
    FEmittedTypes.Add('cfn:' + D.Name);
    EmitFunction(TBindingFunction(D));
    Exit;
  end;
  { Skip decls whose names are libclang-internal blobs ('enum (unnamed
    at ...)', '__WIDL_*', anything with parens or spaces). They'd
    otherwise emit as invalid Pascal identifiers. }
  if (Pos('(', D.Name) > 0) or (Pos(' ', D.Name) > 0)
     or (Pos('__WIDL_', D.Name) > 0) then
    Exit;
  { Vacuous self-typedef (`typedef struct X X;`) — don't claim the
    name in FEmittedTypes, so a later struct decl can still emit. }
  if (D is TBindingTypedef)
     and (LowerCase(MapType(TBindingTypedef(D).Aliased)) = LowerCase(D.Name)) then
    Exit;
  { Type decls dedup by name. libclang surfaces forward decls and
    their later completions as separate cursors with the same
    spelling (zlib's gzFile_s hits this); emit only once. }
  if FEmittedTypes.IndexOf(D.Name) >= 0 then Exit;
  FEmittedTypes.Add(D.Name);
  if      D is TBindingRecord  then EmitRecord(TBindingRecord(D))
  else if D is TBindingEnum    then EmitEnum(TBindingEnum(D))
  else if D is TBindingTypedef then EmitTypedef(TBindingTypedef(D));
end;

function TFpcEmitter.Emit(U: TBindingUnit): string;
var
  I: Integer;
  D: TBindingDecl;
  HasTypes, HasFuncs, HasMacros: Boolean;
  J: Integer;
  EC: TBindingEnumConst;
begin
  FOutput.Clear;
  FEmittedTypes.Clear;
  FDeclaredTypeNames.Clear;
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if D is TBindingFunction then Continue;
    if D is TBindingMacroConst then Continue;
    { Exclude vacuous self-typedefs (`typedef struct X X;`) — they
      don't emit a body, so the name they hold isn't actually
      declared in the unit. }
    if (D is TBindingTypedef)
       and (LowerCase(MapType(TBindingTypedef(D).Aliased)) = LowerCase(D.Name)) then
      Continue;
    FDeclaredTypeNames.Add(LowerCase(D.Name));
  end;
  CollectFunctionPointerAliases(U);
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
    if D is TBindingFunction then HasFuncs := True
    else if not (D is TBindingMacroConst) then HasTypes := True;
  end;

  if HasTypes or (FPointerAliases.Count > 0) or (FOpaqueTypedefs.Count > 0)
     or FNeedsVaList then
  begin
    Line('type');
    { Platform-aware va_list. On SysV x86_64 it's a 24-byte struct
      passed by address (the `[1]` array-decay form). On Win64 / 32-bit
      / non-x86 it's effectively a `char*`. The intent here is twofold:
      (1) callers who already hold a va_list (e.g. a C-side variadic
      thunk handed one to us) can pass it through; (2) for level-2
      construction in Pascal, callers can take @localVaList and the
      record layout is right under SysV. See examples/helpers/. }
    if FNeedsVaList then
    begin
      { Reserve the name so a source-side `typedef ... va_list;`
        (glib, mingw windows.h, ...) is dropped as a duplicate. }
      FEmittedTypes.Add('va_list');
      FEmittedTypes.Add('__va_list_tag');
      Line('{$IFDEF CPUX86_64}{$IFDEF UNIX}');
      Line('  __va_list_tag = record');
      Line('    gp_offset, fp_offset: cuint;');
      Line('    overflow_arg_area, reg_save_area: Pointer;');
      Line('  end;');
      Line('  va_list = array[0..0] of __va_list_tag;');
      Line('{$ELSE}');
      Line('  va_list = PAnsiChar;  { Win64 — va_list is char* }');
      Line('{$ENDIF}{$ELSE}');
      Line('  va_list = PAnsiChar;  { 32-bit / non-x86 — va_list is char* }');
      Line('{$ENDIF}');
    end;
    { Opaque stubs for typedef-ref names that reference system-header
      types we never declared. Layout will not match C — this is a
      v1 "compile, don't crash" measure. }
    for I := 0 to FOpaqueTypedefs.Count - 1 do
      if FDeclaredTypeNames.IndexOf(LowerCase(FOpaqueTypedefs[I])) < 0 then
        { Default to Pointer — overwhelmingly the right ABI size for
          handle-like opaque types (Display *, EGLNativeDisplayType,
          most platform handles). Wrong only for the rare opaque
          struct-by-value typedefs like pthread_mutex_t. }
        Line(Format('  %s = Pointer;  { opaque — layout unknown, assumed pointer-shaped }',
                    [EscapeIdent(FOpaqueTypedefs[I])]));
    { Synthesized 'P<X> = ^X' aliases emitted FIRST so any typedef
      with an inline procedural-type RHS referencing them resolves.
      FPC accepts the forward 'X' name in '^X' (single-pointer
      forward-ref rule) even when 'X' is a record declared further
      down — but it does NOT forward-resolve 'PX' inside a
      function-pointer typedef body. }
    if FPointerAliases.Count > 0 then
    begin
      { Opaque forward record for any pointee that isn't declared in
        the unit and isn't a ctypes-known primitive — covers SQLite-
        style nested-in-struct types referenced only via pointer.
        Skip: ctypes-style primitives (cint/cuint/...), built-in
        Pascal types, and intermediate pointer-alias names like
        'PX' where 'X' is itself a pointer-alias entry. }
      for I := 0 to FPointerAliases.Count - 1 do
      begin
        if FDeclaredTypeNames.IndexOf(LowerCase(FPointerAliases[I])) >= 0 then Continue;
        if FOpaqueTypedefs.IndexOf(FPointerAliases[I]) >= 0 then Continue;
        if Pos('c', FPointerAliases[I]) = 1 then Continue;
        if (LowerCase(FPointerAliases[I]) = 'pointer')
           or (LowerCase(FPointerAliases[I]) = 'pansichar')
           or (LowerCase(FPointerAliases[I]) = 'pchar')
           or (LowerCase(FPointerAliases[I]) = 'pwidechar')
           or (LowerCase(FPointerAliases[I]) = 'pbyte')
           or (LowerCase(FPointerAliases[I]) = 'va_list')
           or (LowerCase(FPointerAliases[I]) = '__va_list_tag') then Continue;
        if (Length(FPointerAliases[I]) >= 2)
           and (FPointerAliases[I][1] = 'P')
           and (FPointerAliases.IndexOf(Copy(FPointerAliases[I], 2, MaxInt)) >= 0)
           then Continue;
        { Filter pathological libclang spellings — see WalkTypeForAliases. }
        if (Pos('(', FPointerAliases[I]) > 0)
           or (Pos(')', FPointerAliases[I]) > 0)
           or (Pos(',', FPointerAliases[I]) > 0)
           or (Pos(' ', FPointerAliases[I]) > 0)
           or (Pos('*', FPointerAliases[I]) > 0)
           or (Pos('__va_list_tag', FPointerAliases[I]) > 0)
           or (Copy(FPointerAliases[I], 1, 2) = '__') then Continue;
        Line(Format('  %s = record end;', [EscapeIdent(FPointerAliases[I])]));
      end;
      for I := 0 to FPointerAliases.Count - 1 do
      begin
        { Same pathological-spelling filter as above — skip aliases
          whose target name isn't a legal Pascal identifier. }
        if (Pos('(', FPointerAliases[I]) > 0)
           or (Pos(')', FPointerAliases[I]) > 0)
           or (Pos(',', FPointerAliases[I]) > 0)
           or (Pos(' ', FPointerAliases[I]) > 0)
           or (Pos('*', FPointerAliases[I]) > 0)
           or (Pos('__va_list_tag', FPointerAliases[I]) > 0) then Continue;
        { Windows headers ship a hand-written 'PULONG = ^ULONG;' family;
          skip our auto-alias when the same name is already declared
          by the source. Pascal is case-insensitive. }
        if FDeclaredTypeNames.IndexOf(LowerCase('P' + FPointerAliases[I])) >= 0 then
          Continue;
        Line(Format('  P%s = ^%s;',
                    [FPointerAliases[I], EscapeIdent(FPointerAliases[I])]));
      end;
    end;
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if (not (D is TBindingFunction))
         and (not (D is TBindingMacroConst)) then
        EmitDecl(D);
    end;
    Line;
  end;

  { #define integer-constant macros + enum constants emit as a
    single const block after the type section ends. }
  HasMacros := False;
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if D is TBindingMacroConst then begin HasMacros := True; Break; end;
    if (D is TBindingEnum) and (TBindingEnum(D).Constants.Count > 0) then
    begin HasMacros := True; Break; end;
  end;
  if HasMacros then
  begin
    Line('const');
    { Pascal is case-insensitive — dedup const names case-insensitively
      to silence collisions like GDK_KEY_a vs GDK_KEY_A. First wins. }
    FEmittedTypes.Clear;
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if D is TBindingMacroConst then
      begin
        if FEmittedTypes.IndexOf(LowerCase(D.Name)) >= 0 then Continue;
        FEmittedTypes.Add(LowerCase(D.Name));
        { Reserve so a same-named function (windows.h's STRETCHBLT
          const vs StretchBlt API) doesn't collide. }
        FDeclaredTypeNames.Add(LowerCase(D.Name));
        EmitMacro(TBindingMacroConst(D));
      end
      else if D is TBindingEnum then
        for J := 0 to TBindingEnum(D).Constants.Count - 1 do
        begin
          EC := TBindingEnum(D).Constants.Items[J];
          if FEmittedTypes.IndexOf(LowerCase(EC.Name)) >= 0 then Continue;
          FEmittedTypes.Add(LowerCase(EC.Name));
          FDeclaredTypeNames.Add(LowerCase(EC.Name));
          Line(Format('  %s = %d;', [EscapeIdent(EC.Name), EC.Value]));
        end;
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
