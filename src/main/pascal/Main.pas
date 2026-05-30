program Main;

{$mode objfpc}{$H+}

uses
  SysUtils, bindgen.ir, bindgen.parser, bindgen.emit.fpc, bindgen.emit.blaise,
  bindgen.emit.rqbasic;

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
  WriteLn('                      [--unit-name <name>] [--library <name>]');
  WriteLn('                      [-- <clang args...>]');
  WriteLn('  With no dialect flag the parser dumps top-level decls for debugging.');
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

var
  HeaderPath: string;
  OutputPath: string;
  UnitName: string;
  LibraryName: string;
  Dialect: string;
  PrefixTypes: Boolean;
  ExtraArgs: array of string;
  I: Integer;
  PastDD: Boolean;
  U: TBindingUnit;
  FpcEmitter: TFpcEmitter;
  BlaiseEmitter: TBlaiseEmitter;
  RqBasicEmitter: TRqBasicEmitter;
  Arg: string;
begin
  HeaderPath := '';
  OutputPath := '';
  UnitName := '';
  LibraryName := '';
  Dialect := '';
  PrefixTypes := False;
  PastDD := False;
  SetLength(ExtraArgs, 0);
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if PastDD then
    begin
      SetLength(ExtraArgs, Length(ExtraArgs) + 1);
      ExtraArgs[High(ExtraArgs)] := Arg;
    end
    else if Arg = '--header' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      HeaderPath := ParamStr(I);
    end
    else if Arg = '--output' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      OutputPath := ParamStr(I);
    end
    else if Arg = '--unit-name' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      UnitName := ParamStr(I);
    end
    else if Arg = '--library' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      LibraryName := ParamStr(I);
    end
    else if Arg = '--fpc' then
      Dialect := 'fpc'
    else if Arg = '--blaise' then
      Dialect := 'blaise'
    else if Arg = '--rqbasic' then
      Dialect := 'rqbasic'
    { rqbasic-only: T-prefix every TYPE name so the type namespace
      can't case-fold-collide with constants/functions. Pointer
      aliases stay on the separate P<bare> track. }
    else if Arg = '--prefix-types' then
      PrefixTypes := True
    else if Arg = '--' then
      PastDD := True
    else
      Usage;
    Inc(I);
  end;
  if HeaderPath = '' then Usage;

  U := ParseHeader(HeaderPath, ExtraArgs);
  try
    if Dialect = 'fpc' then
    begin
      if UnitName = '' then UnitName := DeriveUnitName(OutputPath, HeaderPath);
      FpcEmitter := TFpcEmitter.Create(UnitName, LibraryName);
      try
        if OutputPath = '' then OutputPath := '-';
        WriteAllText(OutputPath, FpcEmitter.Emit(U));
      finally
        FpcEmitter.Free;
      end;
    end
    else if Dialect = 'blaise' then
    begin
      if UnitName = '' then UnitName := DeriveUnitName(OutputPath, HeaderPath);
      BlaiseEmitter := TBlaiseEmitter.Create(UnitName, LibraryName);
      try
        if OutputPath = '' then OutputPath := '-';
        WriteAllText(OutputPath, BlaiseEmitter.Emit(U));
      finally
        BlaiseEmitter.Free;
      end;
    end
    else if Dialect = 'rqbasic' then
    begin
      if UnitName = '' then UnitName := DeriveUnitName(OutputPath, HeaderPath);
      RqBasicEmitter := TRqBasicEmitter.Create(UnitName, LibraryName, PrefixTypes);
      try
        if OutputPath = '' then OutputPath := '-';
        WriteAllText(OutputPath, RqBasicEmitter.Emit(U));
      finally
        RqBasicEmitter.Free;
      end;
    end
    else
      DumpUnit(U);
  finally
    U.Free;
  end;
end.
