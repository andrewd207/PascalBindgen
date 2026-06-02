{
  This file is part of the pascal_bindgen project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

{ bindgen.blob — small heap-resizable byte buffer with file I/O.

  Exists because FPC's TFileStream / TStringList APIs and Blaise's
  TOutputStream / TStreamWriter APIs are different enough that
  IFDEF-bridging them in every call site is noisy. A bespoke blob
  with Append + SaveToFile / LoadFromFile lets the tests and
  emitters write the same code under both compilers. }
unit bindgen.blob;

{$IFDEF FPC}
{$mode delphi}{$H+}
{$ENDIF}

interface

uses
  SysUtils
  {$IFNDEF FPC}, streams{$ENDIF};

type
  { Blaise has no PByte in its RTL but does parse `type PByte = ^Byte`.
    Note: indexing (`P[i]`) is still rejected — use pointer arithmetic
    via PtrUInt + Move/_Memcpy. }
  {$IFNDEF FPC}
  PByte = ^Byte;
  {$ENDIF}

  TMemoryBlob = class
  private
    FData: PByte;
    FSize: PtrUInt;
    FCapacity: PtrUInt;
    procedure Grow(NeededCapacity: PtrUInt);
  public
    constructor Create;
    destructor Destroy; override;
    procedure AppendBytes(P: Pointer; N: PtrUInt);
    procedure AppendString(S: string);
    procedure AppendLine(S: string);
    procedure SaveToFile(Path: string);
    procedure LoadFromFile(Path: string);
    function AsString: string;
    property Size: PtrUInt read FSize;
    property Data: PByte read FData;
  end;

implementation

{ Blaise has no RTL Move; FPC does. Bind libc memcpy directly under
  Blaise; under FPC delegate to the RTL Move. Pointer/Pointer signature
  sidesteps Blaise's restriction on @ of var/const parameters. }
{$IFDEF FPC}
procedure _Memcpy(Dst, Src: Pointer; N: PtrUInt);
begin
  Move(Src^, Dst^, N);
end;
{$ELSE}
procedure _Memcpy(Dst, Src: Pointer; N: Int64); external name 'memcpy';
{$ENDIF}

constructor TMemoryBlob.Create;
begin
  inherited Create;
  FData := nil;
  FSize := 0;
  FCapacity := 0;
end;

destructor TMemoryBlob.Destroy;
begin
  if FData <> nil then FreeMem(FData);
  inherited Destroy;
end;

procedure TMemoryBlob.Grow(NeededCapacity: PtrUInt);
var
  NewCap: PtrUInt;
begin
  if NeededCapacity <= FCapacity then Exit;
  NewCap := FCapacity;
  if NewCap = 0 then NewCap := 64;
  while NewCap < NeededCapacity do NewCap := NewCap * 2;
  { FPC's ReallocMem is a procedure (in-place via var); Blaise's
    returns the new pointer. }
  {$IFDEF FPC}
  ReallocMem(FData, NewCap);
  {$ELSE}
  FData := ReallocMem(FData, NewCap);
  {$ENDIF}
  FCapacity := NewCap;
end;

procedure TMemoryBlob.AppendBytes(P: Pointer; N: PtrUInt);
var
  Dest: Pointer;
begin
  if N = 0 then Exit;
  Grow(FSize + N);
  { Avoid indexing FData as ^Byte: Blaise has no PByte. Compute the
    write address via PtrUInt arithmetic and Move into it. }
  Dest := Pointer(PtrUInt(FData) + FSize);
  _Memcpy(Dest, P, N);
  FSize := FSize + N;
end;

procedure TMemoryBlob.AppendString(S: string);
var
  L: PtrUInt;
begin
  L := Length(S);
  if L = 0 then Exit;
  AppendBytes(PChar(S), L);
end;

procedure TMemoryBlob.AppendLine(S: string);
var
  NL: Byte;
begin
  AppendString(S);
  NL := 10;
  AppendBytes(@NL, 1);
end;

{$IFDEF FPC}
procedure TMemoryBlob.SaveToFile(Path: string);
var
  F: File;
begin
  AssignFile(F, Path);
  Rewrite(F, 1);
  try
    if FSize > 0 then BlockWrite(F, FData^, FSize);
  finally
    CloseFile(F);
  end;
end;

procedure TMemoryBlob.LoadFromFile(Path: string);
var
  F: File;
  Sz: Int64;
begin
  AssignFile(F, Path);
  Reset(F, 1);
  try
    Sz := FileSize(F);
    FSize := 0;
    Grow(Sz);
    if Sz > 0 then BlockRead(F, FData^, Sz);
    FSize := Sz;
  finally
    CloseFile(F);
  end;
end;
{$ELSE}
procedure TMemoryBlob.SaveToFile(Path: string);
var
  S: TFileOutputStream;
begin
  S := TFileOutputStream.Create(Path);
  try
    if FSize > 0 then S.Write(FData, FSize);
  finally
    S.Close;
    S.Free;
  end;
end;

procedure TMemoryBlob.LoadFromFile(Path: string);
var
  S: TFileInputStream;
  { Blaise rejects const-expr array bounds; literal 4095 = 4096-1. }
  Buf: array[0..4095] of Byte;
  Got: Integer;
begin
  FSize := 0;
  S := TFileInputStream.Create(Path);
  try
    repeat
      Got := S.Read(@Buf[0], 4096);
      if Got > 0 then AppendBytes(@Buf[0], Got);
    until Got <= 0;
  finally
    S.Close;
    S.Free;
  end;
end;
{$ENDIF}

function TMemoryBlob.AsString: string;
begin
  SetLength(Result, FSize);
  if FSize > 0 then _Memcpy(PChar(Result), FData, FSize);
end;

end.
