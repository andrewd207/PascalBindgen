{ Blaise ncurses demo — a tiny interactive counter TUI.

  Drives libncurses through the generated ncurses_blaise.pas binding:
  initscr / cbreak / noecho / curs_set to set up a raw full-screen
  session, box() for a border, move()+addstr() to paint, getch() to
  read keys, endwin() to restore the terminal on exit.

  Keys:  +/=  increment    -/_  decrement    q  quit

  Note: printw/mvprintw are C varargs, which Blaise can't call yet, so
  this demo formats with IntToStr and paints via move()+addstr(). }
program demo;

uses
  ncurses_blaise;

const
  KEY_Q     = 113;  { 'q' }
  KEY_PLUS  = 43;   { '+' }
  KEY_EQ    = 61;   { '=' }
  KEY_MINUS = 45;   { '-' }
  KEY_UNDER = 95;   { '_' }

{ Heads-up: ncurses.h has `#define TRUE 1` / `#define FALSE 0`, so the
  binding emits integer consts TRUE/FALSE. Pascal is case-insensitive,
  so those shadow Blaise's own boolean literals True/False inside this
  unit — hence the loop below is driven by the key value directly
  rather than a Boolean flag. }
var
  win: PWINDOW;
  count: Integer;
  ch: Integer;

procedure Paint;
begin
  clear();
  box(win, 0, 0);
  move(1, 3);  addstr(PChar('pascal_bindgen — Blaise ncurses demo'));
  move(3, 3);  addstr(PChar('count = ' + IntToStr(count)));
  move(5, 3);  addstr(PChar('+/= increment   -/_ decrement   q quit'));
  refresh();
end;

begin
  win := initscr();      { returns stdscr }
  cbreak();              { deliver keys immediately, no line buffering }
  noecho();              { don't echo typed characters }
  curs_set(0);           { hide the hardware cursor }

  count := 0;
  ch := 0;
  while ch <> KEY_Q do
  begin
    Paint();
    ch := getch();
    if (ch = KEY_PLUS) or (ch = KEY_EQ) then
      count := count + 1
    else if (ch = KEY_MINUS) or (ch = KEY_UNDER) then
      count := count - 1;
  end;

  endwin();              { restore the terminal }
  WriteLn('final count = ', count);
end.
