program TestRunner;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner,
  bindgen.ir, bindgen.parser, clang.wrap;

type
  TIRTests = class(TTestCase)
  published
    procedure FunctionDeclCarriesNameAndLocation;
    procedure RecordKnowsItsUnionness;
    procedure EnumStartsWithNoConstants;
    procedure UnitOwnsItsDecls;
  end;

  TParserTests = class(TTestCase)
  private
    function SampleHeader: string;
    function Parse: TBindingUnit;
    function FindByName(U: TBindingUnit; const N: string): TBindingDecl;
  published
    procedure ExtractsExpectedTopLevelDecls;
    procedure FiltersOutSystemHeaderDecls;
    procedure CapturesDoxygenCommentVerbatim;
    procedure FunctionAddHasIntReturnAndTwoIntParams;
    procedure FunctionGreetHasConstCharPointerParam;
    procedure StructPointHasTwoIntFields;
    procedure EnumColorHasThreeConsecutiveConstants;
    procedure TypedefMyIntAliasesInt;
  end;

  TClangTypeTests = class(TTestCase)
  private
    function FindCursor(Idx: TClangIndex; const Header, Spelling: string;
                        Kind: Integer): TClangCursor;
  published
    procedure FunctionReturnTypeIsInt;
    procedure FunctionParamCountMatches;
    procedure VariadicDetected;
    procedure ConstParamQualified;
  end;

procedure TIRTests.FunctionDeclCarriesNameAndLocation;
var
  F: TBindingFunction;
begin
  F := TBindingFunction.Create('add', MakeLoc('a.h', 12, 1));
  try
    AssertEquals('name', 'add', F.Name);
    AssertEquals('file', 'a.h', F.Location.FileName);
    AssertEquals('line', 12, F.Location.Line);
  finally
    F.Free;
  end;
end;

procedure TIRTests.RecordKnowsItsUnionness;
var
  S, U: TBindingRecord;
begin
  S := TBindingRecord.Create('S', MakeLoc('x', 1, 1), False);
  U := TBindingRecord.Create('U', MakeLoc('x', 1, 1), True);
  try
    AssertFalse('struct is not union', S.IsUnion);
    AssertTrue('union is union', U.IsUnion);
  finally
    S.Free;
    U.Free;
  end;
end;

procedure TIRTests.EnumStartsWithNoConstants;
var
  E: TBindingEnum;
begin
  E := TBindingEnum.Create('E', MakeLoc('x', 1, 1));
  try
    AssertEquals('no constants on fresh enum', 0, E.Constants.Count);
  finally
    E.Free;
  end;
end;

procedure TIRTests.UnitOwnsItsDecls;
var
  U: TBindingUnit;
begin
  U := TBindingUnit.Create;
  try
    U.Decls.Add(TBindingTypedef.Create('foo', MakeLoc('x', 1, 1)));
    U.Decls.Add(TBindingTypedef.Create('bar', MakeLoc('x', 2, 1)));
    AssertEquals('decl count', 2, U.Decls.Count);
    { destruction must not double-free; the OwnsObjects=True list will
      free each decl — verified by this test running without a SIGSEGV. }
  finally
    U.Free;
  end;
end;

function TParserTests.SampleHeader: string;
const
  Candidates: array[0..3] of string = (
    'sample.h',                          { pasbuild copies it here }
    'src/test/resources/sample.h',       { from repo root }
    '../src/test/resources/sample.h',    { from target/ }
    '../../src/test/resources/sample.h'  { from target/units/ }
  );
var
  I: Integer;
begin
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then
    begin
      Result := Candidates[I];
      Exit;
    end;
  Result := Candidates[0];  { caller will get a clang parse-failure }
end;

function TParserTests.Parse: TBindingUnit;
begin
  Result := TBindgenParser.ParseHeader(SampleHeader, []);
end;

procedure TParserTests.ExtractsExpectedTopLevelDecls;
var
  U: TBindingUnit;
  I, NFunc, NTypedef, NStruct, NUnion, NEnum: Integer;
  D: TBindingDecl;
begin
  U := Parse;
  try
    NFunc := 0; NTypedef := 0; NStruct := 0; NUnion := 0; NEnum := 0;
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls[I];
      if D is TBindingFunction then Inc(NFunc)
      else if D is TBindingTypedef then Inc(NTypedef)
      else if D is TBindingRecord then
        if TBindingRecord(D).IsUnion then Inc(NUnion)
        else Inc(NStruct)
      else if D is TBindingEnum then Inc(NEnum);
    end;
    AssertEquals('functions',  2, NFunc);
    AssertEquals('typedefs',   2, NTypedef);  { Point + my_int_t }
    AssertEquals('structs',    1, NStruct);
    AssertEquals('unions',     1, NUnion);
    AssertEquals('enums',      1, NEnum);
  finally
    U.Free;
  end;
end;

procedure TParserTests.FiltersOutSystemHeaderDecls;
var
  U: TBindingUnit;
  I: Integer;
  D: TBindingDecl;
begin
  U := Parse;
  try
    { No decl's location should live outside the sample header.
      A regression where the main-file filter breaks would flood the
      unit with stddef/stdint guts. }
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls[I];
      AssertTrue('decl ' + D.Name + ' came from sample.h, not ' + D.Location.FileName,
                 Pos('sample.h', D.Location.FileName) > 0);
    end;
  finally
    U.Free;
  end;
end;

procedure TParserTests.CapturesDoxygenCommentVerbatim;
var
  U: TBindingUnit;
  I: Integer;
  D: TBindingDecl;
  PointStruct: TBindingRecord;
begin
  U := Parse;
  try
    PointStruct := nil;
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls[I];
      if (D is TBindingRecord) and (D.Name = 'Point') then
        PointStruct := TBindingRecord(D);
    end;
    AssertNotNull('struct Point present', PointStruct);
    AssertTrue('struct Point has its /** */ doc comment',
               Pos('A point on a 2D grid', PointStruct.RawComment) > 0);
  finally
    U.Free;
  end;
end;

function TParserTests.FindByName(U: TBindingUnit; const N: string): TBindingDecl;
var
  I: Integer;
begin
  for I := 0 to U.Decls.Count - 1 do
    if U.Decls[I].Name = N then
    begin
      Result := U.Decls[I];
      Exit;
    end;
  Result := nil;
end;

procedure TParserTests.FunctionAddHasIntReturnAndTwoIntParams;
var
  U: TBindingUnit;
  F: TBindingFunction;
begin
  U := Parse;
  try
    F := TBindingFunction(FindByName(U, 'add'));
    AssertNotNull('add present', F);
    AssertNotNull('add has a return type', F.ReturnType);
    AssertEquals('add returns int', 'int', F.ReturnType.Spelling);
    AssertEquals('add takes 2 params', 2, F.Params.Count);
    AssertEquals('first param named a', 'a', F.Params[0].Name);
    AssertEquals('second param named b', 'b', F.Params[1].Name);
    AssertEquals('first param type int', 'int', F.Params[0].ParamType.Spelling);
    AssertFalse('add is not variadic', F.IsVarArgs);
  finally
    U.Free;
  end;
end;

procedure TParserTests.FunctionGreetHasConstCharPointerParam;
var
  U: TBindingUnit;
  F: TBindingFunction;
  PT: TBindingType;
begin
  U := Parse;
  try
    F := TBindingFunction(FindByName(U, 'greet'));
    AssertNotNull('greet present', F);
    AssertEquals('one param', 1, F.Params.Count);
    PT := F.Params[0].ParamType;
    AssertEquals('param is pointer', Ord(tkPointer), Ord(PT.Kind));
    AssertNotNull('pointer has pointee', PT.Pointee);
    AssertTrue('pointee is const-qualified char',
               Pos('char', PT.Pointee.Spelling) > 0);
  finally
    U.Free;
  end;
end;

procedure TParserTests.StructPointHasTwoIntFields;
var
  U: TBindingUnit;
  R: TBindingRecord;
begin
  U := Parse;
  try
    R := TBindingRecord(FindByName(U, 'Point'));
    AssertNotNull('Point struct present', R);
    AssertFalse('Point is not a union', R.IsUnion);
    AssertEquals('two fields', 2, R.Fields.Count);
    AssertEquals('first field is x', 'x', R.Fields[0].Name);
    AssertEquals('second field is y', 'y', R.Fields[1].Name);
    AssertEquals('x is int', 'int', R.Fields[0].FieldType.Spelling);
  finally
    U.Free;
  end;
end;

procedure TParserTests.EnumColorHasThreeConsecutiveConstants;
var
  U: TBindingUnit;
  E: TBindingEnum;
begin
  U := Parse;
  try
    E := TBindingEnum(FindByName(U, 'Color'));
    AssertNotNull('Color enum present', E);
    AssertEquals('three constants', 3, E.Constants.Count);
    AssertEquals('RED', 'RED', E.Constants[0].Name);
    AssertEquals('RED=0', 0, E.Constants[0].Value);
    AssertEquals('GREEN=1', 1, E.Constants[1].Value);
    AssertEquals('BLUE=2', 2, E.Constants[2].Value);
  finally
    U.Free;
  end;
end;

procedure TParserTests.TypedefMyIntAliasesInt;
var
  U: TBindingUnit;
  T: TBindingTypedef;
begin
  U := Parse;
  try
    T := TBindingTypedef(FindByName(U, 'my_int_t'));
    AssertNotNull('typedef present', T);
    AssertNotNull('aliased type set', T.Aliased);
    AssertEquals('aliases int', 'int', T.Aliased.Spelling);
  finally
    U.Free;
  end;
end;

{ TClangTypeTests }

function TClangTypeTests.FindCursor(Idx: TClangIndex; const Header, Spelling: string;
                                    Kind: Integer): TClangCursor;
var
  TU: TClangTranslationUnit;
  Root: TClangCursor;
  Kids: TClangCursorArray;
  I: Integer;
begin
  Result := nil;
  TU := Idx.Parse(Header, []);
  try
    Root := TU.RootCursor;
    try
      Kids := Root.Children;
      try
        for I := 0 to High(Kids) do
          if (Kids[I].Kind = Kind) and (Kids[I].Spelling = Spelling) then
          begin
            { transfer ownership out of the kids array }
            Result := Kids[I];
            Kids[I] := nil;
            Break;
          end;
      finally
        for I := 0 to High(Kids) do
          if Kids[I] <> nil then Kids[I].Free;
      end;
    finally
      Root.Free;
    end;
  finally
    TU.Free;
  end;
  if Result = nil then
    Fail('cursor not found: ' + Spelling);
end;

procedure TClangTypeTests.FunctionReturnTypeIsInt;
const
  Snippet = 'int add(int a, int b);';
var
  TmpH: string;
  Idx: TClangIndex;
  C: TClangCursor;
  T, R: TClangType;
begin
  TmpH := GetTempFileName + '.h';
  with TFileStream.Create(TmpH, fmCreate) do
    try Write(Snippet[1], Length(Snippet)); finally Free; end;
  Idx := TClangIndex.Create(False, False);
  try
    C := FindCursor(Idx, TmpH, 'add', TClangKinds.FunctionDecl);
    try
      T := C.TypeOf;
      try
        R := T.ResultType;
        try
          AssertEquals('return kind = Int', TClangTypeKinds.Int, R.Kind);
        finally
          R.Free;
        end;
      finally
        T.Free;
      end;
    finally
      C.Free;
    end;
  finally
    Idx.Free;
    DeleteFile(TmpH);
  end;
end;

procedure TClangTypeTests.FunctionParamCountMatches;
const
  Snippet = 'void f(int a, int b, int c);';
var
  TmpH: string;
  Idx: TClangIndex;
  C: TClangCursor;
  T: TClangType;
begin
  TmpH := GetTempFileName + '.h';
  with TFileStream.Create(TmpH, fmCreate) do
    try Write(Snippet[1], Length(Snippet)); finally Free; end;
  Idx := TClangIndex.Create(False, False);
  try
    C := FindCursor(Idx, TmpH, 'f', TClangKinds.FunctionDecl);
    try
      T := C.TypeOf;
      try
        AssertEquals('param count', 3, T.NumArgs);
      finally
        T.Free;
      end;
    finally
      C.Free;
    end;
  finally
    Idx.Free;
    DeleteFile(TmpH);
  end;
end;

procedure TClangTypeTests.VariadicDetected;
const
  Snippet = 'int printf(const char *fmt, ...);';
var
  TmpH: string;
  Idx: TClangIndex;
  C: TClangCursor;
  T: TClangType;
begin
  TmpH := GetTempFileName + '.h';
  with TFileStream.Create(TmpH, fmCreate) do
    try Write(Snippet[1], Length(Snippet)); finally Free; end;
  Idx := TClangIndex.Create(False, False);
  try
    C := FindCursor(Idx, TmpH, 'printf', TClangKinds.FunctionDecl);
    try
      T := C.TypeOf;
      try
        AssertTrue('variadic', T.IsVariadic);
      finally
        T.Free;
      end;
    finally
      C.Free;
    end;
  finally
    Idx.Free;
    DeleteFile(TmpH);
  end;
end;

procedure TClangTypeTests.ConstParamQualified;
const
  Snippet = 'void g(const int x);';
var
  TmpH: string;
  Idx: TClangIndex;
  C: TClangCursor;
  T, A: TClangType;
begin
  TmpH := GetTempFileName + '.h';
  with TFileStream.Create(TmpH, fmCreate) do
    try Write(Snippet[1], Length(Snippet)); finally Free; end;
  Idx := TClangIndex.Create(False, False);
  try
    C := FindCursor(Idx, TmpH, 'g', TClangKinds.FunctionDecl);
    try
      T := C.TypeOf;
      try
        A := T.Arg(0);
        try
          AssertTrue('const-qualified', A.IsConstQualified);
        finally
          A.Free;
        end;
      finally
        T.Free;
      end;
    finally
      C.Free;
    end;
  finally
    Idx.Free;
    DeleteFile(TmpH);
  end;
end;

var
  Application: TTestRunner;

begin
  Application := TTestRunner.Create(nil);
  try
    RegisterTest(TIRTests);
    RegisterTest(TParserTests);
    RegisterTest(TClangTypeTests);
    Application.Initialize;
    Application.Run;
  finally
    Application.Free;
  end;
end.
