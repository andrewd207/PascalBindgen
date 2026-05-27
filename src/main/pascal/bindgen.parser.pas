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
function BuildType(T: TClangType): TBindingType;
var
  K: Integer;
  Spelling: string;
  Sub: TClangType;
begin
  K := T.Kind;
  Spelling := T.Spelling;
  if K = TClangTypeKinds.Pointer_ then
  begin
    Result := TBindingType.Create(tkPointer, Spelling);
    Sub := T.Pointee;
    try
      Result.Pointee := BuildType(Sub);
    finally
      Sub.Free;
    end;
  end
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
    { "struct Foo" / "enum Bar" / typedef-of-anything form — unwrap
      to the underlying. Preserve the user-facing spelling for refs
      (so 'struct Point' stays as the tag 'Point'), but let
      canonical primitives keep their canonical name so MapPrimitive
      can map them ('size_t' canonical is 'unsigned long' → culong). }
    Sub := T.Canonical;
    try
      Result := BuildType(Sub);
      if Result.Kind in [tkRecordRef, tkEnumRef, tkTypedefRef] then
        Result.Spelling := Spelling;
    finally
      Sub.Free;
    end;
  end
  else
    Result := TBindingType.Create(tkPrimitive, Spelling);
end;

function BuildFunction(C: TClangCursor): TBindingFunction;
var
  FT, RT, AT: TClangType;
  Kids: TClangCursorArray;
  K: TClangCursor;
  I, ParamIdx: Integer;
  Param: TBindingParam;
begin
  Result := TBindingFunction.Create(C.Spelling, CursorLoc(C));
  Result.CallingConv := ccCdecl;  { refine when CXCallingConv shim lands }
  AttachComment(Result, C);
  FT := C.TypeOf;
  try
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
          if Child.InSystemHeader then Continue;
          K := Child.Kind;
          Decl := nil;
          if K = TClangKinds.FunctionDecl then
            Decl := BuildFunction(Child)
          else if K = TClangKinds.TypedefDecl then
            Decl := BuildTypedef(Child)
          else if K = TClangKinds.StructDecl then
            Decl := BuildRecord(Child, False)
          else if K = TClangKinds.UnionDecl then
            Decl := BuildRecord(Child, True)
          else if K = TClangKinds.EnumDecl then
            Decl := BuildEnum(Child)
          else
            Continue;
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
