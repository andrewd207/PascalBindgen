/* Pointer-arg functions force the emitter to synthesise named
   'PX = ^X' aliases — FPC rejects bare '^X' in parameter or return
   types. */
#ifndef PBG_SAMPLE_PTR_H
#define PBG_SAMPLE_PTR_H

typedef struct Widget {
    int kind;
} Widget;

Widget *make_widget(int kind);
int widget_kind(Widget *w);
void widget_kinds(Widget **ws, int n);

#endif
