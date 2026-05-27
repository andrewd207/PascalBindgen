{ GTK4 demo against the generated bindings.

  A window with a label and a button labelled "Quit (10)". A
  g_timeout_add_seconds timer ticks once per second, decrements
  the counter, updates the button label ("Quit (9)" ... "Quit (0)")
  and quits when the counter hits zero. Clicking the button quits
  immediately. Demonstrates GTK signals + the GLib main-loop timer
  driven entirely through pascal_bindgen-generated externs. }
program demo;

{$mode objfpc}{$H+}

uses
  ctypes, SysUtils, Math, gtk4_fpc;

var
  g_app: PGtkApplication;
  g_button: PGtkWidget;
  g_label: PGtkWidget;
  g_seconds_left: Integer = 60;

procedure update_button_label;
var
  msg: AnsiString;
begin
  msg := Format('Quit (%d)', [g_seconds_left]);
  gtk_button_set_label(PGtkButton(g_button), PAnsiChar(msg));
end;

procedure quit_app;
begin
  Writeln('quitting');
  g_application_quit(PGApplication(g_app));
end;

procedure on_clicked(button: Pointer; user_data: Pointer); cdecl;
begin
  Writeln('button clicked');
  quit_app;
end;

function on_tick(user_data: Pointer): cint; cdecl;
begin
  Dec(g_seconds_left);
  Writeln('tick — ', g_seconds_left, 's left');
  if g_seconds_left <= 0 then
  begin
    quit_app;
    Result := 0;  { G_SOURCE_REMOVE — stop firing }
    Exit;
  end;
  update_button_label;
  Result := 1;    { G_SOURCE_CONTINUE — keep firing }
end;

procedure on_activate(app: Pointer; user_data: Pointer); cdecl;
var
  window, box: PGtkWidget;
begin
  window := gtk_application_window_new(PGtkApplication(app));
  gtk_window_set_title(PGtkWindow(window), 'pascal_bindgen + GTK4');
  gtk_window_set_default_size(PGtkWindow(window), 420, 180);

  box := gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_margin_start(box, 24);
  gtk_widget_set_margin_end(box, 24);
  gtk_widget_set_margin_top(box, 24);
  gtk_widget_set_margin_bottom(box, 24);

  g_label := gtk_label_new('Hello from generated bindings!');
  gtk_box_append(PGtkBox(box), g_label);

  g_button := gtk_button_new_with_label('Quit (60)');
  g_signal_connect_data(g_button, 'clicked',
                        GCallback(@on_clicked), nil, nil, 0);
  gtk_box_append(PGtkBox(box), g_button);

  gtk_window_set_child(PGtkWindow(window), box);
  gtk_window_present(PGtkWindow(window));

  g_timeout_add_seconds(1, GSourceFunc(@on_tick), nil);
end;

var
  status: cint;
begin
  { GTK/Cairo do legitimate IEEE-754 math (1.0/0.0 → inf, NaN
    compares, ...) that triggers FPC's default-unmasked FPU
    exceptions. Mask them all so the main loop survives. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);
  g_app := gtk_application_new('org.example.bindgen.demo',
                               G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect_data(g_app, 'activate',
                        GCallback(@on_activate), nil, nil, 0);
  status := g_application_run(PGApplication(g_app), argc, argv);
  g_object_unref(g_app);
  Halt(status);
end.
