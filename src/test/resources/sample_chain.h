/* Forces the canonical-primitive chase: aliases a system typedef
   (size_t) so the system decl gets filtered out, leaving the unit
   referencing 'size_t' without ever declaring it — unless the
   emitter falls back to the canonical primitive. */
#ifndef PBG_SAMPLE_CHAIN_H
#define PBG_SAMPLE_CHAIN_H

#include <stddef.h>

typedef size_t my_size_t;

my_size_t buffer_length(my_size_t hint);

#endif
