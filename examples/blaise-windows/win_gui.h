/* Win32 GUI subset for the countdown-form demo. Sized types only,
   to avoid bindgen's spelling-based unsigned-long mapping. */

typedef void*                HANDLE;
typedef void*                HWND;
typedef void*                HMENU;
typedef void*                HINSTANCE;
typedef void*                HICON;
typedef void*                HCURSOR;
typedef void*                HBRUSH;
typedef void*                HDC;
typedef void*                HGDIOBJ;
typedef unsigned short       WCHAR;
typedef const WCHAR*         LPCWSTR;
typedef WCHAR*               LPWSTR;
typedef unsigned int         UINT;
typedef unsigned int         DWORD;
typedef int                  BOOL;
typedef unsigned long long   ULONG_PTR;
typedef ULONG_PTR            WPARAM;
typedef long long            LPARAM;
typedef long long            LRESULT;
typedef unsigned long long   UINT_PTR;
typedef long                 LONG;
typedef unsigned char        BYTE;
typedef unsigned short       ATOM;

typedef LRESULT (*WNDPROC)(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
typedef void    (*TIMERPROC)(HWND hwnd, UINT msg, UINT_PTR id, DWORD time);

typedef struct tagRECT {
  LONG left;
  LONG top;
  LONG right;
  LONG bottom;
} RECT;

typedef struct tagPOINT {
  LONG x;
  LONG y;
} POINT;

typedef struct tagMSG {
  HWND   hwnd;
  UINT   message;
  WPARAM wParam;
  LPARAM lParam;
  DWORD  time;
  POINT  pt;
  DWORD  lPrivate;
} MSG;

typedef struct tagPAINTSTRUCT {
  HDC   hdc;
  BOOL  fErase;
  RECT  rcPaint;
  BOOL  fRestore;
  BOOL  fIncUpdate;
  BYTE  rgbReserved[32];
} PAINTSTRUCT;

typedef struct tagWNDCLASSEXW {
  UINT      cbSize;
  UINT      style;
  WNDPROC   lpfnWndProc;
  int       cbClsExtra;
  int       cbWndExtra;
  HINSTANCE hInstance;
  HICON     hIcon;
  HCURSOR   hCursor;
  HBRUSH    hbrBackground;
  LPCWSTR   lpszMenuName;
  LPCWSTR   lpszClassName;
  HICON     hIconSm;
} WNDCLASSEXW;

#define WS_OVERLAPPEDWINDOW  0x00CF0000
#define WS_VISIBLE           0x10000000
#define WS_CHILD             0x40000000
#define BS_DEFPUSHBUTTON     0x00000001
#define SW_SHOW              5
#define WM_DESTROY           0x0002
#define WM_PAINT             0x000F
#define WM_CLOSE             0x0010
#define WM_TIMER             0x0113
#define WM_COMMAND           0x0111
#define BN_CLICKED           0
#define IDC_ARROW            32512
#define CW_USEDEFAULT        ((int)0x80000000)
#define COLOR_WINDOW         5

#define ICC_STANDARD_CLASSES 0x4000

typedef struct tagINITCOMMONCONTROLSEX {
  DWORD dwSize;
  DWORD dwICC;
} INITCOMMONCONTROLSEX;

BOOL    __stdcall InitCommonControlsEx(const INITCOMMONCONTROLSEX* picce);

ATOM    __stdcall RegisterClassExW(const WNDCLASSEXW* lpWndClass);
HWND    __stdcall CreateWindowExW(DWORD exStyle, LPCWSTR cls, LPCWSTR title,
                                  DWORD style, int x, int y, int w, int h,
                                  HWND parent, HMENU menu, HINSTANCE hInst, void* lpParam);
LRESULT __stdcall DefWindowProcW(HWND h, UINT m, WPARAM w, LPARAM l);
BOOL    __stdcall ShowWindow(HWND h, int nCmdShow);
BOOL    __stdcall UpdateWindow(HWND h);
BOOL    __stdcall InvalidateRect(HWND h, const RECT* r, BOOL erase);
int     __stdcall GetMessageW(MSG* msg, HWND h, UINT min, UINT max);
BOOL    __stdcall TranslateMessage(const MSG* msg);
LRESULT __stdcall DispatchMessageW(const MSG* msg);
void    __stdcall PostQuitMessage(int nExitCode);
BOOL    __stdcall DestroyWindow(HWND h);
HDC     __stdcall BeginPaint(HWND h, PAINTSTRUCT* ps);
BOOL    __stdcall EndPaint(HWND h, const PAINTSTRUCT* ps);
BOOL    __stdcall TextOutW(HDC dc, int x, int y, LPCWSTR s, int n);
BOOL    __stdcall SetWindowTextW(HWND h, LPCWSTR s);
UINT_PTR __stdcall SetTimer(HWND h, UINT_PTR id, UINT period, TIMERPROC cb);
BOOL    __stdcall KillTimer(HWND h, UINT_PTR id);
HCURSOR __stdcall LoadCursorW(HINSTANCE h, LPCWSTR name);
int     __stdcall MessageBoxW(HWND hwnd, LPCWSTR text, LPCWSTR caption, UINT type);
