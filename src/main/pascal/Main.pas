program Main;

{$mode objfpc}{$H+}

uses
  SysUtils, bindgen.ir, bindgen.parser;

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
    D := U.Decls[I];
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
  WriteLn('usage: pascal_bindgen --header <file.h> [-- <clang args...>]');
  Halt(2);
end;

var
  HeaderPath: string = '';
  ExtraArgs: array of string;
  I: Integer;
  PastDD: Boolean = False;
  U: TBindingUnit;
begin
  SetLength(ExtraArgs, 0);
  I := 1;
  while I <= ParamCount do
  begin
    if PastDD then
    begin
      SetLength(ExtraArgs, Length(ExtraArgs) + 1);
      ExtraArgs[High(ExtraArgs)] := ParamStr(I);
    end
    else if ParamStr(I) = '--header' then
    begin
      Inc(I);
      if I > ParamCount then Usage;
      HeaderPath := ParamStr(I);
    end
    else if ParamStr(I) = '--' then
      PastDD := True
    else
      Usage;
    Inc(I);
  end;
  if HeaderPath = '' then Usage;

  U := TBindgenParser.ParseHeader(HeaderPath, ExtraArgs);
  try
    DumpUnit(U);
  finally
    U.Free;
  end;
end.
