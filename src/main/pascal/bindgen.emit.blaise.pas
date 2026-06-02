{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

(* bindgen.emit.blaise — Blaise-dialect emitter.

  Structurally mirrors bindgen.emit.fpc; the parser populates the
  same IR and the same prepasses/aliasing rules apply. The four
  surface differences:

  1. No `{$mode}` / `{$H+}` / `{$PACKRECORDS}` directives, no
     `uses ctypes` — Blaise does not ship those.
  2. Primitive mapping targets Blaise's built-in types (`Integer`,
     `Cardinal`, `Int64`, `AnsiChar`, ...) rather than ctypes
     aliases.
  3. `external` declarations carry only `name '...'`. No `cdecl`,
     no library directive — Blaise hasn't grown that syntax yet, so
     a `--library` value is recorded as a provenance comment instead.
  4. Reserved-word collisions resolve to a `_` suffix rather than
     FPC's `&` prefix (Blaise has no `&` escape).

  Pending v1 cuts:
  * Union variant parts — Blaise has no `case Integer of`, so we
    emit only the first alternative with the others as comments.
  * Function-pointer typedef-as-procedural-type may still be too
    rich for the current Blaise parser; the emitter falls back to
    Pointer for inline use in parameter positions like FPC does. *)
unit bindgen.emit.blaise;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, bindgen.ir, bindgen.parser;

type
  TBlaiseEmitter = class
  private
    FUnitName: string;
    FLibrary: string;
    FOutput: TStringList;
    FEmittedTypes: TStringList;
    FDeclaredTypeNames: TStringList;
    FPointerAliases: TStringList;
    FOpaqueTypedefs: TStringList;
    FNeedsVaList: Boolean;
    { Blaise accepts inline `function(...): T` only at typedef RHS;
      record fields and function params must reference a named alias
      or fall back to Pointer. Flipped on inside EmitTypedef. }
    FInTypedefBody: Boolean;
    FPrefixTypes: Boolean;
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
    function  AliasPointer(const Raw: string): string;
    function  LocComment(const Loc: TSourceLoc): string;
    function  EscapeIdent(const S: string): string;
    { Like EscapeIdent, but prepends 'T' to type names when
      --prefix-types is on. Same guard as FPC/rqbasic. }
    function  TypeIdent(const S: string): string;
    function  DisambiguateIdent(const CName: string): string;
    function  PascalizeComment(const Raw: string): string;
    procedure CollectFunctionPointerAliases(U: TBindingUnit);
    procedure WalkTypeForAliases(T: TBindingType);
  public
    constructor Create(const AUnitName, ALibrary: string;
                       APrefixTypes: Boolean = False);
    destructor Destroy; override;
    function Emit(U: TBindingUnit): string;
  end;

implementation

{ Blaise reserved-word table. Conservative — overlap-heavy with
  FPC's plus a few Blaise-specific words. Names matching this list
  get a '_' suffix when emitted; Blaise has no '&Ident' escape. }
const
  BLAISE_RESERVED: array[0..77] of string = (
    'absolute','and','array','as','asm','begin','break','case',
    'class','const','constructor','continue','destructor','div','do',
    'downto','else','end','except','exit','exports','external','file',
    'finalization','finally','for','function','goto','halt','if',
    'implementation','in','inherited','initialization','inline',
    'interface','is','label','library','mod','nil','not','object',
    'of','on','operator','or','out','packed','procedure','program',
    'property','raise','record','repeat','result','resourcestring',
    'set','shl','shr','string','then','threadvar','to','try','type',
    'unit','until','uses','var','while','with','xor',
    { Blaise built-ins that aren't keywords but collide as identifiers }
    'abort','integer','boolean','pointer','pchar'
  );

constructor TBlaiseEmitter.Create(const AUnitName, ALibrary: string;
                                  APrefixTypes: Boolean);
begin
  inherited Create;
  FUnitName := AUnitName;
  FLibrary := ALibrary;
  FPrefixTypes := APrefixTypes;
  FOutput := TStringList.Create;
  FEmittedTypes := TStringList.Create;
  FEmittedTypes.Sorted := True;
  FEmittedTypes.Duplicates := dupIgnore;
  FDeclaredTypeNames := TStringList.Create;
  FDeclaredTypeNames.Sorted := True;
  FDeclaredTypeNames.Duplicates := dupIgnore;
  FPointerAliases := TStringList.Create;
  FPointerAliases.Sorted := True;
  FPointerAliases.Duplicates := dupIgnore;
  FOpaqueTypedefs := TStringList.Create;
  FOpaqueTypedefs.Sorted := True;
  FOpaqueTypedefs.Duplicates := dupIgnore;
end;

destructor TBlaiseEmitter.Destroy;
begin
  FOutput.Free;
  FEmittedTypes.Free;
  FDeclaredTypeNames.Free;
  FPointerAliases.Free;
  FOpaqueTypedefs.Free;
  inherited Destroy;
end;

{ Blaise RTL global identifiers. Surfacing at unit-interface scope
  means same-named C externs collide; DisambiguateIdent renames the
  Pascal side ('GetProcessId' -> 'GetProcessId_'), the linker symbol
  ('external name ...') stays unchanged.

  TODO(blaise upstream): when Blaise moves its RTL helpers behind a
  unit prefix (e.g. `System.WriteLn` instead of bare `WriteLn`),
  this list can be deleted entirely and DisambiguateIdent will be
  driven purely by what the binding itself declares.

  Also: when binding Windows headers the deploy target is the Win64
  RTL which has a different (likely smaller) collision set. At that
  point the list should be tightened or made target-aware.

  Built by extracting all uppercase-leading 'T'-typed symbols from
  the Blaise bootstrap RTL archive (`nm
  blaise_rtl_unit_source.a | grep ' T '`), case-folded, then unioned
  with names visible only via prebuilt .o files we discovered via
  `strings`. Case-folded comparison.

  Excluded on purpose:
  * names starting with `_` (Blaise convention for compiler builtins,
    no C library uses them)
  * `k32_*`, `libc_*`, `msvcrt_*`, `pthread_*` (Blaise's prefixed
    syscall wrappers — they don't collide with C names)
  * Blaise class types (TList, TStream...) which the FFI won't
    declare functions for }
const
  BLAISE_RTL_GLOBALS =
    '|absint|abstractmethoderror|appendfile|changefileext|checknil|chr' +
    '|currentexception|currentexceptioncxx|currentexceptionmessage' +
    '|deletefile|directoryexists|doubletostr|excludetrailingpathdelimiter' +
    '|exec|extractfiledir|extractfileext|extractfilename|extractfilepath' +
    '|fdclose|fdopenappend|fdopenread|fdopenwrite|fdread|fdseek|fdsize' +
    '|fdwrite|fileexists|forcedirectories|getcurrentdir|getenvvar|getitab' +
    '|getprocessid|gettempdir|gettempfilename|halt|hasclassattribute' +
    '|implementsinterface|includetrailingpathdelimiter|inheritsfrom' +
    '|inttostr|isinstance|methodaddress|ordat|paramcount|paramstr' +
    '|popexcframe|processaddarg|processcreate|processexecute' +
    '|processexitcode|processfree|processreadoutput|processrunning' +
    '|processsetexe|processsetnoconsole|processwaitonexit|pushexcframe' +
    '|raise|readfile|removedir|renamefile|reraise|rtlgetpathdelim' +
    '|rtlgetpathlistsep|setargs|setcurrentdir|singletostr|sleep' +
    '|stringaddref|stringcompare|stringcomparetext|stringconcat' +
    '|stringcopy|stringdelete|stringequals|stringformatn|stringfrompchar' +
    '|stringlength|stringlowercase|stringpos|stringposex|stringrelease' +
    '|stringreleasecheck|stringsametext|stringsetlength|stringtrim' +
    '|stringuppercase|strtodouble|strtoint|syswriteint|syswritenewline' +
    '|syswritestr|timedaysinmonth|timeisleapyear|timejoin' +
    '|timelocaloffsetsecs|timenow|timesplit|upcase|weakassign|weakclear' +
    '|weakzeroslots|writefile|' +
    { Compiler intrinsics — built into the codegen, not exposed in
      the RTL .a but still clash as global identifiers. }
    '|abs|assigned|chr|dec|dispose|exclude|exit|finalize|high|inc' +
    '|include|initialize|length|low|new|odd|ord|pred|round|setlength' +
    '|sizeof|sqr|sqrt|succ|trunc|typeinfo|';

function IsBlaiseRtlGlobal(const S: string): Boolean;
begin
  Result := Pos('|' + LowerCase(S) + '|', BLAISE_RTL_GLOBALS) > 0;
end;

{ Blaise built-in or RTL-provided identifiers. Used to suppress
  forward-record stubs that would shadow them, and to prevent
  spurious 'Foo = record end' next to a 'PFoo = ^Foo' pointer alias
  when 'Foo' is already a primitive. Case-insensitive. }
function IsBlaiseBuiltin(const S: string): Boolean;
var
  L: string;
begin
  L := LowerCase(S);
  Result := (L = 'pointer') or (L = 'pchar')
         or (L = 'va_list') or (L = '__va_list_tag')
         or (L = 'byte') or (L = 'word') or (L = 'smallint')
         or (L = 'integer') or (L = 'cardinal')
         or (L = 'int16') or (L = 'int64')
         or (L = 'uint16') or (L = 'uint32') or (L = 'uint64')
         or (L = 'single') or (L = 'double')
         or (L = 'boolean') or (L = 'string');
end;

{ Same case-insensitive disambiguation as the FPC emitter: when
  a function's Pascal-side name would collide with anything already
  emitted (or with the Blaise RTL's global namespace), append '_'
  to the Pascal name. The C linker symbol stays untouched via
  `external name '<original>'`. }
function TBlaiseEmitter.DisambiguateIdent(const CName: string): string;
begin
  Result := EscapeIdent(CName);
  while (FDeclaredTypeNames.IndexOf(LowerCase(Result)) >= 0)
     or (FEmittedTypes.IndexOf('fn:' + LowerCase(Result)) >= 0)
     or IsBlaiseRtlGlobal(Result) do
    Result := Result + '_';
end;

function TBlaiseEmitter.EscapeIdent(const S: string): string;
var
  I: Integer;
  Lower: string;
begin
  if S = '' then begin Result := S; Exit; end;
  Lower := LowerCase(S);
  for I := Low(BLAISE_RESERVED) to High(BLAISE_RESERVED) do
    if Lower = BLAISE_RESERVED[I] then
    begin
      Result := S + '_';
      Exit;
    end;
  Result := S;
end;

function TBlaiseEmitter.TypeIdent(const S: string): string;
begin
  Result := EscapeIdent(S);
  if not FPrefixTypes then Exit;
  if Result = '' then Exit;
  if (Length(Result) >= 2) and (Result[1] = 'T')
     and (Result[2] >= 'A') and (Result[2] <= 'Z') then
    Exit;
  Result := 'T' + Result;
end;

procedure TBlaiseEmitter.Line(const S: string);
begin
  FOutput.Add(S);
end;

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

function TBlaiseEmitter.LocComment(const Loc: TSourceLoc): string;
begin
  if Loc.FileName = '' then
    Result := ''
  else
    Result := Format('  { %s:%d }', [ExtractFileName(Loc.FileName), Loc.Line]);
end;

{ C primitive → Blaise built-in type. Width choices target the Blaise
  Linux x86_64 platform (where `long` is 64-bit). }
function TBlaiseEmitter.MapPrimitive(const Spelling: string; SizeBytes: Int64): string;
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
  { Reject any spelling that no Pascal compiler will accept. }
  if (Pos('(', S) > 0) or (Pos('__attribute', S) > 0)
     or (Pos('__vector', S) > 0) then
  begin
    Result := 'Pointer';
    Exit;
  end;
  if      S = 'void'                  then Result := ''
  else if S = 'bool'                  then Result := 'Boolean'
  else if S = '_Bool'                 then Result := 'Boolean'
  else if S = 'char'                  then Result := 'Byte'  { Blaise has no Char type; use Byte for sub-PChar use }
  else if S = 'signed char'           then Result := 'Byte'  { Blaise has no signed 8-bit type; signedness lost }
  else if S = 'unsigned char'         then Result := 'Byte'
  else if S = 'short'                 then Result := 'SmallInt'
  else if S = 'unsigned short'        then Result := 'Word'
  else if S = 'int'                   then Result := 'Integer'
  else if S = 'unsigned int'          then Result := 'Cardinal'
  else if S = 'unsigned'              then Result := 'Cardinal'
  else if S = 'long'                  then
  begin
    { LLP64 (Win64) = 4 bytes; LP64 (Linux/macOS) = 8 bytes. SizeBytes
      reflects the active clang target — defaults to LP64 for host. }
    if SizeBytes = 4 then Result := 'Integer' else Result := 'Int64';
  end
  else if S = 'unsigned long'         then
  begin
    if SizeBytes = 4 then Result := 'Cardinal' else Result := 'UInt64';
  end
  else if S = 'long long'             then Result := 'Int64'
  else if S = 'unsigned long long'    then Result := 'UInt64'
  else if S = 'float'                 then Result := 'Single'
  else if S = 'double'                then Result := 'Double'
  else if S = 'long double'           then Result := 'Double'  { Blaise lacks 80-bit }
  else Result := S;
end;

{ '^X' becomes 'PX' (with 'PX = ^X' registered); '^^X' becomes 'PPX'
  (registering both layers). Blaise rejects '^X' in parameter and
  return-type positions, so we route signatures through here. }
function TBlaiseEmitter.AliasPointer(const Raw: string): string;
var
  Pointee, InnerAlias: string;
begin
  if (Length(Raw) >= 2) and (Raw[1] = '^') then
  begin
    Pointee := Copy(Raw, 2, MaxInt);
    if (Length(Pointee) >= 1) and (Pointee[1] = '^') then
    begin
      InnerAlias := AliasPointer(Pointee);
      { Keep the P-track on bare (unprefixed) names so 'PPX = ^PX'
        reads cleanly when --prefix-types is on. }
      if FPrefixTypes and (Length(InnerAlias) >= 2)
         and (InnerAlias[1] = 'P') and (InnerAlias[2] = 'T') then
        InnerAlias := 'P' + Copy(InnerAlias, 3, MaxInt);
      Result := 'P' + InnerAlias;
      FPointerAliases.Add(InnerAlias);
    end
    else
    begin
      { Under --prefix-types, MapType returns 'TX' for any type ref;
        strip the T here so FPointerAliases stays in bare form and
        the emit loop produces 'PX = ^TX'. }
      if FPrefixTypes and (Length(Pointee) >= 1) and (Pointee[1] = 'T') then
        Pointee := Copy(Pointee, 2, MaxInt);
      Result := 'P' + Pointee;
      FPointerAliases.Add(Pointee);
    end;
  end
  else
    Result := Raw;
end;

function TBlaiseEmitter.MapTypeForSig(T: TBindingType): string;
begin
  { Inline function pointers are too rich for the Blaise parser
    in a parameter position; typedef'd ones come through as
    tkTypedefRef and stay readable. }
  if (T <> nil) and (T.Kind = tkFunctionPointer) then
  begin
    Result := 'Pointer';
    Exit;
  end;
  { C array parameter decays to a pointer at the ABI level. }
  if (T <> nil) and (T.Kind = tkArray) and (T.Pointee <> nil) then
  begin
    Result := AliasPointer('^' + MapType(T.Pointee));
    Exit;
  end;
  Result := AliasPointer(MapType(T));
end;

procedure TBlaiseEmitter.WalkTypeForAliases(T: TBindingType);
var
  J: Integer;
  Discard, RefName: string;
begin
  if T = nil then Exit;
  Discard := AliasPointer(MapType(T));
  if Discard = '' then ;
  if T.Kind = tkTypedefRef then
  begin
    RefName := T.Spelling;
    if Copy(RefName, 1, 7) = 'struct ' then Delete(RefName, 1, 7)
    else if Copy(RefName, 1, 6) = 'union '  then Delete(RefName, 1, 6)
    else if Copy(RefName, 1, 5) = 'enum '   then Delete(RefName, 1, 5);
    if Copy(RefName, 1, 6) = 'const '   then Delete(RefName, 1, 6);
    if (FDeclaredTypeNames.IndexOf(RefName) < 0)
       and (T.CanonicalSpelling = '')
       and (RefName <> '')
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

procedure TBlaiseEmitter.CollectFunctionPointerAliases(U: TBindingUnit);
var
  I, J: Integer;
  D: TBindingDecl;
  F: TBindingFunction;
  R: TBindingRecord;
  Td: TBindingTypedef;
begin
  FPointerAliases.Clear;
  FOpaqueTypedefs.Clear;
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

function TBlaiseEmitter.MapType(T: TBindingType): string;
var
  Inner: string;
  J: Integer;
  Params, Ret: string;
begin
  if T = nil then begin Result := 'Pointer'; Exit; end;
  { Pathological libclang spellings → Pointer-sized blob. }
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
          Result := 'Pointer'
        else if T.Pointee.Kind = tkPointer then
          Result := AliasPointer('^' + MapType(T.Pointee))
        else
        begin
          Inner := MapType(T.Pointee);
          { C `char *` → Blaise `PChar`. Blaise lacks Char/AnsiChar
            as standalone types, so plain `char` maps to Byte above,
            but `^char` collapses to PChar (Blaise's NUL-terminated
            string handle). }
          if (Inner = 'Byte') and (T.Pointee <> nil)
             and (T.Pointee.Kind = tkPrimitive)
             and ((Trim(T.Pointee.Spelling) = 'char')
                  or (Trim(T.Pointee.Spelling) = 'const char')) then
            Result := 'PChar'
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
        Inner := T.Spelling;
        if Copy(Inner, 1, 6) = 'const ' then Delete(Inner, 1, 6);
        if Copy(Inner, 1, 9) = 'volatile ' then Delete(Inner, 1, 9);
        if      Copy(Inner, 1, 7) = 'struct '  then Delete(Inner, 1, 7)
        else if Copy(Inner, 1, 6) = 'union '   then Delete(Inner, 1, 6)
        else if Copy(Inner, 1, 5) = 'enum '    then Delete(Inner, 1, 5);
        if (T.Kind = tkTypedefRef)
           and (FDeclaredTypeNames.IndexOf(Inner) < 0)
           and (T.CanonicalSpelling <> '') then
        begin
          if Copy(T.CanonicalSpelling, 1, 5) = 'enum ' then
            Result := 'Cardinal'   { C enum default width, Blaise spelling }
          else
            Result := MapPrimitive(T.CanonicalSpelling, T.ByteSize);
        end
        else if (T.Kind = tkEnumRef)
                and (FDeclaredTypeNames.IndexOf(Inner) < 0) then
          Result := 'Cardinal'
        else
          Result := TypeIdent(Inner);
      end;
    tkFunctionPointer:
      begin
        if not FInTypedefBody then
        begin
          { Blaise won't parse inline procedural types in record /
            field / parameter positions. Collapse to Pointer; the
            typed form survives at typedef RHS via FInTypedefBody. }
          Result := 'Pointer';
          Exit;
        end;
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
          Result := Format('procedure%s', [Params])
        else
          Result := Format('function%s: %s', [Params, Ret]);
      end;
    tkVaList:
      begin
        FNeedsVaList := True;
        Result := 'va_list';
      end;
    tkPrimitive:
      Result := MapPrimitive(T.Spelling, T.ByteSize);
  else
    Result := MapPrimitive(T.Spelling, T.ByteSize);
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
  RetType, Sig, ParamName, Modifiers, PascalName: string;
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
  Modifiers := Format('external name ''%s''', [F.Name]);
  if F.IsVarArgs then
    Modifiers := Modifiers +
      '  { varargs — Blaise has no varargs syntax yet, call via wrapper }';

  if RetType = '' then
    Sig := Format('procedure %s%s; %s;', [PascalName, Params, Modifiers])
  else
    Sig := Format('function %s%s: %s; %s;', [PascalName, Params, RetType, Modifiers]);
  FEmittedTypes.Add('fn:' + LowerCase(PascalName));

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
    { Blaise has no variant-part records. Emit the first alternative
      as the active field; surface the rest as comments. }
    Line(Format('  %s = record  { union — using first alternative; size may differ from C } %s',
                [TypeIdent(R.Name), LocComment(R.Location)]));
    if R.Fields.Count > 0 then
    begin
      F := R.Fields.Items[0];
      Line(Format('    %s: %s;', [EscapeIdent(F.Name), MapType(F.FieldType)]));
      for I := 1 to R.Fields.Count - 1 do
        Line(Format('    { alt %d: %s: %s }',
             [I, R.Fields.Items[I].Name, MapType(R.Fields.Items[I].FieldType)]));
    end;
    Line('  end;');
  end
  else
  begin
    Line(Format('  %s = record%s', [TypeIdent(R.Name), LocComment(R.Location)]));
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

procedure TBlaiseEmitter.EmitEnum(E: TBindingEnum);
var
  Underlying: string;
begin
  if E.RawComment <> '' then Line(PascalizeComment(E.RawComment));
  if E.UnderlyingType <> nil then
    Underlying := MapType(E.UnderlyingType)
  else
    Underlying := 'Integer';
  if Underlying = '' then Underlying := 'Integer';
  Line(Format('  %s = %s;%s', [TypeIdent(E.Name), Underlying, LocComment(E.Location)]));
  { Constants are batched into a single const block emitted after
    the entire type section closes — keeps forward type refs
    resolvable across the section. }
end;

procedure TBlaiseEmitter.EmitTypedef(T: TBindingTypedef);
var
  Aliased: string;
begin
  if T.RawComment <> '' then Line(PascalizeComment(T.RawComment));
  FInTypedefBody := True;
  try
    Aliased := MapType(T.Aliased);
  finally
    FInTypedefBody := False;
  end;
  if Aliased = '' then Aliased := 'Pointer';
  { Vacuous self-typedef ('typedef struct X X;') — skip. Pascal is
    case-insensitive, so compare lowered. }
  { Vacuous self-typedef — also catches the case where --prefix-types
    has T-prefixed both sides ('TX = TX;'). }
  if LowerCase(Aliased) = LowerCase(TypeIdent(T.Name)) then Exit;
  if LowerCase(Aliased) = LowerCase(T.Name) then Exit;
  Line(Format('  %s = %s;%s', [TypeIdent(T.Name), Aliased, LocComment(T.Location)]));
end;

procedure TBlaiseEmitter.EmitMacro(M: TBindingMacroConst);
begin
  if M.RawComment <> '' then Line(PascalizeComment(M.RawComment));
  Line(Format('  %s = %s;%s', [EscapeIdent(M.Name), M.RawValue, LocComment(M.Location)]));
end;

{ True when the macro's literal won't parse in Blaise. Right now
  the only known case is hex literals > Int64 (FPC accepts QWord
  literally; Blaise's lexer rejects them). }
function BlaiseRejectsMacro(const RawValue: string): Boolean;
begin
  Result := ExceedsInt64Hex(RawValue);
end;

procedure TBlaiseEmitter.EmitDecl(D: TBindingDecl);
begin
  if D is TBindingFunction then
  begin
    { Multiple FunctionDecl cursors with the same exact C name are
      redeclarations; emit only the first. RTL/type-name collisions
      are handled inside EmitFunction by '_' suffix renaming. }
    if FEmittedTypes.IndexOf('cfn:' + D.Name) >= 0 then Exit;
    FEmittedTypes.Add('cfn:' + D.Name);
    EmitFunction(TBindingFunction(D));
    Exit;
  end;
  if (Pos('(', D.Name) > 0) or (Pos(' ', D.Name) > 0)
     or (Pos('__WIDL_', D.Name) > 0) then
    Exit;
  { Blaise built-ins are case-folded; if a header re-typedefs one
    of them (`typedef short INT16;`), Blaise sees a duplicate and
    rejects the unit. Skip the redeclaration. }
  if IsBlaiseBuiltin(D.Name) then Exit;
  { Vacuous self-typedef — don't claim the name in FEmittedTypes so
    a later StructDecl can still emit. }
  if (D is TBindingTypedef)
     and (LowerCase(MapType(TBindingTypedef(D).Aliased)) = LowerCase(D.Name)) then
    Exit;
  if FEmittedTypes.IndexOf(D.Name) >= 0 then Exit;
  FEmittedTypes.Add(D.Name);
  if      D is TBindingRecord  then EmitRecord(TBindingRecord(D))
  else if D is TBindingEnum    then EmitEnum(TBindingEnum(D))
  else if D is TBindingTypedef then EmitTypedef(TBindingTypedef(D));
end;

function TBlaiseEmitter.Emit(U: TBindingUnit): string;
var
  I, J: Integer;
  D: TBindingDecl;
  HasTypes, HasFuncs, HasMacros: Boolean;
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
    if (D is TBindingTypedef)
       and (LowerCase(MapType(TBindingTypedef(D).Aliased)) = LowerCase(D.Name)) then
      Continue;
    FDeclaredTypeNames.Add(D.Name);
  end;
  CollectFunctionPointerAliases(U);
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
  if HasMacros then ;  { used below — silence stale-var warning }

  if HasTypes or (FPointerAliases.Count > 0) or (FOpaqueTypedefs.Count > 0)
     or FNeedsVaList then
  begin
    Line('type');
    { Platform-aware va_list. Blaise currently targets only Linux
      x86_64, so the SysV layout is what we emit. }
    if FNeedsVaList then
    begin
      FEmittedTypes.Add('va_list');
      FEmittedTypes.Add('__va_list_tag');
      Line('  __va_list_tag = record');
      Line('    gp_offset: Cardinal;');
      Line('    fp_offset: Cardinal;');
      Line('    overflow_arg_area: Pointer;');
      Line('    reg_save_area: Pointer;');
      Line('  end;');
      Line('  va_list = array[0..0] of __va_list_tag;');
    end;
    { Opaque stubs for typedef-ref names that reference system-header
      types we never declared. }
    for I := 0 to FOpaqueTypedefs.Count - 1 do
      if FDeclaredTypeNames.IndexOf(FOpaqueTypedefs[I]) < 0 then
        Line(Format('  %s = Pointer;  { opaque — layout unknown, assumed pointer-shaped }',
                    [TypeIdent(FOpaqueTypedefs[I])]));
    { Synthesized 'P<X> = ^X' aliases — emit forward-record stubs for
      pointee names we don't otherwise declare. }
    if FPointerAliases.Count > 0 then
    begin
      for I := 0 to FPointerAliases.Count - 1 do
      begin
        if FDeclaredTypeNames.IndexOf(FPointerAliases[I]) >= 0 then Continue;
        if FOpaqueTypedefs.IndexOf(FPointerAliases[I]) >= 0 then Continue;
        if IsBlaiseBuiltin(FPointerAliases[I]) then Continue;
        if (Length(FPointerAliases[I]) >= 2)
           and (FPointerAliases[I][1] = 'P')
           and (FPointerAliases.IndexOf(Copy(FPointerAliases[I], 2, MaxInt)) >= 0)
           then Continue;
        if (Pos('(', FPointerAliases[I]) > 0)
           or (Pos(')', FPointerAliases[I]) > 0)
           or (Pos(',', FPointerAliases[I]) > 0)
           or (Pos(' ', FPointerAliases[I]) > 0)
           or (Pos('*', FPointerAliases[I]) > 0)
           or (Pos('__va_list_tag', FPointerAliases[I]) > 0)
           or (Copy(FPointerAliases[I], 1, 2) = '__') then Continue;
        Line(Format('  %s = record end;', [TypeIdent(FPointerAliases[I])]));
      end;
      for I := 0 to FPointerAliases.Count - 1 do
      begin
        if (Pos('(', FPointerAliases[I]) > 0)
           or (Pos(')', FPointerAliases[I]) > 0)
           or (Pos(',', FPointerAliases[I]) > 0)
           or (Pos(' ', FPointerAliases[I]) > 0)
           or (Pos('*', FPointerAliases[I]) > 0)
           or (Pos('__va_list_tag', FPointerAliases[I]) > 0) then Continue;
        if FDeclaredTypeNames.IndexOf('P' + FPointerAliases[I]) >= 0 then
          Continue;
        Line(Format('  P%s = ^%s;',
                    [FPointerAliases[I], TypeIdent(FPointerAliases[I])]));
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

  { #define integer constants + enum constants share a single
    const block at the end of the type section so the type section
    stays unbroken (forward 'PX' refs would otherwise fail to
    resolve across an intervening const section). }
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
    { Case-insensitive dedup — Pascal-side identifiers collide
      under case folding (GDK_KEY_a vs GDK_KEY_A and similar). }
    FEmittedTypes.Clear;
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if D is TBindingMacroConst then
      begin
        if FEmittedTypes.IndexOf(LowerCase(D.Name)) >= 0 then Continue;
        if BlaiseRejectsMacro(TBindingMacroConst(D).RawValue) then Continue;
        FEmittedTypes.Add(LowerCase(D.Name));
        { Reserve so a same-named function (windows.h's STRETCHBLT
          const vs StretchBlt API) renames the function side. }
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
