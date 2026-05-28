{ bindgen.parser — drives libclang and populates a TBindingUnit.

  Scope of this first pass
  ------------------------
  * Top-level decls from the main header *and* any user-side
    #include — anything libclang does NOT classify as a system
    header (clang_Location_isInSystemHeader). This is wider than
    the original main-file-only filter so that real-world headers
    like zlib.h pull in their zconf.h typedef vocabulary.
  * Functions, typedefs, structs/unions, enums. No fields-of-structs,
    no enum-constant values, no type info beyond a spelling placeholder
    yet — those land in follow-on passes once the shim exposes CXType.
  * Macros are skipped with a LossReason; the shim turns off
    DetailedPreprocessingRecord so they don't show up here anyway. }
unit bindgen.parser;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, clang.wrap, bindgen.ir;

{ Parse a header into a fresh TBindingUnit. ExtraArgs are clang
  command-line args (`-I...`, `-D...`, etc.). Caller owns the
  result and must Free it.

  Plain function rather than a `class function` on a holder type
  because Blaise does not yet parse `class function` / `class
  procedure`. }
function ParseHeader(const HeaderPath: string;
                     const ExtraArgs: array of string): TBindingUnit; overload;
{ True for hex literals beyond signed Int64 ('$8000000000000000' and
  larger). FPC parses these as QWord; Blaise's lexer doesn't. }
function ExceedsInt64Hex(const Lit: string): Boolean;
{ Convenience overload — Blaise rejects empty array literals at call sites. }
function ParseHeader(const HeaderPath: string): TBindingUnit; overload;

implementation

function CursorLoc(C: TClangCursor): TSourceLoc;
var
  FN: string;
  Line, Col: Cardinal;
begin
  C.Location(FN, Line, Col);
  Result := MakeLoc(FN, Line, Col);
end;

procedure AttachComment(D: TBindingDecl; C: TClangCursor);
begin
  D.RawComment := C.RawComment;
end;

{ Translate a TClangType into the dialect-neutral TBindingType. The
  input is borrowed; result is heap-allocated and owned by the caller. }
function BuildType(T: TClangType): TBindingType; forward;

{ Build a tkFunctionPointer from a FunctionProto-kind type. The proto
  itself supplies the return type and argument types; parameter names
  are not part of the prototype (libclang exposes them only on
  ParmDecl children of a FunctionDecl, not on bare function types). }
function BuildFunctionProto(T: TClangType; const Spelling: string): TBindingType;
var
  RT, AT: TClangType;
  N, I: Integer;
begin
  Result := TBindingType.Create(tkFunctionPointer, Spelling);
  Result.FuncParams := TBindingTypeList.Create;
  RT := T.ResultType;
  try
    Result.FuncReturn := BuildType(RT);
  finally
    RT.Free;
  end;
  N := T.NumArgs;
  for I := 0 to N - 1 do
  begin
    AT := T.Arg(I);
    try
      Result.FuncParams.Add(BuildType(AT));
    finally
      AT.Free;
    end;
  end;
end;

function BuildType(T: TClangType): TBindingType;
var
  K: Integer;
  Spelling: string;
  Sub, Canon: TClangType;
begin
  K := T.Kind;
  Spelling := T.Spelling;
  { Detect va_list early — it survives in many shapes (typedef of an
    array of __va_list_tag, builtin opaque, ...). Collapse them all
    to a single tkVaList marker so the emitter can route through a
    platform-aware typedef. }
  if (Pos('__va_list_tag', Spelling) > 0)
     or (Pos('__builtin_va_list', Spelling) > 0)
     or (Spelling = 'va_list') then
  begin
    Result := TBindingType.Create(tkVaList, 'va_list');
    Exit;
  end;
  if K = TClangTypeKinds.Pointer_ then
  begin
    { Pointer-to-function: collapse 'T (*)(args)' into tkFunctionPointer
      so the emitter can render a Pascal procedural type instead of
      'function(...)' garbage from the C spelling. }
    Sub := T.Pointee;
    try
      Canon := Sub.Canonical;
      try
        if Canon.Kind = TClangTypeKinds.FunctionProto then
        begin
          Result := BuildFunctionProto(Canon, Spelling);
          Exit;
        end;
      finally
        Canon.Free;
      end;
    finally
      Sub.Free;
    end;
    Result := TBindingType.Create(tkPointer, Spelling);
    Sub := T.Pointee;
    try
      Result.Pointee := BuildType(Sub);
    finally
      Sub.Free;
    end;
  end
  else if K = TClangTypeKinds.FunctionProto then
    Result := BuildFunctionProto(T, Spelling)
  else if (K = TClangTypeKinds.ConstantArray) or
          (K = TClangTypeKinds.IncompleteArray) then
  begin
    Result := TBindingType.Create(tkArray, Spelling);
    if K = TClangTypeKinds.ConstantArray then
      Result.ArraySize := T.ArraySize
    else
      Result.ArraySize := -1;
    Sub := T.ArrayElement;
    try
      Result.Pointee := BuildType(Sub);
    finally
      Sub.Free;
    end;
  end
  else if K = TClangTypeKinds.Record_ then
    Result := TBindingType.Create(tkRecordRef, Spelling)
  else if K = TClangTypeKinds.Enum then
    Result := TBindingType.Create(tkEnumRef, Spelling)
  else if K = TClangTypeKinds.Typedef then
  begin
    Result := TBindingType.Create(tkTypedefRef, Spelling);
    { Capture canonical primitive spelling so the FPC emitter can
      fall back when the typedef itself is filtered out as a
      system-header decl (e.g. 'z_size_t = size_t' where size_t
      lives in <stddef.h>). }
    Sub := T.Canonical;
    try
      if Sub.Kind <> TClangTypeKinds.Record_ then
        Result.CanonicalSpelling := Sub.Spelling;
    finally
      Sub.Free;
    end;
  end
  else if K = TClangTypeKinds.Elaborated then
  begin
    { "struct Foo" / "enum Bar" / typedef-of-anything. If the spelling
      is a bare identifier (no space, no asterisk) it names a typedef
      directly — model it as tkTypedefRef and skip canonicalization,
      which would otherwise unfold a function-pointer typedef into an
      inline procedural type. Only when the spelling carries a
      'struct '/'union '/'enum ' tag or other adornment do we need to
      chase the canonical for the underlying record/enum/primitive. }
    if (Spelling <> '') and (Pos(' ', Spelling) = 0)
       and (Pos('*', Spelling) = 0) then
    begin
      Result := TBindingType.Create(tkTypedefRef, Spelling);
      { Capture canonical primitive for the fallback-when-undeclared
        path — same rule as the bare-Typedef branch above. }
      Sub := T.Canonical;
      try
        if (Sub.Kind <> TClangTypeKinds.Record_)
           and (Sub.Kind <> TClangTypeKinds.FunctionProto)
           and (Sub.Kind <> TClangTypeKinds.Pointer_) then
          Result.CanonicalSpelling := Sub.Spelling;
      finally
        Sub.Free;
      end;
    end
    else
    begin
      Sub := T.Canonical;
      try
        Result := BuildType(Sub);
        if Result.Kind in [tkRecordRef, tkEnumRef, tkTypedefRef] then
          Result.Spelling := Spelling;
      finally
        Sub.Free;
      end;
    end;
  end
  else
  begin
    Result := TBindingType.Create(tkPrimitive, Spelling);
    Result.ByteSize := T.SizeOf;
  end;
end;

function ContainsVaList(T: TClangType): Boolean;
var
  Spell: string;
begin
  Spell := T.Spelling;
  Result := (Pos('__va_list_tag', Spell) > 0)
            or (Pos('__builtin_va_list', Spell) > 0)
            or (Pos('va_list', Spell) > 0);
end;

function BuildFunction(C: TClangCursor): TBindingFunction;
var
  FT, RT, AT: TClangType;
  Kids: TClangCursorArray;
  K: TClangCursor;
  I, ParamIdx, NA: Integer;
  Param: TBindingParam;
  HasVaList: Boolean;
begin
  Result := TBindingFunction.Create(C.Spelling, CursorLoc(C));
  Result.CallingConv := ccCdecl;  { refine when CXCallingConv shim lands }
  AttachComment(Result, C);
  FT := C.TypeOf;
  try
    { va_list-bearing signatures used to be dropped wholesale. Now
      we keep them — BuildType collapses any va_list spelling to a
      single tkVaList marker, and the emitter renders it via a
      unit-local platform-aware typedef. The flag below is kept for
      LossReason annotation only. }
    HasVaList := False;
    NA := FT.NumArgs;
    for I := 0 to NA - 1 do
    begin
      AT := FT.Arg(I);
      try
        if ContainsVaList(AT) then HasVaList := True;
      finally
        AT.Free;
      end;
      if HasVaList then Break;
    end;
    if HasVaList then
      Result.LossReason :=
        'takes a va_list — caller must pass an already-held va_list; '
        + 'construction in Pascal needs target-aware helpers (see '
        + 'bindgen_helpers.pas)';
    RT := FT.ResultType;
    try
      Result.ReturnType := BuildType(RT);
    finally
      RT.Free;
    end;
    Result.IsVarArgs := FT.IsVariadic;
    { Param *names* come from ParmDecl children; param *types* come from
      FT.Arg(i) so anonymous params still get typed. }
    Kids := CursorChildren(C);
    try
      ParamIdx := 0;
      for I := 0 to High(Kids) do
        if Kids[I].Kind = TClangKinds.ParmDecl then
        begin
          AT := FT.Arg(ParamIdx);
          try
            Param := TBindingParam.Create(
              Kids[I].Spelling,
              BuildType(AT),
              AT.IsConstQualified);
          finally
            AT.Free;
          end;
          Result.Params.Add(Param);
          Inc(ParamIdx);
        end;
    finally
      for I := 0 to High(Kids) do begin K := Kids[I]; K.Free; end;
    end;
  finally
    FT.Free;
  end;
end;

function BuildTypedef(C: TClangCursor): TBindingTypedef;
var
  UT: TClangType;
begin
  Result := TBindingTypedef.Create(C.Spelling, CursorLoc(C));
  AttachComment(Result, C);
  UT := C.TypedefUnderlying;
  try
    Result.Aliased := BuildType(UT);
  finally
    UT.Free;
  end;
end;

function BuildRecord(C: TClangCursor; IsUnion: Boolean): TBindingRecord;
var
  Kids: TClangCursorArray;
  K: TClangCursor;
  I: Integer;
  FT: TClangType;
  Field: TBindingField;
begin
  Result := TBindingRecord.Create(C.Spelling, CursorLoc(C), IsUnion);
  AttachComment(Result, C);
  Kids := CursorChildren(C);
  try
    for I := 0 to High(Kids) do
      if Kids[I].Kind = TClangKinds.FieldDecl then
      begin
        FT := Kids[I].TypeOf;
        try
          Field := TBindingField.Create(Kids[I].Spelling, BuildType(FT));
        finally
          FT.Free;
        end;
        Field.BitWidth := Kids[I].FieldBitWidth;
        Result.Fields.Add(Field);
      end;
  finally
    for I := 0 to High(Kids) do begin K := Kids[I]; K.Free; end;
  end;
end;

function BuildEnum(C: TClangCursor): TBindingEnum;
var
  IT: TClangType;
  Kids: TClangCursorArray;
  K: TClangCursor;
  I: Integer;
begin
  Result := TBindingEnum.Create(C.Spelling, CursorLoc(C));
  AttachComment(Result, C);
  IT := C.EnumIntegerType;
  try
    Result.UnderlyingType := BuildType(IT);
  finally
    IT.Free;
  end;
  Kids := CursorChildren(C);
  try
    for I := 0 to High(Kids) do
      if Kids[I].Kind = TClangKinds.EnumConstant then
        Result.Constants.Add(TBindingEnumConst.Create(
          Kids[I].Spelling, Kids[I].EnumConstantValue));
  finally
    for I := 0 to High(Kids) do begin K := Kids[I]; K.Free; end;
  end;
end;

{ Recognize a single integer-literal C token: optional minus sign,
  then 0x/0X-prefixed hex digits OR decimal digits, then optional
  C integer suffix (u, l, ll, ul, ull, etc., in either case). Output
  Pascal-compatible literal in OutLit ('$FF' for hex, decimal as-is). }
function TryParseIntegerLiteral(const Tok: string; out OutLit: string): Boolean;
var
  S: string;
  I, Lo, Hi: Integer;
  IsHex: Boolean;
  Sign: string;
  Body, Suffix: string;
  C: Char;
begin
  Result := False;
  S := Trim(Tok);
  if S = '' then Exit;
  Sign := '';
  if (S[1] = '-') or (S[1] = '+') then
  begin
    if S[1] = '-' then Sign := '-';
    Delete(S, 1, 1);
    if S = '' then Exit;
  end;
  IsHex := False;
  Lo := 1;
  if (Length(S) >= 2) and (S[1] = '0') and ((S[2] = 'x') or (S[2] = 'X')) then
  begin
    IsHex := True;
    Lo := 3;
  end;
  { Scan body (digits) up to optional suffix. }
  Hi := Lo - 1;
  for I := Lo to Length(S) do
  begin
    C := S[I];
    if IsHex then
    begin
      if ((C >= '0') and (C <= '9')) or ((C >= 'a') and (C <= 'f'))
         or ((C >= 'A') and (C <= 'F')) then
        Hi := I
      else
        Break;
    end
    else
    begin
      if (C >= '0') and (C <= '9') then
        Hi := I
      else
        Break;
    end;
  end;
  if Hi < Lo then Exit;  { no digits }
  Body := Copy(S, Lo, Hi - Lo + 1);
  Suffix := Copy(S, Hi + 1, MaxInt);
  { Validate suffix is only u/U/l/L characters. }
  for I := 1 to Length(Suffix) do
  begin
    C := Suffix[I];
    if not ((C = 'u') or (C = 'U') or (C = 'l') or (C = 'L')) then
      Exit;
  end;
  if IsHex then
    OutLit := Sign + '$' + Body
  else
    OutLit := Sign + Body;
  Result := True;
end;

{ A hex literal that exceeds signed Int64 range. FPC parses these
  fine as QWord; Blaise's lexer rejects anything > $7FFFFFFFFFFFFFFF
  regardless of target type. Used by the Blaise emitter to drop
  affected macros. }
function ExceedsInt64Hex(const Lit: string): Boolean;
var
  S: string;
begin
  Result := False;
  S := Lit;
  if (Length(S) >= 1) and ((S[1] = '-') or (S[1] = '+')) then
    Delete(S, 1, 1);
  if (Length(S) < 2) or (S[1] <> '$') then Exit;
  Delete(S, 1, 1);
  if Length(S) > 16 then begin Result := True; Exit; end;
  if Length(S) = 16 then
    Result := (S[1] > '7');  { '8'..'9', 'A'..'F' all > '7' }
end;

function BuildMacro(C: TClangCursor): TBindingMacroConst;
var
  Body, Lit, FN: string;
  Line, Col: Cardinal;
begin
  Result := nil;
  { Reject builtin / command-line macros: they have no source file. }
  C.Location(FN, Line, Col);
  if FN = '' then Exit;
  Body := C.MacroBody;
  if Body = '' then Exit;
  { Single token only — reject anything with internal whitespace
    (we joined tokens with LF). Parenthesized / shifted / arithmetic
    expressions stay deferred. }
  if Pos(#10, Body) > 0 then Exit;
  if not TryParseIntegerLiteral(Body, Lit) then Exit;
  Result := TBindingMacroConst.Create(C.Spelling, CursorLoc(C));
  Result.RawValue := Lit;
  Result.MacroKind := mkInteger;
  AttachComment(Result, C);
end;

{ Internal: walk a parsed TU and populate the binding unit. Both
  ParseHeader overloads route through here so the AST-walking logic
  stays in one place. The TU is *owned* by this routine. }
function ParseFromTU(TU: TClangTranslationUnit;
                     const HeaderPath: string): TBindingUnit;
var
  Root: TClangCursor;
  Children: TClangCursorArray;
  Child: TClangCursor;
  K: Integer;
  Decl: TBindingDecl;
  I: Integer;
begin
  Result := TBindingUnit.Create;
  Result.AddHeader(HeaderPath);
  try
    Root := TU.RootCursor;
    try
      Children := CursorChildren(Root);
      try
        for I := 0 to High(Children) do
        begin
          Child := Children[I];
          { Skip system-header decls (stddef/stdint guts, glibc
            internals) unless the cursor is in the actual main file —
            that lets headers living under /usr/include themselves
            (EGL/egl.h, GL/gl.h, ...) be the target without losing
            all their top-level decls. }
          if Child.InSystemHeader and not Child.InMainFile then Continue;
          K := Child.Kind;
          Decl := nil;
          if K = TClangKinds.FunctionDecl then
          begin
            Decl := BuildFunction(Child);
            if Decl = nil then Continue;
          end
          else if K = TClangKinds.TypedefDecl then
            Decl := BuildTypedef(Child)
          else if K = TClangKinds.StructDecl then
            Decl := BuildRecord(Child, False)
          else if K = TClangKinds.UnionDecl then
            Decl := BuildRecord(Child, True)
          else if K = TClangKinds.EnumDecl then
            Decl := BuildEnum(Child)
          else if K = TClangKinds.MacroDef then
            Decl := BuildMacro(Child)
          else
            Continue;
          if Decl = nil then Continue;
          Result.Decls.Add(Decl);
        end;
      finally
        for I := 0 to High(Children) do begin
          Child := Children[I]; Child.Free; end;
      end;
    finally
      Root.Free;
    end;
  finally
    TU.Free;
  end;
end;

function ParseHeader(const HeaderPath: string;
                     const ExtraArgs: array of string): TBindingUnit;
var
  Idx: TClangIndex;
begin
  Idx := TClangIndex.Create(False, False);
  try
    Result := ParseFromTU(Idx.Parse(HeaderPath, ExtraArgs), HeaderPath);
  finally
    Idx.Free;
  end;
end;

function ParseHeader(const HeaderPath: string): TBindingUnit;
var
  Idx: TClangIndex;
begin
  Idx := TClangIndex.Create(False, False);
  try
    Result := ParseFromTU(Idx.ParseNoArgs(HeaderPath), HeaderPath);
  finally
    Idx.Free;
  end;
end;

end.
