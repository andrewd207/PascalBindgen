{ Minimal round-trip demo against libz, using exactly the four
  extern declarations pascal_bindgen produced for zlibVersion,
  compress, uncompress, and compressBound. Trimmed in by hand from
  examples/zlib/zlib_fpc.pas so the program can compile while the
  rest of that generated unit waits on the gaps in README.adoc.

  Each external below is a verbatim line from the generated output,
  proving the parameter shapes, cdecl convention, and library name
  the generator chose are correct in isolation.

  Build:  ./build.sh
  Run:    ./demo  }
program demo;

{$mode objfpc}{$H+}

uses
  SysUtils, ctypes;

type
  { Hand-written stand-ins for the zconf.h typedefs (README §1). }
  Bytef  = cuchar;
  uLong  = culong;
  uLongf = culong;
  { Named pointer aliases — required because FPC rejects '^X' as a
    parameter type. The v1 emitter writes '^Bytef' inline; until that
    is fixed (README §5), every '^X' must be aliased manually. }
  PBytef  = ^Bytef;
  PuLongf = ^uLongf;

{ ---- declarations lifted from zlib_fpc.pas, parameter types swapped
       from '^Bytef' / '^uLongf' to the named PBytef / PuLongf ---- }

function zlibVersion: PAnsiChar;
  cdecl; external 'libz' name 'zlibVersion';

function compress(dest: PBytef; destLen: PuLongf;
                  source: PBytef; sourceLen: uLong): cint;
  cdecl; external 'libz' name 'compress';

function compressBound(sourceLen: uLong): uLong;
  cdecl; external 'libz' name 'compressBound';

function uncompress(dest: PBytef; destLen: PuLongf;
                    source: PBytef; sourceLen: uLong): cint;
  cdecl; external 'libz' name 'uncompress';

{ ---- demo ---- }

const
  Source: AnsiString =
    'Hello, zlib from Pascal! Hello, zlib from Pascal! ' +
    'Hello, zlib from Pascal! Hello, zlib from Pascal! ' +
    'Hello, zlib from Pascal! Hello, zlib from Pascal!';
  Z_OK = 0;

procedure Die(const Msg: string);
begin
  WriteLn(StdErr, 'demo: ', Msg);
  Halt(1);
end;

var
  SrcLen, BufLen, FinalLen, RestoredLen: uLong;
  Compressed, Restored: array of Bytef;
  RC: cint;
begin
  WriteLn('zlib version: ', zlibVersion);

  SrcLen := Length(Source);
  BufLen := compressBound(SrcLen);
  SetLength(Compressed, BufLen);

  FinalLen := BufLen;
  RC := compress(@Compressed[0], @FinalLen,
                 PByte(@Source[1]), SrcLen);
  if RC <> Z_OK then Die(Format('compress -> %d', [RC]));
  WriteLn(Format('compressed %d -> %d bytes', [SrcLen, FinalLen]));

  SetLength(Restored, SrcLen);
  RestoredLen := SrcLen;
  RC := uncompress(@Restored[0], @RestoredLen,
                   @Compressed[0], FinalLen);
  if RC <> Z_OK then Die(Format('uncompress -> %d', [RC]));
  if RestoredLen <> SrcLen then Die('length mismatch');

  if CompareMem(@Source[1], @Restored[0], SrcLen) then
    WriteLn('round-trip OK')
  else
    Die('payload mismatch');
end.
