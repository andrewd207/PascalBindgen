/* Exercises B2 function-pointer typedef synthesis:
   - typedef of pointer-to-function
   - struct field of the typedef'd function-pointer type
   - struct field of an inline function-pointer (no typedef)
   - function parameter typed by the typedef (must not inline) */
#ifndef PBG_SAMPLE_FUNCPTR_H
#define PBG_SAMPLE_FUNCPTR_H

typedef int (*compare_fn)(const void* a, const void* b);

struct sorter {
    compare_fn cmp;
    void (*on_swap)(int i, int j);
};

void sort_run(struct sorter* s, compare_fn cb);

#endif
