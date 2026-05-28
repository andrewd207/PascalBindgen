/* Mini win32 surface using sized types — avoids unsigned-long ABI
   mismatch from bindgen's spelling-based mapping. */
typedef void*         HANDLE;
typedef unsigned int  DWORD;
typedef int           BOOL;
typedef struct _FILETIME {
  DWORD dwLowDateTime;
  DWORD dwHighDateTime;
} FILETIME;

__attribute__((dllimport)) HANDLE __stdcall GetStdHandle(DWORD nStdHandle);
__attribute__((dllimport)) BOOL   __stdcall WriteFile(HANDLE h, const void* buf, DWORD n, DWORD* written, void* ov);
__attribute__((dllimport)) void   __stdcall GetSystemTimeAsFileTime(FILETIME* lpSystemTimeAsFileTime);
__attribute__((dllimport)) void   __stdcall Sleep(DWORD ms);
__attribute__((dllimport)) void   __stdcall ExitProcess(DWORD code);
