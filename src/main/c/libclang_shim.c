/*
 * libclang_shim — a thin C shim around libclang that hides every
 * by-value struct (CXCursor, CXString, CXSourceLocation, ...) behind
 * pointers and scalars. Lets a Pascal frontend that doesn't implement
 * the SysV >16-byte struct-return ABI talk to libclang.
 *
 * Ownership rules
 * ---------------
 * - Anything returned as `pbg_*` (opaque pointer) is heap-allocated by
 *   the shim and must be freed via the matching pbg_*_dispose call.
 * - Strings returned via const char* are owned by the shim; release
 *   with pbg_free_string. They are interned/copied; libclang's own
 *   CXString is disposed inside the shim before returning.
 */

#include "clang-c/Index.h"
#include <stdlib.h>
#include <string.h>

typedef struct PbgIndex {
    CXIndex idx;
} PbgIndex;

typedef struct PbgTU {
    CXTranslationUnit tu;
} PbgTU;

typedef struct PbgCursor {
    CXCursor c;
} PbgCursor;

/* --- index --- */

PbgIndex* pbg_index_create(int exclude_pch, int display_diag) {
    PbgIndex* p = (PbgIndex*)malloc(sizeof(*p));
    if (!p) return NULL;
    p->idx = clang_createIndex(exclude_pch, display_diag);
    if (!p->idx) { free(p); return NULL; }
    return p;
}

void pbg_index_dispose(PbgIndex* p) {
    if (!p) return;
    clang_disposeIndex(p->idx);
    free(p);
}

/* --- translation unit --- */

/* Returns 0 on success, nonzero CXErrorCode otherwise. */
int pbg_parse_tu(PbgIndex* p,
                 const char* filename,
                 const char* const* args, int nargs,
                 PbgTU** out_tu) {
    *out_tu = NULL;
    CXTranslationUnit tu = NULL;
    enum CXErrorCode rc = clang_parseTranslationUnit2(
        p->idx, filename, args, nargs, NULL, 0,
        CXTranslationUnit_SkipFunctionBodies,
        &tu);
    if (rc != CXError_Success) return (int)rc;
    PbgTU* w = (PbgTU*)malloc(sizeof(*w));
    if (!w) { clang_disposeTranslationUnit(tu); return -1; }
    w->tu = tu;
    *out_tu = w;
    return 0;
}

void pbg_tu_dispose(PbgTU* p) {
    if (!p) return;
    clang_disposeTranslationUnit(p->tu);
    free(p);
}

unsigned pbg_tu_num_diagnostics(PbgTU* p) {
    return clang_getNumDiagnostics(p->tu);
}

/* Caller frees via pbg_free_string. */
const char* pbg_tu_diagnostic(PbgTU* p, unsigned i) {
    CXDiagnostic d = clang_getDiagnostic(p->tu, i);
    CXString s = clang_formatDiagnostic(d, clang_defaultDiagnosticDisplayOptions());
    const char* raw = clang_getCString(s);
    char* copy = raw ? strdup(raw) : NULL;
    clang_disposeString(s);
    clang_disposeDiagnostic(d);
    return copy;
}

/* --- cursor --- */

static PbgCursor* wrap_cursor(CXCursor c) {
    PbgCursor* w = (PbgCursor*)malloc(sizeof(*w));
    if (!w) return NULL;
    w->c = c;
    return w;
}

void pbg_cursor_dispose(PbgCursor* p) {
    if (p) free(p);
}

PbgCursor* pbg_tu_cursor(PbgTU* p) {
    return wrap_cursor(clang_getTranslationUnitCursor(p->tu));
}

int pbg_cursor_kind(PbgCursor* p) {
    return (int)clang_getCursorKind(p->c);
}

/* Caller frees via pbg_free_string. */
const char* pbg_cursor_spelling(PbgCursor* p) {
    CXString s = clang_getCursorSpelling(p->c);
    const char* raw = clang_getCString(s);
    char* copy = raw ? strdup(raw) : NULL;
    clang_disposeString(s);
    return copy;
}

const char* pbg_kind_spelling(int kind) {
    CXString s = clang_getCursorKindSpelling((enum CXCursorKind)kind);
    const char* raw = clang_getCString(s);
    char* copy = raw ? strdup(raw) : NULL;
    clang_disposeString(s);
    return copy;
}

/* Fill out_file (caller frees), out_line, out_col. out_file is NULL
 * if location is not in a file (builtin, command-line, ...). */
void pbg_cursor_location(PbgCursor* p,
                         const char** out_file,
                         unsigned* out_line,
                         unsigned* out_col) {
    CXSourceLocation loc = clang_getCursorLocation(p->c);
    CXFile file = NULL;
    unsigned line = 0, col = 0, off = 0;
    clang_getFileLocation(loc, &file, &line, &col, &off);
    *out_line = line;
    *out_col = col;
    if (file) {
        CXString s = clang_getFileName(file);
        const char* raw = clang_getCString(s);
        *out_file = raw ? strdup(raw) : NULL;
        clang_disposeString(s);
    } else {
        *out_file = NULL;
    }
}

/* Returns 1 if this cursor's location is inside the translation unit's
 * main file (i.e. the user's header), 0 otherwise. */
int pbg_cursor_in_main_file(PbgCursor* p) {
    CXSourceLocation loc = clang_getCursorLocation(p->c);
    return clang_Location_isFromMainFile(loc) ? 1 : 0;
}

/* Raw doc comment text attached to this cursor (Doxygen / //! / star-star block).
 * NULL when there is no attached comment. Caller frees via pbg_free_string. */
const char* pbg_cursor_raw_comment(PbgCursor* p) {
    CXString s = clang_Cursor_getRawCommentText(p->c);
    const char* raw = clang_getCString(s);
    char* copy = raw ? strdup(raw) : NULL;
    clang_disposeString(s);
    return copy;
}

/* CXCursorKind constants we care about. Stable across libclang versions. */
int pbg_kind_function_decl(void)  { return (int)CXCursor_FunctionDecl; }
int pbg_kind_struct_decl(void)    { return (int)CXCursor_StructDecl; }
int pbg_kind_union_decl(void)     { return (int)CXCursor_UnionDecl; }
int pbg_kind_enum_decl(void)      { return (int)CXCursor_EnumDecl; }
int pbg_kind_enum_constant(void)  { return (int)CXCursor_EnumConstantDecl; }
int pbg_kind_typedef_decl(void)   { return (int)CXCursor_TypedefDecl; }
int pbg_kind_field_decl(void)     { return (int)CXCursor_FieldDecl; }
int pbg_kind_macro_def(void)      { return (int)CXCursor_MacroDefinition; }
int pbg_kind_parm_decl(void)      { return (int)CXCursor_ParmDecl; }
int pbg_kind_var_decl(void)       { return (int)CXCursor_VarDecl; }

/* --- child enumeration ---
 *
 * Instead of exposing clang_visitChildren (which takes a callback that
 * receives CXCursor by value), we snapshot direct children into an
 * array on demand. Recursion is the caller's job. */

typedef struct {
    PbgCursor** items;
    int count;
    int cap;
} CursorList;

static enum CXChildVisitResult collect_visitor(CXCursor c, CXCursor parent, CXClientData data) {
    (void)parent;
    CursorList* list = (CursorList*)data;
    if (list->count == list->cap) {
        int newcap = list->cap ? list->cap * 2 : 16;
        PbgCursor** nb = (PbgCursor**)realloc(list->items, newcap * sizeof(PbgCursor*));
        if (!nb) return CXChildVisit_Break;
        list->items = nb;
        list->cap = newcap;
    }
    PbgCursor* w = wrap_cursor(c);
    if (!w) return CXChildVisit_Break;
    list->items[list->count++] = w;
    return CXChildVisit_Continue;
}

/* Returns an opaque list handle. Use pbg_children_count / pbg_children_get
 * to access, pbg_children_dispose to free. Items themselves transfer
 * ownership to the caller — pbg_children_dispose only frees the list
 * spine; each PbgCursor* must be disposed individually. */
typedef struct PbgCursorList {
    CursorList list;
} PbgCursorList;

PbgCursorList* pbg_cursor_children(PbgCursor* p) {
    PbgCursorList* L = (PbgCursorList*)calloc(1, sizeof(*L));
    if (!L) return NULL;
    clang_visitChildren(p->c, collect_visitor, &L->list);
    return L;
}

int pbg_children_count(PbgCursorList* L) {
    return L ? L->list.count : 0;
}

PbgCursor* pbg_children_get(PbgCursorList* L, int i) {
    if (!L || i < 0 || i >= L->list.count) return NULL;
    return L->list.items[i];
}

/* Frees the list spine only — the cursors themselves are still owned
 * by the caller and must each be disposed via pbg_cursor_dispose. */
void pbg_children_dispose(PbgCursorList* L) {
    if (!L) return;
    free(L->list.items);
    free(L);
}

/* --- string release --- */

void pbg_free_string(const char* s) {
    free((void*)s);
}
