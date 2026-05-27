/* Cross-include sample: pulls in a user-side header to exercise
   the parser's "admit user includes, skip system headers" filter. */
#ifndef PBG_SAMPLE_WITH_INCLUDE_H
#define PBG_SAMPLE_WITH_INCLUDE_H

#include <stddef.h>          /* system header — should NOT appear in output */
#include "sample_include.h"  /* user header   — SHOULD appear in output    */

/* Function in the main file, using a typedef from the user include. */
my_byte_t main_file_func(my_byte_t x);

#endif
