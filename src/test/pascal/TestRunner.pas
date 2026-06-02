{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

program TestRunner;

{$IFDEF FPC}
{$mode objfpc}{$H+}
{$ENDIF}

uses
  Classes, SysUtils, StrUtils,
  {$IFDEF FPC}
  fpcunit, testregistry, consoletestrunner,
  {$ELSE}
  blaise.testing, blaise.testing.runner.text,
  {$ENDIF}
  bindgen.ir, bindgen.parser, bindgen.emit.fpc, bindgen.emit.blaise,
  bindgen.blob, clang.wrap, process;

{ Run a shell command, wait, return its exit code. Both FPC and
  Blaise expose TProcess with the same surface, so this stays
  IFDEF-free. }
function RunShell(Cmd: string): Integer;
var
  P: TProcess;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(Cmd);
    P.Execute;
    P.WaitOnExit;
    Result := P.ExitCode;
  finally
    P.Free;
  end;
end;

procedure WriteSnippet(Path, Content: string);
var
  B: TMemoryBlob;
begin
  B := TMemoryBlob.Create;
  try
    B.AppendString(Content);
    B.SaveToFile(Path);
  finally
    B.Free;
  end;
end;

function ReadAllText(Path: string): string;
var
  B: TMemoryBlob;
begin
  B := TMemoryBlob.Create;
  try
    B.LoadFromFile(Path);
    Result := B.AsString;
  finally
    B.Free;
  end;
end;

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
    procedure UserIncludeDeclsAreEmittedSystemHeadersAreNot;
    procedure ForwardDeclThenDefinitionEmitsOnce;
    procedure ReservedWordIdentsAreEscapedAndEmittedSourceCompiles;
    procedure PointerParamAndReturnAreNamedAliasesAndCompile;
    procedure FilteredOutTypedefChasesCanonicalPrimitive;
    procedure FunctionPointerTypedefBecomesProceduralType;
    procedure IntegerLiteralMacrosBecomeConsts;
  end;

  TFpcEmitTests = class(TTestCase)
  private
    function SampleHeader: string;
    function EmitSample: string;
  published
    procedure HasProvenanceHeader;
    procedure DeclaresUnitAndUsesCtypes;
    procedure FunctionAddBecomesCdeclExternal;
    procedure StructPointHasIntFields;
    procedure UnionValueUsesRecordCase;
    procedure EnumColorEmitsTypeAndConstants;
    procedure VariadicEmitsVarargsModifier;
    procedure ConstCharPointerBecomesPAnsiChar;
    procedure EmittedSourceCompilesUnderFpc;
  end;

  TBlaiseEmitTests = class(TTestCase)
  private
    function SampleHeader: string;
    function EmitSample: string;
  published
    procedure HasProvenanceHeaderAndLibraryNote;
    procedure UsesBlaiseBuiltinTypesNotCtypes;
    procedure FunctionAddBecomesExternalNameNoCdecl;
    procedure NoModeOrPackrecordsDirective;
    procedure StructPointHasIntegerFields;
    procedure EnumColorEmitsTypeAndConstants;
    procedure EmittedSourceCompilesUnderBlaise;
    procedure UnsignedLongMapsBySizeOnWin64;
    procedure UnsignedLongMapsBySizeOnLinux;
    procedure DisambiguatesAgainstRtlGlobalCollision;
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
    AssertEquals('line', 12, Integer(F.Location.Line));
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
  Result := ParseHeader(SampleHeader);
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
      D := U.Decls.Items[I];
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
      D := U.Decls.Items[I];
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
      D := U.Decls.Items[I];
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
    if U.Decls.Items[I].Name = N then
    begin
      Result := U.Decls.Items[I];
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
    AssertEquals('first param named a', 'a', F.Params.Items[0].Name);
    AssertEquals('second param named b', 'b', F.Params.Items[1].Name);
    AssertEquals('first param type int', 'int', F.Params.Items[0].ParamType.Spelling);
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
    PT := F.Params.Items[0].ParamType;
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
    AssertEquals('first field is x', 'x', R.Fields.Items[0].Name);
    AssertEquals('second field is y', 'y', R.Fields.Items[1].Name);
    AssertEquals('x is int', 'int', R.Fields.Items[0].FieldType.Spelling);
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
    AssertEquals('RED', 'RED', E.Constants.Items[0].Name);
    AssertEquals('RED=0', 0, E.Constants.Items[0].Value);
    AssertEquals('GREEN=1', 1, E.Constants.Items[1].Value);
    AssertEquals('BLUE=2', 2, E.Constants.Items[2].Value);
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

procedure TParserTests.UserIncludeDeclsAreEmittedSystemHeadersAreNot;
{ Confirms the parser admits decls from user #includes (sample_include.h)
  while still skipping system headers (<stddef.h> in this case).
  Regression for the gap zlib surfaced — its zconf.h types used to
  vanish under the old main-file-only filter. }
const
  Candidates: array[0..3] of string = (
    'sample_with_include.h',
    'src/test/resources/sample_with_include.h',
    '../src/test/resources/sample_with_include.h',
    '../../src/test/resources/sample_with_include.h'
  );
var
  Header: string;
  I: Integer;
  U: TBindingUnit;
  D: TBindingDecl;
  SawUserInclude, SawMainFile, AnySystemLeak: Boolean;
begin
  Header := Candidates[0];
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Header := Candidates[I]; Break; end;

  U := ParseHeader(Header);
  try
    SawUserInclude := False; SawMainFile := False; AnySystemLeak := False;
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if D.Name = 'UserIncluded' then SawUserInclude := True;
      if D.Name = 'main_file_func' then SawMainFile := True;
      { System-header leak would show as e.g. ptrdiff_t / NULL / size_t.
        Looser check: the location filename must contain "sample" — both
        sample_with_include.h and sample_include.h match. }
      if Pos('sample', D.Location.FileName) = 0 then
        AnySystemLeak := True;
    end;
    AssertTrue('user-include decl UserIncluded present',     SawUserInclude);
    AssertTrue('main-file decl main_file_func present',      SawMainFile);
    AssertFalse('no leak from system headers like stddef.h', AnySystemLeak);
  finally
    U.Free;
  end;
end;

procedure TParserTests.ForwardDeclThenDefinitionEmitsOnce;
{ Regression for the zlib gzFile_s pattern: a forward struct decl
  ahead of its later completion used to produce two type
  declarations in the emitter output. With dedup on, the FPC
  emitter must produce exactly one 'OpaqueThing = record' line. }
const
  Candidates: array[0..3] of string = (
    'sample_dup.h',
    'src/test/resources/sample_dup.h',
    '../src/test/resources/sample_dup.h',
    '../../src/test/resources/sample_dup.h'
  );
var
  Header, EmittedSrc: string;
  I, Count: Integer;
  P: Integer;
  Hdr: string;
  U: TBindingUnit;
  E: TFpcEmitter;
begin
  Hdr := Candidates[0];
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Hdr := Candidates[I]; Break; end;

  U := ParseHeader(Hdr);
  try
    E := TFpcEmitter.Create('dup', 'libdup');
    try
      EmittedSrc := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;

  Count := 0;
  P := 1;
  while True do
  begin
    P := PosEx('OpaqueThing = record', EmittedSrc, P);
    if P = 0 then Break;
    Inc(Count);
    Inc(P);
  end;
  AssertEquals('exactly one OpaqueThing record declaration', 1, Count);
end;

procedure TParserTests.ReservedWordIdentsAreEscapedAndEmittedSourceCompiles;
{ Parameter and field names that collide with Pascal reserved words
  ('file', 'type', 'in', 'out', 'begin', 'end', ...) must be
  emitted with the '&' escape so the unit still parses under FPC. }
const
  Candidates: array[0..3] of string = (
    'sample_reserved.h',
    'src/test/resources/sample_reserved.h',
    '../src/test/resources/sample_reserved.h',
    '../../src/test/resources/sample_reserved.h'
  );
var
  Hdr, Src: string;
  I, RC: Integer;
  U: TBindingUnit;
  E: TFpcEmitter;
  TmpDir, PasFile, OutFile, Cmd: string;
begin
  Hdr := Candidates[0];
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Hdr := Candidates[I]; Break; end;

  U := ParseHeader(Hdr);
  try
    E := TFpcEmitter.Create('reserved', 'libreserved');
    try
      Src := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;

  { Spot-check a couple of escapes landed. }
  AssertTrue('file_ param present',  Pos('file_:', Src) > 0);
  AssertTrue('type_ param present',  Pos('type_:', Src) > 0);
  AssertTrue('begin_ field present', Pos('begin_:', Src) > 0);
  AssertTrue('in_ param present',    Pos('in_:', Src) > 0);

  { And compile the whole thing under fpc -Cn — if a collision still
    snuck through, this is what catches it. }
  TmpDir := GetTempDir(True);
  PasFile := IncludeTrailingPathDelimiter(TmpDir) + 'reserved.pas';
  OutFile := IncludeTrailingPathDelimiter(TmpDir) + 'reserved.out';
  WriteSnippet(PasFile, Src);
  try
    Cmd := Format('fpc -Cn -O- %s > %s 2>&1', [PasFile, OutFile]);
    RC := RunShell(Cmd);
    if RC <> 0 then
    begin
      WriteLn('--- fpc output ---');
      WriteLn(ReadAllText(OutFile));
      WriteLn('--- emitted source ---');
      WriteLn(Src);
    end;
    AssertEquals('emitted reserved-words source parses', 0, RC);
  finally
    DeleteFile(PasFile);
    DeleteFile(OutFile);
  end;
end;

procedure TParserTests.PointerParamAndReturnAreNamedAliasesAndCompile;
{ Bare '^Widget' as a parameter or return type is rejected by FPC.
  The emitter must synthesise 'PWidget = ^Widget;' once at the top
  of the type section and substitute that name at sig sites. Whole
  output must round-trip through fpc -Cn. }
const
  Candidates: array[0..3] of string = (
    'sample_ptr.h',
    'src/test/resources/sample_ptr.h',
    '../src/test/resources/sample_ptr.h',
    '../../src/test/resources/sample_ptr.h'
  );
var
  Hdr, Src: string;
  I, RC: Integer;
  U: TBindingUnit;
  E: TFpcEmitter;
  TmpDir, PasFile, OutFile, Cmd: string;
begin
  Hdr := Candidates[0];
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Hdr := Candidates[I]; Break; end;

  U := ParseHeader(Hdr);
  try
    E := TFpcEmitter.Create('ptr', 'libptr');
    try
      Src := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;

  AssertTrue('PWidget alias declared', Pos('PWidget = ^Widget;', Src) > 0);
  AssertTrue('uses PWidget as param',  Pos(': PWidget', Src) > 0);
  AssertTrue('uses PWidget as return', Pos('): PWidget', Src) > 0);
  AssertTrue('no inline ^Widget in signature',
             Pos(': ^Widget', Src) = 0);

  TmpDir := GetTempDir(True);
  PasFile := IncludeTrailingPathDelimiter(TmpDir) + 'ptr.pas';
  OutFile := IncludeTrailingPathDelimiter(TmpDir) + 'ptr.out';
  WriteSnippet(PasFile, Src);
  try
    Cmd := Format('fpc -Cn -O- %s > %s 2>&1', [PasFile, OutFile]);
    RC := RunShell(Cmd);
    if RC <> 0 then
    begin
      WriteLn('--- fpc output ---'); WriteLn(ReadAllText(OutFile));
      WriteLn('--- emitted source ---'); WriteLn(Src);
    end;
    AssertEquals('emitted pointer-arg source parses', 0, RC);
  finally
    DeleteFile(PasFile);
    DeleteFile(OutFile);
  end;
end;

procedure TParserTests.FilteredOutTypedefChasesCanonicalPrimitive;
{ When a user typedef aliases a system-header typedef (e.g.
  'my_size_t = size_t' where size_t lives in <stddef.h>), the
  system decl is filtered out. Without B1, the unit would reference
  an undeclared 'size_t'. With B1, the emitter must chase to the
  canonical primitive (culong on Linux x86_64). }
const
  Candidates: array[0..3] of string = (
    'sample_chain.h',
    'src/test/resources/sample_chain.h',
    '../src/test/resources/sample_chain.h',
    '../../src/test/resources/sample_chain.h'
  );
var
  Hdr, Src: string;
  I, RC: Integer;
  U: TBindingUnit;
  E: TFpcEmitter;
  TmpDir, PasFile, OutFile, Cmd: string;
begin
  Hdr := Candidates[0];
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Hdr := Candidates[I]; Break; end;

  U := ParseHeader(Hdr);
  try
    E := TFpcEmitter.Create('chain', 'libchain');
    try
      Src := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;

  AssertTrue('chases size_t to culong',
             Pos('my_size_t = culong', Src) > 0);
  AssertTrue('no undeclared size_t leak',
             Pos('= size_t', Src) = 0);

  TmpDir := GetTempDir(True);
  PasFile := IncludeTrailingPathDelimiter(TmpDir) + 'chain.pas';
  OutFile := IncludeTrailingPathDelimiter(TmpDir) + 'chain.out';
  WriteSnippet(PasFile, Src);
  try
    Cmd := Format('fpc -Cn -O- %s > %s 2>&1', [PasFile, OutFile]);
    RC := RunShell(Cmd);
    if RC <> 0 then
    begin
      WriteLn('--- fpc output ---'); WriteLn(ReadAllText(OutFile));
      WriteLn('--- emitted source ---'); WriteLn(Src);
    end;
    AssertEquals('emitted typedef-chain source parses', 0, RC);
  finally
    DeleteFile(PasFile);
    DeleteFile(OutFile);
  end;
end;

procedure TParserTests.FunctionPointerTypedefBecomesProceduralType;
{ B2: typedef'd function pointers, struct fields of that type, and
  inline function-pointer fields must all render as Pascal procedural
  types ('function(...): T; cdecl') rather than raw C-syntax garbage. }
const
  Candidates: array[0..3] of string = (
    'sample_funcptr.h',
    'src/test/resources/sample_funcptr.h',
    '../src/test/resources/sample_funcptr.h',
    '../../src/test/resources/sample_funcptr.h'
  );
var
  Hdr, Src: string;
  I, RC: Integer;
  U: TBindingUnit;
  E: TFpcEmitter;
  TmpDir, PasFile, OutFile, Cmd: string;
begin
  Hdr := Candidates[0];
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Hdr := Candidates[I]; Break; end;

  U := ParseHeader(Hdr);
  try
    E := TFpcEmitter.Create('funcptr', 'libfuncptr');
    try
      Src := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;

  AssertTrue('compare_fn renders as Pascal procedural type',
             Pos('compare_fn = function', Src) > 0);
  AssertTrue('compare_fn carries cdecl',
             Pos('cdecl', Src) > 0);
  AssertTrue('no raw C function-pointer syntax in output',
             Pos('(*)', Src) = 0);
  AssertTrue('inline void-returning field is a procedure',
             Pos('on_swap: procedure', Src) > 0);
  AssertTrue('typedef name preserved in sort_run parameter (not inlined)',
             Pos('cb: compare_fn', Src) > 0);

  TmpDir := GetTempDir(True);
  PasFile := IncludeTrailingPathDelimiter(TmpDir) + 'funcptr.pas';
  OutFile := IncludeTrailingPathDelimiter(TmpDir) + 'funcptr.out';
  WriteSnippet(PasFile, Src);
  try
    Cmd := Format('fpc -Cn -O- %s > %s 2>&1', [PasFile, OutFile]);
    RC := RunShell(Cmd);
    if RC <> 0 then
    begin
      WriteLn('--- fpc output ---'); WriteLn(ReadAllText(OutFile));
      WriteLn('--- emitted source ---'); WriteLn(Src);
    end;
    AssertEquals('emitted function-pointer source compiles', 0, RC);
  finally
    DeleteFile(PasFile);
    DeleteFile(OutFile);
  end;
end;

procedure TParserTests.IntegerLiteralMacrosBecomeConsts;
{ B3: integer-literal #define macros are extracted as TBindingMacroConst
  with Pascal-syntax RawValue (hex '$FF', decimal as-is); function-like,
  string, and expression-bodied macros are skipped silently. Output
  compiles under FPC. }
const
  Candidates: array[0..3] of string = (
    'sample_macros.h',
    'src/test/resources/sample_macros.h',
    '../src/test/resources/sample_macros.h',
    '../../src/test/resources/sample_macros.h'
  );
var
  Hdr, Src: string;
  I, RC: Integer;
  U: TBindingUnit;
  E: TFpcEmitter;
  D: TBindingDecl;
  M: TBindingMacroConst;
  SawOK, SawHex, SawFunclike, SawExpr, SawStr: Boolean;
  TmpDir, PasFile, OutFile, Cmd: string;
begin
  Hdr := Candidates[0];
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Hdr := Candidates[I]; Break; end;

  U := ParseHeader(Hdr);
  try
    SawOK := False; SawHex := False;
    SawFunclike := False; SawExpr := False; SawStr := False;
    for I := 0 to U.Decls.Count - 1 do
    begin
      D := U.Decls.Items[I];
      if not (D is TBindingMacroConst) then Continue;
      M := TBindingMacroConst(D);
      if M.Name = 'M_OK' then
      begin
        SawOK := True;
        AssertEquals('M_OK is decimal 0', '0', M.RawValue);
      end;
      if M.Name = 'M_FLAG_A' then
      begin
        SawHex := True;
        AssertEquals('M_FLAG_A is $01', '$01', M.RawValue);
      end;
      if M.Name = 'M_FUNCLIKE' then SawFunclike := True;
      if M.Name = 'M_EXPR'     then SawExpr := True;
      if M.Name = 'M_STR'      then SawStr := True;
    end;
    AssertTrue('M_OK extracted',         SawOK);
    AssertTrue('M_FLAG_A hex extracted', SawHex);
    AssertFalse('function-like macro is skipped',  SawFunclike);
    AssertFalse('expression-bodied macro is skipped', SawExpr);
    AssertFalse('string-literal macro is skipped', SawStr);

    E := TFpcEmitter.Create('macros', 'libdummy');
    try
      Src := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;

  AssertTrue('const block present', Pos('const', Src) > 0);
  AssertTrue('M_FLAG_B emitted as $FF', Pos('M_FLAG_B = $FF', Src) > 0);

  TmpDir := GetTempDir(True);
  PasFile := IncludeTrailingPathDelimiter(TmpDir) + 'macros.pas';
  OutFile := IncludeTrailingPathDelimiter(TmpDir) + 'macros.out';
  WriteSnippet(PasFile, Src);
  try
    Cmd := Format('fpc -Cn -O- %s > %s 2>&1', [PasFile, OutFile]);
    RC := RunShell(Cmd);
    if RC <> 0 then
    begin
      WriteLn('--- fpc output ---'); WriteLn(ReadAllText(OutFile));
      WriteLn('--- emitted source ---'); WriteLn(Src);
    end;
    AssertEquals('emitted macro-const source compiles', 0, RC);
  finally
    DeleteFile(PasFile);
    DeleteFile(OutFile);
  end;
end;

{ TFpcEmitTests }

function TFpcEmitTests.SampleHeader: string;
const
  Candidates: array[0..3] of string = (
    'sample.h',
    'src/test/resources/sample.h',
    '../src/test/resources/sample.h',
    '../../src/test/resources/sample.h'
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
  Result := Candidates[0];
end;

function TFpcEmitTests.EmitSample: string;
var
  U: TBindingUnit;
  E: TFpcEmitter;
begin
  U := ParseHeader(SampleHeader);
  try
    E := TFpcEmitter.Create('sample', 'libsample');
    try
      Result := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;
end;

procedure TFpcEmitTests.HasProvenanceHeader;
var S: string;
begin
  S := EmitSample;
  AssertTrue('DO NOT EDIT banner', Pos('DO NOT EDIT', S) > 0);
  AssertTrue('source line names sample.h', Pos('sample.h', S) > 0);
end;

procedure TFpcEmitTests.DeclaresUnitAndUsesCtypes;
var S: string;
begin
  S := EmitSample;
  AssertTrue('unit sample;', Pos('unit sample;', S) > 0);
  AssertTrue('PACKRECORDS C', Pos('{$PACKRECORDS C}', S) > 0);
  AssertTrue('uses ctypes',  Pos('ctypes', S) > 0);
end;

procedure TFpcEmitTests.FunctionAddBecomesCdeclExternal;
var S: string;
begin
  S := EmitSample;
  AssertTrue('add signature present',
             Pos('function add(a: cint; b: cint): cint;', S) > 0);
  AssertTrue('cdecl modifier',  Pos('cdecl', S) > 0);
  AssertTrue('external libsample name ''add''',
             Pos('external ''libsample'' name ''add''', S) > 0);
end;

procedure TFpcEmitTests.StructPointHasIntFields;
var S: string;
begin
  S := EmitSample;
  AssertTrue('record opener', Pos('Point = record', S) > 0);
  AssertTrue('field x: cint', Pos('x: cint;', S) > 0);
  AssertTrue('field y: cint', Pos('y: cint;', S) > 0);
end;

procedure TFpcEmitTests.UnionValueUsesRecordCase;
var S: string;
begin
  S := EmitSample;
  AssertTrue('Value record opener',     Pos('Value = record', S) > 0);
  AssertTrue('case Integer of present', Pos('case Integer of', S) > 0);
end;

procedure TFpcEmitTests.EnumColorEmitsTypeAndConstants;
var S: string;
begin
  S := EmitSample;
  AssertTrue('Color underlying type',
             (Pos('Color = cint', S) > 0) or (Pos('Color = cuint', S) > 0));
  AssertTrue('RED = 0',   Pos('RED = 0;', S) > 0);
  AssertTrue('GREEN = 1', Pos('GREEN = 1;', S) > 0);
  AssertTrue('BLUE = 2',  Pos('BLUE = 2;', S) > 0);
end;

procedure TFpcEmitTests.VariadicEmitsVarargsModifier;
const
  Snippet = 'int my_printf(const char *fmt, ...);';
var
  TmpH, Out_: string;
  U: TBindingUnit;
  E: TFpcEmitter;
begin
  TmpH := GetTempFileName + '.h';
  WriteSnippet(TmpH, Snippet);
  try
    U := ParseHeader(TmpH);
    try
      E := TFpcEmitter.Create('vd', 'libvd');
      try
        Out_ := E.Emit(U);
      finally
        E.Free;
      end;
    finally
      U.Free;
    end;
    AssertTrue('varargs modifier present', Pos('varargs', Out_) > 0);
  finally
    DeleteFile(TmpH);
  end;
end;

procedure TFpcEmitTests.ConstCharPointerBecomesPAnsiChar;
var S: string;
begin
  S := EmitSample;
  AssertTrue('greet takes PAnsiChar',
             Pos('PAnsiChar', S) > 0);
end;

procedure TFpcEmitTests.EmittedSourceCompilesUnderFpc;
var
  S, TmpDir, PasFile, OutFile, Cmd: string;
  RC: Integer;
begin
  S := EmitSample;
  TmpDir := GetTempDir;
  PasFile := IncludeTrailingPathDelimiter(TmpDir) + 'sample.pas';
  OutFile := IncludeTrailingPathDelimiter(TmpDir) + 'sample.out';
  WriteSnippet(PasFile, S);
  try
    { -Cn  produces .o only (no link). Plenty for syntactic verification. }
    Cmd := Format('fpc -Cn -O- %s > %s 2>&1', [PasFile, OutFile]);
    RC := RunShell(Cmd);
    if RC <> 0 then
    begin
      Writeln('--- fpc output ---');
      Writeln(ReadAllText(OutFile));
      Writeln('--- emitted source ---');
      Writeln(S);
    end;
    AssertEquals('fpc -Cn returns 0 on emitted source', 0, RC);
  finally
    DeleteFile(PasFile);
    DeleteFile(OutFile);
    DeleteFile(ChangeFileExt(PasFile, '.o'));
    DeleteFile(ChangeFileExt(PasFile, '.ppu'));
  end;
end;

{ TBlaiseEmitTests }

function TBlaiseEmitTests.SampleHeader: string;
const
  Candidates: array[0..3] of string = (
    'sample.h',
    'src/test/resources/sample.h',
    '../src/test/resources/sample.h',
    '../../src/test/resources/sample.h'
  );
var I: Integer;
begin
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then begin Result := Candidates[I]; Exit; end;
  Result := Candidates[0];
end;

function TBlaiseEmitTests.EmitSample: string;
var
  U: TBindingUnit;
  E: TBlaiseEmitter;
begin
  U := ParseHeader(SampleHeader);
  try
    E := TBlaiseEmitter.Create('sample', 'libsample');
    try
      Result := E.Emit(U);
    finally
      E.Free;
    end;
  finally
    U.Free;
  end;
end;

procedure TBlaiseEmitTests.HasProvenanceHeaderAndLibraryNote;
var S: string;
begin
  S := EmitSample;
  AssertTrue('DO NOT EDIT', Pos('DO NOT EDIT', S) > 0);
  AssertTrue('Blaise dialect banner', Pos('Blaise dialect', S) > 0);
  AssertTrue('library shows up as informational',
             (Pos('library: libsample', S) > 0) and
             (Pos('informational', S) > 0));
end;

procedure TBlaiseEmitTests.UsesBlaiseBuiltinTypesNotCtypes;
var S: string;
begin
  S := EmitSample;
  AssertFalse('no ctypes import', Pos('ctypes', S) > 0);
  AssertFalse('no cint', Pos('cint', S) > 0);
  AssertTrue('uses Integer', Pos('Integer', S) > 0);
end;

procedure TBlaiseEmitTests.FunctionAddBecomesExternalNameNoCdecl;
var S: string;
begin
  S := EmitSample;
  AssertTrue('add signature', Pos('function add(a: Integer; b: Integer): Integer;', S) > 0);
  AssertTrue('external name', Pos('external name ''add''', S) > 0);
  AssertFalse('no cdecl modifier', Pos('cdecl', S) > 0);
end;

procedure TBlaiseEmitTests.NoModeOrPackrecordsDirective;
var S: string;
begin
  S := EmitSample;
  AssertFalse('no $mode',         Pos('{$mode', S) > 0);
  AssertFalse('no PACKRECORDS',   Pos('PACKRECORDS', S) > 0);
  AssertFalse('no $H+',           Pos('{$H+', S) > 0);
end;

procedure TBlaiseEmitTests.StructPointHasIntegerFields;
var S: string;
begin
  S := EmitSample;
  AssertTrue('Point record',  Pos('Point = record', S) > 0);
  AssertTrue('x: Integer',    Pos('x: Integer;', S) > 0);
  AssertTrue('y: Integer',    Pos('y: Integer;', S) > 0);
end;

procedure TBlaiseEmitTests.EnumColorEmitsTypeAndConstants;
var S: string;
begin
  S := EmitSample;
  AssertTrue('Color alias',
             (Pos('Color = Integer', S) > 0) or (Pos('Color = Cardinal', S) > 0));
  AssertTrue('RED = 0',   Pos('RED = 0;', S) > 0);
  AssertTrue('GREEN = 1', Pos('GREEN = 1;', S) > 0);
  AssertTrue('BLUE = 2',  Pos('BLUE = 2;', S) > 0);
end;

procedure TBlaiseEmitTests.EmittedSourceCompilesUnderBlaise;
const
  BlaiseBin = '/home/andrew/Programming/GroupProjects/blaise/local/blaisec.py';
var
  S, TmpDir, PasFile, OutFile, Cmd: string;
  RC: Integer;
begin
  if not FileExists(BlaiseBin) then
  begin
    { Don't fail the suite on machines where Blaise isn't installed;
      this guard is only meaningful where the wrapper exists. }
    Ignore('Blaise wrapper not available at ' + BlaiseBin);
    Exit;
  end;
  S := EmitSample;
  TmpDir := GetTempDir;
  PasFile := IncludeTrailingPathDelimiter(TmpDir) + 'sample.pas';
  OutFile := IncludeTrailingPathDelimiter(TmpDir) + 'sample.out';
  WriteSnippet(PasFile, S);
  try
    { --emit-ir: parse + lower without writing a binary. Sufficient
      proof that the emitted unit is syntactically and semantically
      acceptable to Blaise as a standalone unit. }
    Cmd := Format('%s --source %s --emit-ir > %s 2>&1',
                  [BlaiseBin, PasFile, OutFile]);
    RC := RunShell(Cmd);
    if RC <> 0 then
    begin
      Writeln('--- blaise output ---');
      Writeln(ReadAllText(OutFile));
      Writeln('--- emitted source ---');
      Writeln(S);
    end;
    AssertEquals('blaise --emit-ir returns 0', 0, RC);
  finally
    DeleteFile(PasFile);
    DeleteFile(OutFile);
  end;
end;

{ Emit a fixture header under a specific clang -target, returning
  the Blaise-dialect unit text. Helper for the size-aware tests. }
function EmitBlaiseForTarget(const Hdr, Target: string): string;
var
  TmpDir, HdrFile: string;
  U: TBindingUnit;
  E: TBlaiseEmitter;
begin
  TmpDir := GetTempDir;
  HdrFile := IncludeTrailingPathDelimiter(TmpDir) + 'sizeprobe.h';
  WriteSnippet(HdrFile, Hdr);
  try
    U := ParseHeader(HdrFile, ['-target', Target]);
    try
      E := TBlaiseEmitter.Create('sizeprobe', 'libsizeprobe');
      try
        Result := E.Emit(U);
      finally
        E.Free;
      end;
    finally
      U.Free;
    end;
  finally
    DeleteFile(HdrFile);
  end;
end;

procedure TBlaiseEmitTests.UnsignedLongMapsBySizeOnWin64;
const
  Hdr =
    'typedef unsigned long DWORD;'    + LineEnding +
    'typedef long          LONG;'     + LineEnding;
var
  S: string;
begin
  { LLP64: unsigned long = 4 bytes -> Cardinal; long = 4 bytes -> Integer. }
  S := EmitBlaiseForTarget(Hdr, 'x86_64-w64-mingw32');
  AssertTrue('DWORD on Win64 should be Cardinal: ' + S,
             Pos('DWORD = Cardinal', S) > 0);
  AssertTrue('LONG on Win64 should be Integer: ' + S,
             Pos('LONG = Integer', S) > 0);
end;

procedure TBlaiseEmitTests.UnsignedLongMapsBySizeOnLinux;
const
  Hdr =
    'typedef unsigned long DWORD;'    + LineEnding +
    'typedef long          LONG;'     + LineEnding;
var
  S: string;
begin
  { LP64: unsigned long = 8 bytes -> UInt64; long = 8 bytes -> Int64. }
  S := EmitBlaiseForTarget(Hdr, 'x86_64-linux-gnu');
  AssertTrue('DWORD on Linux should be UInt64: ' + S,
             Pos('DWORD = UInt64', S) > 0);
  AssertTrue('LONG on Linux should be Int64: ' + S,
             Pos('LONG = Int64', S) > 0);
end;

procedure TBlaiseEmitTests.DisambiguatesAgainstRtlGlobalCollision;
const
  { WriteFile and Sleep are both names of Blaise RTL globals; the
    emitter must rename the Pascal-side identifier while keeping the
    original C name in the external clause. }
  Hdr =
    'int WriteFile(int);' + LineEnding +
    'void Sleep(int);'    + LineEnding;
var
  S: string;
begin
  S := EmitBlaiseForTarget(Hdr, 'x86_64-w64-mingw32');
  AssertTrue('WriteFile renamed to WriteFile_: ' + S,
             Pos('function WriteFile_(', S) > 0);
  AssertTrue('WriteFile external keeps original C name: ' + S,
             Pos('external name ''WriteFile''', S) > 0);
  AssertTrue('Sleep renamed to Sleep_: ' + S,
             Pos('procedure Sleep_(', S) > 0);
  AssertTrue('Sleep external keeps original C name: ' + S,
             Pos('external name ''Sleep''', S) > 0);
end;

{ TClangTypeTests }

function TClangTypeTests.FindCursor(Idx: TClangIndex; const Header, Spelling: string;
                                    Kind: Integer): TClangCursor;
var
  TU: TClangTranslationUnit;
  Root: TClangCursor;
  Kids: TClangCursorArray;
  K: TClangCursor;
  I: Integer;
begin
  Result := nil;
  TU := Idx.ParseNoArgs(Header);
  try
    Root := TU.RootCursor;
    try
      Kids := CursorChildren(Root);
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
        begin
          { Stage through K — Blaise rejects arr[I].Method calls. }
          K := Kids[I];
          if K <> nil then K.Free;
        end;
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
  WriteSnippet(TmpH, Snippet);
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
  WriteSnippet(TmpH, Snippet);
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
  WriteSnippet(TmpH, Snippet);
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
  WriteSnippet(TmpH, Snippet);
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

{$IFDEF FPC}
var
  Application: TTestRunner;
{$ENDIF}

begin
  RegisterTest(TIRTests);
  RegisterTest(TParserTests);
  RegisterTest(TClangTypeTests);
  RegisterTest(TFpcEmitTests);
  RegisterTest(TBlaiseEmitTests);
{$IFDEF FPC}
  Application := TTestRunner.Create(nil);
  try
    Application.Initialize;
    Application.Run;
  finally
    Application.Free;
  end;
{$ELSE}
  Halt(RunAll);
{$ENDIF}
end.
