{ bindgen.parser — drives libclang and populates a TBindingUnit.

  Scope of this first pass
  ------------------------
  * Only top-level decls whose location is in the main header
    (clang_Location_isFromMainFile) — no system-header leakage.
  * Functions, typedefs, structs/unions, enums. No fields-of-structs,
    no enum-constant values, no type info beyond a spelling placeholder
    yet — those land in follow-on passes once the shim exposes CXType.
  * Macros are skipped with a LossReason; the shim turns off
    DetailedPreprocessingRecord so they don't show up here anyway. }
unit bindgen.parser;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, clang.wrap, bindgen.ir;

type
  TBindgenParser = class
  public
    { Parse a header into a fresh TBindingUnit. ExtraArgs are clang
      command-line args (`-I...`, `-D...`, etc.). Caller owns the
      result and must Free it. }
    class function ParseHeader(const HeaderPath: string;
                               const ExtraArgs: array of string): TBindingUnit;
  end;

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

function BuildFunction(C: TClangCursor): TBindingFunction;
begin
  Result := TBindingFunction.Create(C.Spelling, CursorLoc(C));
  Result.CallingConv := ccCdecl;  { default; will refine when CXType shim lands }
  AttachComment(Result, C);
end;

function BuildTypedef(C: TClangCursor): TBindingTypedef;
begin
  Result := TBindingTypedef.Create(C.Spelling, CursorLoc(C));
  AttachComment(Result, C);
end;

function BuildRecord(C: TClangCursor; IsUnion: Boolean): TBindingRecord;
begin
  Result := TBindingRecord.Create(C.Spelling, CursorLoc(C), IsUnion);
  AttachComment(Result, C);
end;

function BuildEnum(C: TClangCursor): TBindingEnum;
begin
  Result := TBindingEnum.Create(C.Spelling, CursorLoc(C));
  AttachComment(Result, C);
end;

class function TBindgenParser.ParseHeader(const HeaderPath: string;
                                          const ExtraArgs: array of string): TBindingUnit;
var
  Idx: TClangIndex;
  TU: TClangTranslationUnit;
  Root: TClangCursor;
  Children: TClangCursorArray;
  Child: TClangCursor;
  K: Integer;
  Decl: TBindingDecl;
  I: Integer;
begin
  Result := TBindingUnit.Create;
  Result.AddHeader(HeaderPath);
  Idx := TClangIndex.Create(False, False);
  try
    TU := Idx.Parse(HeaderPath, ExtraArgs);
    try
      Root := TU.RootCursor;
      try
        Children := Root.Children;
        try
          for I := 0 to High(Children) do
          begin
            Child := Children[I];
            if not Child.InMainFile then Continue;
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
              Continue;  { unhandled kind, skip for v1 }
            Result.Decls.Add(Decl);
          end;
        finally
          for I := 0 to High(Children) do
            Children[I].Free;
        end;
      finally
        Root.Free;
      end;
    finally
      TU.Free;
    end;
  finally
    Idx.Free;
  end;
end;

end.
