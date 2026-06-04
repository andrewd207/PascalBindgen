{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

program Main;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, bindgen.ir, bindgen.parser, bindgen.merge,
  bindgen.emit.fpc, bindgen.emit.blaise, bindgen.emit.rqbasic;

const
  Version = '1.0.0';

procedure DumpUnit(U: TBindingUnit);
var
  I: Integer;
  D: TBindingDecl;
  Kind: string;
begin
  for I := 0 to U.Decls.Count - 1 do
  begin
    D := U.Decls.Items[I];
    if D is TBindingFunction then       Kind := 'function'
    else if D is TBindingTypedef then   Kind := 'typedef'
    else if D is TBindingRecord then
      if TBindingRecord(D).IsUnion then Kind := 'union'
      else                              Kind := 'struct'
    else if D is TBindingEnum then      Kind := 'enum'
    else                                Kind := '?';
    WriteLn(Format('%-8s %-30s  { %s:%d }',
            [Kind, D.Name, D.Location.FileName, D.Location.Line]));
  end;
end;

procedure Usage;
begin
  WriteLn('pascal_bindgen ', Version);
  WriteLn('usage: pascal_bindgen [--fpc|--blaise|--rqbasic] --header <file.h> [--output <file.pas>]');
  WriteLn('                      [--unit-name <name>] [--library <name>] [--prefix-types]');
  WriteLn('                      [--target SYMBOL:TRIPLE]...');
  WriteLn('                      [--target-args SYMBOL=ARGS]...');
  WriteLn('                      [-- <clang args...>]');
  WriteLn('  With no dialect flag the parser dumps top-level decls for debugging.');
  WriteLn('  --target may be repeated; each pass parses with -target TRIPLE and the');
  WriteLn('  per-symbol --target-args. Decls divergent across passes are gated with');
  WriteLn('  {$IFDEF SYMBOL} ... in the emitted output. Without --target, output is');
  WriteLn('  byte-identical to a single-target run.');
  Halt(2);
end;

procedure WriteAllText(const Path, Text: string);
var
  F: TextFile;
begin
  if Path = '-' then
    Write(Text)
  else
  begin
    AssignFile(F, Path);
    Rewrite(F);
    try
      Write(F, Text);
    finally
      CloseFile(F);
    end;
  end;
end;

function DeriveUnitName(const OutputPath, HeaderPath: string): string;
begin
  if OutputPath <> '' then
    Result := ChangeFileExt(ExtractFileName(OutputPath), '')
  else
    Result := ChangeFileExt(ExtractFileName(HeaderPath), '');
  if Result = '' then Result := 'bindings';
end;

{ Split "SYMBOL:rest" or "SYMBOL=rest" into the symbol and the
  remainder. Whichever separator comes first wins. Returns False if
  no separator is present. }
function SplitOnce(const S: string; out Sym, Rest: string): Boolean;
var
  P, P2: Integer;
begin
  P  := Pos(':', S);
  P2 := Pos('=', S);
  if (P2 > 0) and ((P = 0) or (P2 < P)) then P := P2;
  if P <= 0 then Exit(False);
  Sym  := Copy(S, 1, P - 1);
  Rest := Copy(S, P + 1, Length(S) - P);
  Result := True;
end;

{ Split a shell-style argument string into tokens. Honors single and
  double quotes; no shell-escape expansion. Enough for `pkg-config
  --cflags` output and the typical -I/-D flag soup. }
procedure SplitArgs(const S: string; Args: TStrings);
var
  I, N: Integer;
  C, Quote: Char;
  Tok: string;
begin
  N := Length(S);
  I := 1;
  while I <= N do
  begin
    while (I <= N) and (S[I] in [' ', #9]) do Inc(I);
    if I > N then Break;
    Tok := '';
    Quote := #0;
    while I <= N do
    begin
      C := S[I];
      if Quote <> #0 then
      begin
        if C = Quote then Quote := #0
        else Tok := Tok + C;
      end
      else if (C = '''') or (C = '"') then
        Quote := C
      else if C in [' ', #9] then
        Break
      else
        Tok := Tok + C;
      Inc(I);
    end;
    Args.Add(Tok);
  end;
end;

type
  TTargetSpec = record
    Symbol: string;  { e.g. 'WINDOWS' }
    Triple: string;  { e.g. 'x86_64-w64-mingw32' }
    Args:   TStringList;  { per-target clang args, owned }
  end;
  TTargetSpecs = array of TTargetSpec;

function FindTarget(var Targets: TTargetSpecs; const Sym: string): Integer;
var I: Integer;
begin
  for I := 0 to High(Targets) do
    if Targets[I].Symbol = Sym then Exit(I);
  Result := -1;
end;

function EmitBindings(Dialect, UnitName, LibraryName: string;
                      PrefixTypes: Boolean; U: TBindingUnit): string;
var
  FpcEmitter:    TFpcEmitter;
  BlaiseEmitter: TBlaiseEmitter;
  RqEmitter:     TRqBasicEmitter;
begin
  if Dialect = 'fpc' then
  begin
    FpcEmitter := TFpcEmitter.Create(UnitName, LibraryName, PrefixTypes);
    try Result := FpcEmitter.Emit(U); finally FpcEmitter.Free; end;
  end
  else if Dialect = 'blaise' then
  begin
    BlaiseEmitter := TBlaiseEmitter.Create(UnitName, LibraryName, PrefixTypes);
    try Result := BlaiseEmitter.Emit(U); finally BlaiseEmitter.Free; end;
  end
  else { rqbasic }
  begin
    RqEmitter := TRqBasicEmitter.Create(UnitName, LibraryName, PrefixTypes);
    try Result := RqEmitter.Emit(U); finally RqEmitter.Free; end;
  end;
end;

var
  HeaderPath:  string;
  OutputPath:  string;
  UnitName:    string;
  LibraryName: string;
  Dialect:     string;
  PrefixTypes: Boolean;
  ExtraArgs:   array of string;
  Targets:     TTargetSpecs;
  I, J, Ti:    Integer;
  PastDD:      Boolean;
  U:           TBindingUnit;
  Arg, Sym, Rest: string;
  Units:       array of TBindingUnit;
  Symbols:     array of string;
  PerArgs:     TStringList;
  PerArgsArr:  array of string;
  Merged:      TBindingUnit;
begin
  HeaderPath := '';
  OutputPath := '';
  UnitName := '';
  LibraryName := '';
  Dialect := '';
  PrefixTypes := False;
  PastDD := False;
  SetLength(ExtraArgs, 0);
  SetLength(Targets, 0);
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if PastDD then
    begin
      SetLength(ExtraArgs, Length(ExtraArgs) + 1);
      ExtraArgs[High(ExtraArgs)] := Arg;
    end
    else if Arg = '--header'    then begin Inc(I); if I > ParamCount then Usage; HeaderPath  := ParamStr(I); end
    else if Arg = '--output'    then begin Inc(I); if I > ParamCount then Usage; OutputPath  := ParamStr(I); end
    else if Arg = '--unit-name' then begin Inc(I); if I > ParamCount then Usage; UnitName    := ParamStr(I); end
    else if Arg = '--library'   then begin Inc(I); if I > ParamCount then Usage; LibraryName := ParamStr(I); end
    else if Arg = '--fpc'     then Dialect := 'fpc'
    else if Arg = '--blaise'  then Dialect := 'blaise'
    else if Arg = '--rqbasic' then Dialect := 'rqbasic'
    else if Arg = '--prefix-types' then PrefixTypes := True
    else if Arg = '--target' then
    begin
      Inc(I); if I > ParamCount then Usage;
      if not SplitOnce(ParamStr(I), Sym, Rest) then
      begin
        WriteLn(StdErr, 'error: --target expects SYMBOL:TRIPLE, got: ', ParamStr(I));
        Halt(2);
      end;
      Ti := FindTarget(Targets, Sym);
      if Ti < 0 then
      begin
        SetLength(Targets, Length(Targets) + 1);
        Ti := High(Targets);
        Targets[Ti].Symbol := Sym;
        Targets[Ti].Args   := TStringList.Create;
      end;
      Targets[Ti].Triple := Rest;
    end
    else if Arg = '--target-args' then
    begin
      Inc(I); if I > ParamCount then Usage;
      if not SplitOnce(ParamStr(I), Sym, Rest) then
      begin
        WriteLn(StdErr, 'error: --target-args expects SYMBOL=ARGS, got: ', ParamStr(I));
        Halt(2);
      end;
      Ti := FindTarget(Targets, Sym);
      if Ti < 0 then
      begin
        { Tolerate ordering: --target-args before --target. }
        SetLength(Targets, Length(Targets) + 1);
        Ti := High(Targets);
        Targets[Ti].Symbol := Sym;
        Targets[Ti].Args   := TStringList.Create;
      end;
      SplitArgs(Rest, Targets[Ti].Args);
    end
    else if Arg = '--' then PastDD := True
    else Usage;
    Inc(I);
  end;
  if HeaderPath = '' then Usage;

  { Validate --target entries — every named symbol must have a triple. }
  for I := 0 to High(Targets) do
    if Targets[I].Triple = '' then
    begin
      WriteLn(StdErr, 'error: --target-args ', Targets[I].Symbol,
              '=... has no matching --target ', Targets[I].Symbol, ':TRIPLE');
      Halt(2);
    end;

  { Single path: 0 or 1 target → preserve byte-identical legacy
    behavior. Targets with one entry still skip the merge: we just
    add the per-target args to ExtraArgs and parse once. }
  if Length(Targets) <= 1 then
  begin
    if Length(Targets) = 1 then
    begin
      { Prepend -target TRIPLE + per-target args. }
      SetLength(ExtraArgs, Length(ExtraArgs) + 2 + Targets[0].Args.Count);
      for I := High(ExtraArgs) downto Targets[0].Args.Count + 2 do
        ExtraArgs[I] := ExtraArgs[I - 2 - Targets[0].Args.Count];
      ExtraArgs[0] := '-target';
      ExtraArgs[1] := Targets[0].Triple;
      for I := 0 to Targets[0].Args.Count - 1 do
        ExtraArgs[2 + I] := Targets[0].Args[I];
    end;
    U := ParseHeader(HeaderPath, ExtraArgs);
    try
      if Dialect = '' then DumpUnit(U)
      else
      begin
        if UnitName = '' then UnitName := DeriveUnitName(OutputPath, HeaderPath);
        if OutputPath = '' then OutputPath := '-';
        WriteAllText(OutputPath, EmitBindings(Dialect, UnitName, LibraryName, PrefixTypes, U));
      end;
    finally
      U.Free;
    end;
    Halt(0);
  end;

  { Multi-target: parse once per target, then merge. ExtraArgs are
    the user's post-`--` clang flags, shared across all targets. Each
    pass prepends `-target TRIPLE` + per-target --target-args. }
  SetLength(Units,   Length(Targets));
  SetLength(Symbols, Length(Targets));
  PerArgs := TStringList.Create;
  try
    for Ti := 0 to High(Targets) do
    begin
      Symbols[Ti] := Targets[Ti].Symbol;
      PerArgs.Clear;
      PerArgs.Add('-target');
      PerArgs.Add(Targets[Ti].Triple);
      PerArgs.AddStrings(Targets[Ti].Args);
      for I := 0 to High(ExtraArgs) do PerArgs.Add(ExtraArgs[I]);

      { ParseHeader takes a Pascal open array; marshal into a fresh
        local. Do not mutate ExtraArgs — the next iteration needs the
        original user flags untouched. }
      SetLength(PerArgsArr, PerArgs.Count);
      for J := 0 to PerArgs.Count - 1 do PerArgsArr[J] := PerArgs[J];
      Units[Ti] := ParseHeader(HeaderPath, PerArgsArr);
    end;
  finally
    PerArgs.Free;
  end;

  Merged := MergeUnits(Units, Symbols);
  try
    for Ti := 0 to High(Units) do Units[Ti].Free;
    if Dialect = '' then DumpUnit(Merged)
    else
    begin
      if UnitName = '' then UnitName := DeriveUnitName(OutputPath, HeaderPath);
      if OutputPath = '' then OutputPath := '-';
      WriteAllText(OutputPath, EmitBindings(Dialect, UnitName, LibraryName, PrefixTypes, Merged));
    end;
  finally
    Merged.Free;
    for Ti := 0 to High(Targets) do Targets[Ti].Args.Free;
  end;
end.
