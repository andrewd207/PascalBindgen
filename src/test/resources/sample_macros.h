/* Exercises B3 integer-literal macro extraction.
   - decimal literal
   - hex literal (uppercase prefix)
   - hex literal with U suffix
   - decimal literal with L suffix
   - function-like macro (must be skipped)
   - non-integer body (must be skipped)
   - parenthesized / expression body (must be skipped for v1) */
#ifndef PBG_SAMPLE_MACROS_H
#define PBG_SAMPLE_MACROS_H

#define M_OK         0
#define M_BUF_SIZE   4096
#define M_FLAG_A     0x01
#define M_FLAG_B     0xFFu
#define M_BIG        1000000L

#define M_FUNCLIKE(x) ((x) + 1)
#define M_EXPR       (1 << 3)
#define M_STR        "hello"

#endif
