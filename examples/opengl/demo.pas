{ Headless OpenGL demo against the generator output.

  Spins up a 1x1 EGL pbuffer surface against EGL_DEFAULT_DISPLAY,
  binds the OpenGL API, creates a context, makes it current, and
  prints glGetString(VENDOR/RENDERER/VERSION) — proof that the
  generator's egl_fpc.pas + gl_fpc.pas units actually drive a real
  OpenGL driver without a window manager.

  No X11 / Wayland / GLFW / SDL dependency. Useful as a smoke test
  for the GPU stack from a TTY. }
program demo;

{$mode objfpc}{$H+}

uses
  ctypes, SysUtils, egl_fpc, gl_fpc;

const
  { EGL_DEFAULT_DISPLAY = (EGLNativeDisplayType)0 — the cast-form
    macro doesn't survive the v1 integer-literal-only macro filter,
    so we hardcode nil here. }
  EGL_DEFAULT_DISPLAY = nil;
  { Mesa surfaceless platform — present in eglmesaext.h, not in
    the base egl.h, so we hardcode the value here. Lets us skip
    Xlib/Wayland entirely for the smoke test. }
  EGL_PLATFORM_SURFACELESS_MESA = $31DD;

procedure Die(const where: string);
begin
  Writeln(StdErr, where, ' failed: EGL error 0x', IntToHex(eglGetError, 4));
  Halt(1);
end;

var
  display: EGLDisplay;
  config: EGLConfig;
  surface: EGLSurface;
  ctx: EGLContext;
  major, minor, numConfigs: cint;
  configAttribs: array[0..6] of cint;
  surfaceAttribs: array[0..4] of cint;
  s: Pcuchar;
begin
  display := eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                   EGL_DEFAULT_DISPLAY, nil);
  if display = nil then Die('eglGetPlatformDisplay');

  if eglInitialize(display, @major, @minor) = 0 then Die('eglInitialize');
  Writeln(Format('EGL %d.%d initialised', [major, minor]));

  if eglBindAPI(EGL_OPENGL_API) = 0 then Die('eglBindAPI(GL)');

  configAttribs[0] := EGL_SURFACE_TYPE;
  configAttribs[1] := EGL_PBUFFER_BIT;
  configAttribs[2] := EGL_RENDERABLE_TYPE;
  configAttribs[3] := EGL_OPENGL_BIT;
  configAttribs[4] := EGL_NONE;
  configAttribs[5] := 0;
  configAttribs[6] := 0;

  if eglChooseConfig(display, @configAttribs[0], @config, 1,
                     @numConfigs) = 0 then Die('eglChooseConfig');
  if numConfigs = 0 then Die('no matching EGLConfig');

  surfaceAttribs[0] := EGL_WIDTH;
  surfaceAttribs[1] := 1;
  surfaceAttribs[2] := EGL_HEIGHT;
  surfaceAttribs[3] := 1;
  surfaceAttribs[4] := EGL_NONE;

  surface := eglCreatePbufferSurface(display, config, @surfaceAttribs[0]);
  if surface = nil then Die('eglCreatePbufferSurface');

  ctx := eglCreateContext(display, config, nil, nil);
  if ctx = nil then Die('eglCreateContext');

  if eglMakeCurrent(display, surface, surface, ctx) = 0 then
    Die('eglMakeCurrent');

  s := glGetString(GL_VENDOR);
  Writeln('GL_VENDOR    : ', PAnsiChar(s));
  s := glGetString(GL_RENDERER);
  Writeln('GL_RENDERER  : ', PAnsiChar(s));
  s := glGetString(GL_VERSION);
  Writeln('GL_VERSION   : ', PAnsiChar(s));

  eglMakeCurrent(display, nil, nil, nil);
  eglDestroyContext(display, ctx);
  eglDestroySurface(display, surface);
  eglTerminate(display);
  Writeln('clean shutdown');
end.
