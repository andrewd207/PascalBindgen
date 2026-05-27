{ Blaise port of the GTK4 countdown demo.

  Same shape as examples/gtk4/demo.pas (FPC dialect) — a window
  with a label + 'Quit (N)' button, plus a g_timeout_add_seconds
  source that decrements N each tick and quits at zero. Built
  against the 46.8K-line gtk4_blaise.pas the generator produces
  under --blaise.

  Drives GApplication + GObject signals + GLib main-loop timers
  through pure generated externs. }
program demo;

uses
  sysutils, gtk4_blaise;

var
  g_app: PGtkApplication;
  g_button: PGtkWidget;
  g_label: PGtkWidget;
  g_seconds_left: Integer;

procedure update_button_label;
begin
  gtk_button_set_label(PGtkButton(g_button),
                       PChar('Quit (' + IntToStr(g_seconds_left) + ')'));
end;

procedure quit_app;
begin
  WriteLn('quitting');
  g_application_quit(PGApplication(g_app));
end;

procedure on_clicked(button: Pointer; user_data: Pointer);
begin
  WriteLn('button clicked');
  quit_app;
end;

function on_tick(user_data: Pointer): Integer;
begin
  g_seconds_left := g_seconds_left - 1;
  WriteLn('tick — ' + IntToStr(g_seconds_left) + 's left');
  if g_seconds_left <= 0 then
  begin
    quit_app;
    Result := 0;   { G_SOURCE_REMOVE }
    Exit;
  end;
  update_button_label;
  Result := 1;     { G_SOURCE_CONTINUE }
end;

procedure on_activate(app: Pointer; user_data: Pointer);
var
  window: PGtkWidget;
  box: PGtkWidget;
begin
  window := gtk_application_window_new(PGtkApplication(app));
  gtk_window_set_title(PGtkWindow(window), PChar('pascal_bindgen blaise GTK4'));
  gtk_window_set_default_size(PGtkWindow(window), 420, 180);

  box := gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_margin_start(box, 24);
  gtk_widget_set_margin_end(box, 24);
  gtk_widget_set_margin_top(box, 24);
  gtk_widget_set_margin_bottom(box, 24);

  g_label := gtk_label_new(PChar('Hello from generated Blaise bindings!'));
  gtk_box_append(PGtkBox(box), g_label);

  g_button := gtk_button_new_with_label(PChar('Quit (60)'));
  g_signal_connect_data(g_button, PChar('clicked'),
                        GCallback(@on_clicked), nil, nil, 0);
  gtk_box_append(PGtkBox(box), g_button);

  gtk_window_set_child(PGtkWindow(window), box);
  gtk_window_present(PGtkWindow(window));

  g_timeout_add_seconds(1, GSourceFunc(@on_tick), nil);
end;

var
  status: Integer;
begin
  g_seconds_left := 60;

  g_app := gtk_application_new(PChar('org.example.bindgen.blaise.demo'),
                               G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect_data(g_app, PChar('activate'),
                        GCallback(@on_activate), nil, nil, 0);

  { argc/argv aren't exposed as builtins in Blaise; pass 0/nil. GTK
    parses argv only for built-in flags (--display, --gtk-debug),
    which we don't need for a toy demo. }
  status := g_application_run(PGApplication(g_app), 0, nil);
  g_object_unref(g_app);
  Halt(status);
end.
