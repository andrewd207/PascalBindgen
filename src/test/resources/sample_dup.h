/* Forward-decl + later completion of the same struct — libclang
   surfaces both as separate cursors with the same spelling, and
   the v1 emitter used to declare the record twice (zlib's gzFile_s
   pattern). */
#ifndef PBG_SAMPLE_DUP_H
#define PBG_SAMPLE_DUP_H

typedef struct OpaqueThing *OpaqueThingPtr;

struct OpaqueThing {
    int payload;
};

#endif
