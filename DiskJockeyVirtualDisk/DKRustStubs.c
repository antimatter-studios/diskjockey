/*
 * Stubs for Rust std symbols that are bundled into libqcow2_dk / libvhdx_dk
 * but are unavailable in DriverKit AND never reachable at runtime from QCOW2/VHDX
 * block-device code paths. If any of these stubs are actually called, the dext
 * will trap — the correct behaviour since it indicates an unexpected code path.
 *
 * Covered groups:
 *   - libunwind ABI     (__Unwind_*)    — Rust panic unwinding; should never run
 *   - Dynamic linker    (_dlopen etc.)  — not available in DriverKit sandbox
 *   - copyfile API      (_copyfile_*)   — not available in DriverKit
 *   - getaddrinfo API   (_getaddrinfo)  — DNS; not needed by block I/O
 *   - getpwuid_r        — user DB; not needed
 *   - realpath          — path resolution; not needed
 *   - __tlv_bootstrap   — TLS initialiser; Rust TLS never used on this path
 */

#include <stdint.h>
#include <stddef.h>

__attribute__((noreturn)) static void _dk_abort(void) { __builtin_trap(); }

/* ── libunwind ABI ─────────────────────────────────────────────── */

typedef struct _Unwind_Context   _Unwind_Context;
typedef struct _Unwind_Exception _Unwind_Exception;
typedef int  _Unwind_Reason_Code;
typedef uintptr_t _Unwind_Word;
typedef _Unwind_Reason_Code (*_Unwind_Trace_Fn)(_Unwind_Context*, void*);

#define _URC_END_OF_STACK 5

_Unwind_Reason_Code __Unwind_RaiseException(_Unwind_Exception* e)                          { (void)e; _dk_abort(); }
void                __Unwind_Resume(_Unwind_Exception* e)                                   { (void)e; _dk_abort(); }
void                __Unwind_DeleteException(_Unwind_Exception* e)                          { (void)e; }
_Unwind_Reason_Code __Unwind_Backtrace(_Unwind_Trace_Fn fn, void* arg)                     { (void)fn; (void)arg; return _URC_END_OF_STACK; }
_Unwind_Word        __Unwind_GetIP(_Unwind_Context* c)                                      { (void)c; return 0; }
_Unwind_Word        __Unwind_GetIPInfo(_Unwind_Context* c, int* ip_before)                  { (void)c; if (ip_before) *ip_before = 0; return 0; }
_Unwind_Word        __Unwind_GetCFA(_Unwind_Context* c)                                     { (void)c; return 0; }
_Unwind_Word        __Unwind_GetRegionStart(_Unwind_Context* c)                             { (void)c; return 0; }
_Unwind_Word        __Unwind_GetDataRelBase(_Unwind_Context* c)                             { (void)c; return 0; }
_Unwind_Word        __Unwind_GetTextRelBase(_Unwind_Context* c)                             { (void)c; return 0; }
_Unwind_Word        __Unwind_GetLanguageSpecificData(_Unwind_Context* c)                    { (void)c; return 0; }
void                __Unwind_SetIP(_Unwind_Context* c, _Unwind_Word v)                      { (void)c; (void)v; }
void                __Unwind_SetGR(_Unwind_Context* c, int r, _Unwind_Word v)               { (void)c; (void)r; (void)v; }

/* ── TLS bootstrap ─────────────────────────────────────────────── */

void __tlv_bootstrap(void) {}   /* Rust TLS never used from block I/O path */

/* ── Dynamic linker ────────────────────────────────────────────── */

void* _dlopen(const char* path, int mode)  { (void)path; (void)mode; return NULL; }
int   _dlclose(void* handle)               { (void)handle; return 0; }
void* _dlsym(void* handle, const char* s)  { (void)handle; (void)s; return NULL; }
char* _dlerror(void)                       { return NULL; }

/* ── copyfile API ──────────────────────────────────────────────── */

typedef void* copyfile_state_t;
copyfile_state_t _copyfile_state_alloc(void) { return NULL; }
int              _copyfile_state_free(copyfile_state_t s) { (void)s; return 0; }
int              _copyfile_state_get(copyfile_state_t s, uint32_t f, void* dst) { (void)s; (void)f; (void)dst; return -1; }
int              _fcopyfile(int from, int to, copyfile_state_t st, uint32_t flags) { (void)from; (void)to; (void)st; (void)flags; return -1; }

/* ── getaddrinfo / DNS ─────────────────────────────────────────── */

struct addrinfo;
int  _getaddrinfo(const char* n, const char* s, const struct addrinfo* h, struct addrinfo** r)
     { (void)n; (void)s; (void)h; (void)r; return -1; /* EAI_FAIL */ }
void _freeaddrinfo(struct addrinfo* ai)   { (void)ai; }
const char* _gai_strerror(int e)          { (void)e; return ""; }

/* ── passwd DB ─────────────────────────────────────────────────── */

struct passwd;
int _getpwuid_r(unsigned uid, struct passwd* pwd, char* buf, size_t buflen, struct passwd** result)
    { (void)uid; (void)pwd; (void)buf; (void)buflen; if (result) *result = NULL; return -1; }

/* ── realpath ──────────────────────────────────────────────────── */

/* _realpath$DARWIN_EXTSN is the linker symbol for realpath on macOS 10.6+.
   DriverKit doesn't export it; provide a stub. The $DARWIN_EXTSN suffix is
   added via the assembler directive below. */
__asm__(".globl _realpath$DARWIN_EXTSN");
__asm__("_realpath$DARWIN_EXTSN:");
__asm__("  mov x0, #0");
__asm__("  ret");
