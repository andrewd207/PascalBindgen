program blaise_winapi_form_demo;

uses win_gui;

const
  TIMER_ID: UINT_PTR = 1;
  BTN_ID:   UINT_PTR = 100;
  CW_USEDEFAULT_VAL: Integer = -2147483648;
  BUF_LEN = 128;

type
  TUtf16Buf = array[0..127] of Word;

var
  g_secondsLeft: Integer;
  g_label:       HWND;
  g_button:      HWND;

  g_titleBuf:  TUtf16Buf;
  g_clsBuf:    TUtf16Buf;
  g_btnTxt:    TUtf16Buf;
  g_lblBuf:    TUtf16Buf;
  g_staticCls: TUtf16Buf;
  g_buttonCls: TUtf16Buf;

procedure FillUtf16(buf: PWord; const s: string);
var
  i, n: Integer;
  p: PWord;
begin
  n := Length(s);
  if n >= BUF_LEN then n := BUF_LEN - 1;
  { Blaise strings are 0-indexed: s[0] is the first character. }
  for i := 0 to n - 1 do
  begin
    p := PWord(PtrUInt(buf) + UInt64(i * 2));
    p^ := Word(Ord(s[i]));
  end;
  p := PWord(PtrUInt(buf) + UInt64(n * 2));
  p^ := 0;
end;

procedure UpdateLabel;
var
  msg: string;
begin
  if g_secondsLeft > 0 then
    msg := 'Time left: ' + IntToStr(g_secondsLeft) + 's'
  else
    msg := 'Time up - click Close to quit';
  FillUtf16(@g_lblBuf[0], msg);
  SetWindowTextW(g_label, @g_lblBuf[0]);
end;

function FormWndProc(hwnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT;
var
  hiWord: UInt32;
  ctrlId: UInt32;
begin
  Result := 0;
  case msg of
    WM_COMMAND:
    begin
      ctrlId := UInt32(wp and $FFFF);
      hiWord := UInt32((wp shr 16) and $FFFF);
      if (ctrlId = UInt32(BTN_ID)) and (hiWord = BN_CLICKED) then
      begin
        KillTimer(hwnd, TIMER_ID);
        DestroyWindow(hwnd);
        Exit;
      end;
    end;
    WM_TIMER:
    begin
      if wp = TIMER_ID then
      begin
        if g_secondsLeft > 0 then
        begin
          Dec(g_secondsLeft);
          UpdateLabel;
        end;
        if g_secondsLeft = 0 then
          KillTimer(hwnd, TIMER_ID);
      end;
      Exit;
    end;
    WM_CLOSE:
    begin
      KillTimer(hwnd, TIMER_ID);
      DestroyWindow(hwnd);
      Exit;
    end;
    WM_DESTROY:
    begin
      PostQuitMessage(0);
      Exit;
    end;
  end;
  Result := DefWindowProcW(hwnd, msg, wp, lp);
end;

var
  wc:    WNDCLASSEXW;
  hwnd:  HWND;
  m:     MSG;
  gotIt: Integer;

begin
  g_secondsLeft := 10;

  FillUtf16(@g_clsBuf[0],    'BlaiseFormDemo');
  FillUtf16(@g_titleBuf[0],  'Blaise + pascal_bindgen demo');
  FillUtf16(@g_btnTxt[0],    'Close');
  FillUtf16(@g_staticCls[0], 'STATIC');
  FillUtf16(@g_buttonCls[0], 'BUTTON');
  FillUtf16(@g_lblBuf[0],    'Time left: 10s');

  wc.cbSize        := SizeOf(WNDCLASSEXW);
  wc.style         := 0;
  wc.lpfnWndProc   := WNDPROC(@FormWndProc);
  wc.cbClsExtra    := 0;
  wc.cbWndExtra    := 0;
  wc.hInstance     := nil;
  wc.hIcon         := nil;
  wc.hCursor       := LoadCursorW(nil, Pointer(UInt64(IDC_ARROW)));
  wc.hbrBackground := Pointer(UInt64(COLOR_WINDOW + 1));
  wc.lpszMenuName  := nil;
  wc.lpszClassName := @g_clsBuf[0];
  wc.hIconSm       := nil;

  if RegisterClassExW(@wc) = 0 then
  begin
    WriteLn('RegisterClassExW failed');
    Halt(1);
  end;

  hwnd := CreateWindowExW(
    0,
    @g_clsBuf[0],
    @g_titleBuf[0],
    WS_OVERLAPPEDWINDOW or WS_VISIBLE,
    CW_USEDEFAULT_VAL, CW_USEDEFAULT_VAL, 360, 160,
    nil, nil, nil, nil);
  if hwnd = nil then
  begin
    WriteLn('CreateWindowExW failed');
    Halt(2);
  end;

  g_label := CreateWindowExW(
    0,
    @g_staticCls[0],
    @g_lblBuf[0],
    WS_VISIBLE or WS_CHILD,
    20, 20, 320, 30,
    hwnd, Pointer(UInt64(99)), nil, nil);
  if g_label = nil then WriteLn('label create failed');

  g_button := CreateWindowExW(
    0,
    @g_buttonCls[0],
    @g_btnTxt[0],
    WS_VISIBLE or WS_CHILD or BS_DEFPUSHBUTTON,
    130, 70, 100, 30,
    hwnd, Pointer(BTN_ID), nil, nil);
  if g_button = nil then WriteLn('button create failed');

  SetTimer(hwnd, TIMER_ID, 1000, nil);
  ShowWindow(hwnd, SW_SHOW);
  UpdateWindow(hwnd);

  while True do
  begin
    gotIt := GetMessageW(@m, nil, 0, 0);
    if gotIt <= 0 then break;
    TranslateMessage(@m);
    DispatchMessageW(@m);
  end;
end.
