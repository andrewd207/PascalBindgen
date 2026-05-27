#ifndef PBG_SAMPLE_H
#define PBG_SAMPLE_H

/** A point on a 2D grid. */
typedef struct Point {
    int x;
    int y;
} Point;

enum Color {
    RED   = 0,
    GREEN = 1,
    BLUE  = 2
};

union Value {
    int   as_int;
    float as_float;
};

typedef int my_int_t;

int add(int a, int b);
void greet(const char *name);

#endif
