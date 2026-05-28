program blaise_windows_demo;

uses win_demo;

const
  STD_OUTPUT_HANDLE: DWORD = $FFFFFFF5;  { (DWORD)-11 }

  { 100-ns ticks between 1601-01-01 (FILETIME epoch) and 1970-01-01 (Unix epoch). }
  EPOCH_DIFF_HI: DWORD = 27111902;
  EPOCH_DIFF_LO: DWORD = 3577643008;

procedure WriteStdout(const s: string);
var
  h: HANDLE;
  written: DWORD;
begin
  h := GetStdHandle(STD_OUTPUT_HANDLE);
  WriteFile_(h, PChar(s), Length(s), @written, nil);
end;

procedure WriteLine(const s: string);
begin
  WriteStdout(s);
  WriteStdout(#13#10);
end;

function UIntToHex8(v: DWORD): string;
const
  digits = '0123456789ABCDEF';
var
  i, d: Integer;
  buf: string;
begin
  buf := '';
  for i := 7 downto 0 do
  begin
    d := (v shr (i * 4)) and $F;
    buf := buf + Copy(digits, d + 1, 1);
  end;
  Result := buf;
end;

var
  ft: FILETIME;
begin
  WriteLine('hello from blaise on win64');
  WriteLine('calling kernel32 via pascal_bindgen-generated unit...');

  GetSystemTimeAsFileTime(@ft);

  WriteStdout('FILETIME.high = $');
  WriteStdout(UIntToHex8(ft.dwHighDateTime));
  WriteStdout('  low = $');
  WriteLine(UIntToHex8(ft.dwLowDateTime));

  WriteLine('sleeping 250ms...');
  Sleep_(250);
  WriteLine('done.');
end.
