/* Identifiers that collide with Pascal reserved words. The emitter
   must escape these so the generated unit still parses. */
#ifndef PBG_SAMPLE_RESERVED_H
#define PBG_SAMPLE_RESERVED_H

int do_action(int file, int type, int label, int mode);

struct WithReservedFields {
    int begin;
    int end;
    int repeat;
};

int procedure_func(int in, int out);

#endif
