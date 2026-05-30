' demo_rqbasic.bas — SDL2 hello-world via pascal_bindgen --rqbasic.
' Opens a window, polls events, fades the background through a hue
' cycle, exits on window-close (SDL_QUIT). Demonstrates:
'
'   - opaque-handle FFI: PSDL_Window / PSDL_Renderer flow through
'     create/use/destroy without rqbasic needing to know the layout
'   - union padding: DIM ev AS SDL_Event allocates the full 56-byte
'     storage even though only the `type_` field is typed, so
'     SDL_PollEvent's per-event-class write doesn't smash neighbours
'   - integer-by-value FFI: SDL_SetRenderDrawColor takes four BYTEs

$INCLUDE "sdl2_rqbasic.bas"

DIM win AS PSDL_Window
DIM ren AS PSDL_Renderer
DIM ev AS TSDL_Event
DIM running AS INTEGER
DIM tick AS INTEGER

IF SDL_Init(SDL_INIT_VIDEO) <> 0 THEN
  PRINT "SDL_Init failed"
  HALT
END IF

win = SDL_CreateWindow(PCHAR("rqbasic + SDL2"), _
                       &H1FFF0000, &H1FFF0000, _   ' SDL_WINDOWPOS_UNDEFINED x2
                       640, 480, SDL_WINDOW_SHOWN)
ren = SDL_CreateRenderer(win, -1, 0)

running = 1
tick = 0
WHILE running = 1
  WHILE SDL_PollEvent(VARPTR(ev)) <> 0
    IF ev._type = SDL_QUIT THEN running = 0
  WEND

  ' Cycle background through a teal-magenta-amber hue based on tick.
  ' Each channel is a 0..255 sin-like wave, phase-offset 120deg apart.
  DIM r AS INTEGER
  DIM g AS INTEGER
  DIM b AS INTEGER
  r = 128 + ((tick     ) MOD 256) - 128
  g = 128 + ((tick + 85) MOD 256) - 128
  b = 128 + ((tick +170) MOD 256) - 128
  IF r < 0 THEN r = -r
  IF g < 0 THEN g = -g
  IF b < 0 THEN b = -b
  SDL_SetRenderDrawColor(ren, r, g, b, 255)
  SDL_RenderClear(ren)
  SDL_RenderPresent(ren)

  SDL_Delay(16)
  tick = tick + 2
WEND

SDL_DestroyRenderer(ren)
SDL_DestroyWindow(win)
SDL_Quit_()   ' renamed by --prefix-types to disambiguate from CONST SDL_QUIT
