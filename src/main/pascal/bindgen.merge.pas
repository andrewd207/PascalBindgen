{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

{ bindgen.merge — fold per-target parsed units into one platform-tagged unit.

  Each input unit was produced by ParseHeader with a distinct clang
  target (Linux, Windows, ...). MergeUnits walks them in order, keys
  decls by (kind, name), and emits one merged TBindingUnit:

  * Decl present in every input AND deep-equal across all of them →
    one decl, Platforms left empty (unconditional emit).
  * Decl present in every input but differs → one decl per distinct
    variant, each tagged with the platform symbols whose IR matched
    that variant.
  * Decl present in only a subset → one decl per variant tagged with
    just the platforms that have it.

  Ownership: the merged unit takes ownership of decls from the first
  input unit it sees them in; the input units have their declaration
  lists drained (decls reparented, not copied), so callers must Free
  the input units afterwards without expecting decls to live on. }
unit bindgen.merge;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  Classes, SysUtils, Generics.Collections, bindgen.ir;

type
  TBindingUnitArray = array of TBindingUnit;
  TStringArray      = array of string;

{ Merge per-target units. Symbols[i] is the platform tag for Units[i]
  (e.g. 'WINDOWS', 'UNIX'). Returns a new TBindingUnit; the caller
  owns it. The input units are consumed: their decl lists are emptied
  and the surviving decls reparented to the result. Callers should
  still Free the input units afterwards (they retain headers /
  command-line / version metadata). }
function MergeUnits(const Units: TBindingUnitArray;
                    const Symbols: TStringArray): TBindingUnit;

(* Wrap the lines added between StartIdx and Output.Count in a
   platform guard. No-op when Targets is empty (single-target run) or
   when Platforms is empty (decl present on every target). Pass the
   dialect-appropriate brackets — Pascal-style is ( '{' + '$' , '}' );
   rqbasic-style is ( '$', '' ). *)
procedure WrapPlatformGuard(Output: TStringList;
                            Targets, Platforms: TStringList;
                            StartIdx: Integer;
                            const OpenBracket, CloseBracket: string);

implementation

{ Deep-equality on the IR shapes we care about. Cheap enough — most
  binding decls are small. We don't memoize: clang's typedef
  collapsing keeps recursion shallow in practice. }

function TypesEqual(A, B: TBindingType): Boolean; forward;

function TypeListsEqual(A, B: TBindingTypeList): Boolean;
var I: Integer;
begin
  if (A = nil) and (B = nil) then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  if A.Count <> B.Count then Exit(False);
  for I := 0 to A.Count - 1 do
    if not TypesEqual(A.Items[I], B.Items[I]) then Exit(False);
  Result := True;
end;

function TypesEqual(A, B: TBindingType): Boolean;
begin
  if (A = nil) and (B = nil) then Exit(True);
  if (A = nil) or (B = nil) then Exit(False);
  if A.Kind <> B.Kind then Exit(False);
  if A.Spelling <> B.Spelling then Exit(False);
  if A.ArraySize <> B.ArraySize then Exit(False);
  if A.ByteSize <> B.ByteSize then Exit(False);
  if A.CanonicalSpelling <> B.CanonicalSpelling then Exit(False);
  if not TypesEqual(A.Pointee, B.Pointee) then Exit(False);
  if not TypesEqual(A.FuncReturn, B.FuncReturn) then Exit(False);
  if not TypeListsEqual(A.FuncParams, B.FuncParams) then Exit(False);
  Result := True;
end;

function ParamsEqual(A, B: TBindingParamList): Boolean;
var I: Integer;
begin
  if A.Count <> B.Count then Exit(False);
  for I := 0 to A.Count - 1 do
  begin
    if A.Items[I].Name <> B.Items[I].Name then Exit(False);
    if A.Items[I].IsConst <> B.Items[I].IsConst then Exit(False);
    if not TypesEqual(A.Items[I].ParamType, B.Items[I].ParamType) then
      Exit(False);
  end;
  Result := True;
end;

function FieldsEqual(A, B: TBindingFieldList): Boolean;
var I: Integer;
begin
  if A.Count <> B.Count then Exit(False);
  for I := 0 to A.Count - 1 do
  begin
    if A.Items[I].Name <> B.Items[I].Name then Exit(False);
    if A.Items[I].BitWidth <> B.Items[I].BitWidth then Exit(False);
    if not TypesEqual(A.Items[I].FieldType, B.Items[I].FieldType) then
      Exit(False);
  end;
  Result := True;
end;

function EnumConstsEqual(A, B: TBindingEnumConstList): Boolean;
var I: Integer;
begin
  if A.Count <> B.Count then Exit(False);
  for I := 0 to A.Count - 1 do
  begin
    if A.Items[I].Name <> B.Items[I].Name then Exit(False);
    if A.Items[I].Value <> B.Items[I].Value then Exit(False);
  end;
  Result := True;
end;

function DeclsEqual(A, B: TBindingDecl): Boolean;
begin
  if A.ClassType <> B.ClassType then Exit(False);
  if A.Name <> B.Name then Exit(False);
  if A is TBindingFunction then
  begin
    Result :=
      (TBindingFunction(A).IsVarArgs = TBindingFunction(B).IsVarArgs) and
      (TBindingFunction(A).CallingConv = TBindingFunction(B).CallingConv) and
      TypesEqual(TBindingFunction(A).ReturnType, TBindingFunction(B).ReturnType) and
      ParamsEqual(TBindingFunction(A).Params, TBindingFunction(B).Params);
    Exit;
  end;
  if A is TBindingRecord then
  begin
    { ByteSize is deliberately NOT compared: a record whose fields
      are emitted identically (e.g. both have `p: Pointer`) will
      legitimately have different total sizes on Win32 vs Win64
      because Pascal's Pointer/clong/etc. adapt at compile time.
      Splitting on the C-reported total size would emit two visually
      identical record bodies under different $IFDEFs. Field-level
      divergence (e.g. `cint` vs `clonglong`) is what should drive
      a real split, and that flows through FieldsEqual. }
    Result :=
      (TBindingRecord(A).IsUnion = TBindingRecord(B).IsUnion) and
      (TBindingRecord(A).IsForwardDecl = TBindingRecord(B).IsForwardDecl) and
      FieldsEqual(TBindingRecord(A).Fields, TBindingRecord(B).Fields);
    Exit;
  end;
  if A is TBindingEnum then
  begin
    Result :=
      TypesEqual(TBindingEnum(A).UnderlyingType, TBindingEnum(B).UnderlyingType) and
      EnumConstsEqual(TBindingEnum(A).Constants, TBindingEnum(B).Constants);
    Exit;
  end;
  if A is TBindingTypedef then
  begin
    Result := TypesEqual(TBindingTypedef(A).Aliased, TBindingTypedef(B).Aliased);
    Exit;
  end;
  if A is TBindingMacroConst then
  begin
    Result :=
      (TBindingMacroConst(A).MacroKind = TBindingMacroConst(B).MacroKind) and
      (TBindingMacroConst(A).RawValue  = TBindingMacroConst(B).RawValue);
    Exit;
  end;
  Result := False;
end;

type
  TDeclItemList = TList<TBindingDecl>;

procedure WrapPlatformGuard(Output: TStringList;
                            Targets, Platforms: TStringList;
                            StartIdx: Integer;
                            const OpenBracket, CloseBracket: string);
var
  Cond: string;
  I: Integer;
begin
  if (Targets = nil) or (Targets.Count = 0) then Exit;
  if (Platforms = nil) or (Platforms.Count = 0) then Exit;
  if Output.Count <= StartIdx then Exit;

  if Platforms.Count = 1 then
    Cond := OpenBracket + 'IFDEF ' + Platforms[0] + CloseBracket
  else
  begin
    Cond := OpenBracket + 'IF';
    for I := 0 to Platforms.Count - 1 do
    begin
      if I > 0 then Cond := Cond + ' or';
      Cond := Cond + ' defined(' + Platforms[I] + ')';
    end;
    Cond := Cond + CloseBracket;
  end;

  Output.Insert(StartIdx, Cond);
  Output.Add(OpenBracket + 'ENDIF' + CloseBracket);
end;

function MergeUnits(const Units: TBindingUnitArray;
                    const Symbols: TStringArray): TBindingUnit;
var
  I, J, K, V, VI: Integer;
  Drained: array of TDeclItemList;
  Taken: array of array of Boolean;
  Result_: TBindingUnit;
  Cur: TBindingDecl;
  Variants: TList<TBindingDecl>;
  VariantPlatforms: TList<TStringList>;
  Match: TBindingDecl;
  AllMatched: Boolean;
  PL: TStringList;
begin
  if Length(Units) <> Length(Symbols) then
    raise Exception.Create('MergeUnits: Units/Symbols length mismatch');
  if Length(Units) = 0 then
    raise Exception.Create('MergeUnits: need at least one input unit');

  Result_ := TBindingUnit.Create;
  for I := 0 to High(Symbols) do
    Result_.Targets.Add(Symbols[I]);

  { Carry over metadata from the first input unit. }
  for I := 0 to Units[0].HeaderPaths.Count - 1 do
    Result_.AddHeader(Units[0].HeaderPaths[I]);
  Result_.CommandLine  := Units[0].CommandLine;
  Result_.ClangVersion := Units[0].ClangVersion;

  { Drain decls out of each input. We do not reparent into Result_
    directly — we may emit some decls and drop others, so we want
    explicit ownership control. }
  SetLength(Drained, Length(Units));
  SetLength(Taken, Length(Units));
  for I := 0 to High(Units) do
  begin
    Drained[I] := TDeclItemList.Create;
    for J := 0 to Units[I].Decls.Count - 1 do
      Drained[I].Add(Units[I].Decls.Items[J]);
    Units[I].Decls.ReleaseAll;
    SetLength(Taken[I], Drained[I].Count);
  end;

  Variants := TList<TBindingDecl>.Create;
  VariantPlatforms := TList<TStringList>.Create;
  try
    { Walk each input unit in order; for each not-yet-taken decl,
      gather variants across the remaining units. This preserves the
      first input's order, then appends novel decls in subsequent
      units' order. }
    for I := 0 to High(Units) do
      for J := 0 to Drained[I].Count - 1 do
      begin
        if Taken[I][J] then Continue;
        Cur := Drained[I][J];
        Taken[I][J] := True;

        Variants.Clear;
        for V := 0 to VariantPlatforms.Count - 1 do
          VariantPlatforms[V].Free;
        VariantPlatforms.Clear;

        Variants.Add(Cur);
        PL := TStringList.Create;
        PL.Add(Symbols[I]);
        VariantPlatforms.Add(PL);

        { Scan all later units for matches by name+kind. }
        for K := I + 1 to High(Units) do
          for V := 0 to Drained[K].Count - 1 do
          begin
            if Taken[K][V] then Continue;
            Match := Drained[K][V];
            if (Match.ClassType <> Cur.ClassType)
               or (Match.Name <> Cur.Name) then Continue;
            Taken[K][V] := True;
            { Match against an existing variant if deep-equal. }
            AllMatched := False;
            for VI := 0 to Variants.Count - 1 do
              if DeclsEqual(Variants[VI], Match) then
              begin
                VariantPlatforms[VI].Add(Symbols[K]);
                Match.Free;
                AllMatched := True;
                Break;
              end;
            if not AllMatched then
            begin
              Variants.Add(Match);
              PL := TStringList.Create;
              PL.Add(Symbols[K]);
              VariantPlatforms.Add(PL);
            end;
            Break;  { each unit contributes at most one match for a given name }
          end;

        { Emit variants. If only one variant and it matched every
          target, leave Platforms empty (unconditional). Else tag
          each variant with its platform set. }
        if (Variants.Count = 1)
           and (VariantPlatforms[0].Count = Length(Symbols)) then
        begin
          Variants[0].Platforms.Clear;
          Result_.Decls.Add(Variants[0]);
        end
        else
          for V := 0 to Variants.Count - 1 do
          begin
            Variants[V].Platforms.Assign(VariantPlatforms[V]);
            Result_.Decls.Add(Variants[V]);
          end;
      end;
  finally
    for V := 0 to VariantPlatforms.Count - 1 do
      VariantPlatforms[V].Free;
    VariantPlatforms.Free;
    Variants.Free;
    for I := 0 to High(Drained) do
      Drained[I].Free;
  end;

  Result := Result_;
end;

end.
