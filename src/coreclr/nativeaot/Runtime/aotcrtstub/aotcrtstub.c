// Copyright (c) 2026 Marc-André Moreau.
// Licensed under the MIT License.

//
// aotcrtstub - the minimal set of MSVC CRT support symbols that the NativeAOT
// runtime statics reference, reimplemented so a NativeAOT executable can link
// without libcmt.lib / libvcruntime.lib.
//
// Symbols satisfied from ntdll.dll (see ntdllcrt.def) are deliberately absent
// here: memcpy memmove memset memcmp memchr strstr wcsrchr
//        __C_specific_handler __chkstk
//
// Symbols that cannot be expressed in C live in aotcrtstub_amd64.asm:
//        __security_check_cookie __guard_dispatch_icall_fptr
//

#include <windows.h>
#include <intrin.h>

#if defined(__cplusplus)
extern "C" {
#endif

//
// Floating point marker. The compiler emits a reference to this whenever a
// translation unit uses floating point; the value itself is never read.
//
int _fltused = 0x9875;

//
// /GS stack cookie.
//
// The canonical default; __security_init_cookie replaces it at startup with a
// value derived from unpredictable system state.
//
#if defined(_WIN64)
#define AOTCRT_DEFAULT_SECURITY_COOKIE 0x00002B992DDFA232ULL
#else
#define AOTCRT_DEFAULT_SECURITY_COOKIE 0xBB40E64E
#endif

UINT_PTR __security_cookie = AOTCRT_DEFAULT_SECURITY_COOKIE;
UINT_PTR __security_cookie_complement = ~(UINT_PTR)AOTCRT_DEFAULT_SECURITY_COOKIE;

__declspec(noreturn) void __cdecl __report_gsfailure(UINT_PTR stackCookie)
{
    (void)stackCookie;
    __fastfail(FAST_FAIL_STACK_COOKIE_CHECK_FAILURE);
}

void __cdecl __report_rangecheckfailure(void)
{
    __fastfail(FAST_FAIL_RANGE_CHECK_FAILURE);
}

//
// /GS exception handler.
//
// The linker names this in the unwind data of any function that both has a
// stack cookie and can be unwound through. Its sole job is to detect that the
// cookie was corrupted while an exception is being dispatched; it never
// influences control flow, and always reports that the search should continue.
//
// Validating the cookie requires decoding the GS handler data that the MSVC
// compiler emits alongside the unwind info, an encoding that is not publicly
// documented. Rather than guess at it - where a wrong guess turns into
// spurious __report_gsfailure crashes - this implementation performs no check.
// The result is defence-in-depth equivalent to building without /GS, which is
// safe, and it is the one symbol here that would need real ABI work before
// this library could ship.
//
EXCEPTION_DISPOSITION __cdecl __GSHandlerCheck(
    PEXCEPTION_RECORD exceptionRecord,
    PVOID establisherFrame,
    PCONTEXT contextRecord,
    PVOID dispatcherContext)
{
    (void)exceptionRecord;
    (void)establisherFrame;
    (void)contextRecord;
    (void)dispatcherContext;

    return ExceptionContinueSearch;
}

//
// Derives a cookie from values that differ between runs and between machines,
// mirroring what the MSVC CRT does.
//
void __cdecl __security_init_cookie(void)
{
    UINT_PTR cookie;
    FILETIME systemTime;
    LARGE_INTEGER counter;

    GetSystemTimeAsFileTime(&systemTime);
    cookie = ((UINT_PTR)systemTime.dwHighDateTime << 16) ^ (UINT_PTR)systemTime.dwLowDateTime;
    cookie ^= (UINT_PTR)GetCurrentProcessId();
    cookie ^= (UINT_PTR)GetCurrentThreadId();
    cookie ^= (UINT_PTR)GetTickCount64();

    if (QueryPerformanceCounter(&counter))
    {
        cookie ^= (UINT_PTR)counter.QuadPart;
    }

    cookie ^= (UINT_PTR)&cookie;

#if defined(_WIN64)
    // Clearing the high 16 bits keeps a cookie from ever resembling a valid
    // user-mode return address.
    cookie &= 0x0000FFFFFFFFFFFFULL;
#endif

    if (cookie == (UINT_PTR)AOTCRT_DEFAULT_SECURITY_COOKIE)
    {
        cookie++;
    }

    __security_cookie = cookie;
    __security_cookie_complement = ~cookie;
}

//
// Control Flow Guard.
//
// The loader rewrites these pointers when it loads a CFG-enabled image on a
// CFG-enabled system. Until then they must point at something callable.
// __guard_check_icall_fptr receives the call target in RCX and validates it;
// for an image with no guard CF table there is nothing to check.
//
static void __cdecl AotCrtGuardCheckIcallNop(UINT_PTR target)
{
    (void)target;
}

UINT_PTR __guard_check_icall_fptr = (UINT_PTR)&AotCrtGuardCheckIcallNop;

// Defined in aotcrtstub_amd64.asm: unlike the check variant, the dispatch
// thunk takes its target in RAX and tail-calls it, so it cannot be written in C.
extern UINT_PTR __guard_dispatch_icall_fptr;

//
// TLS support.
//
// _tls_index is zero for the primary executable module. __tls_guard tracks
// whether dynamic TLS initialisation has already run on the current thread.
//
ULONG _tls_index = 0;
BOOL __tls_guard = TRUE;

void __cdecl __dyn_tls_on_demand_init(void)
{
}

//
// The PE thread-local storage directory.
//
// Without this the image has no TLS directory at all, the loader never
// allocates a TLS slot for the module, and every __declspec(thread) access
// reads through a null ThreadLocalStoragePointer entry. The NativeAOT runtime
// keeps its per-thread state in thread locals, so this is load-bearing: an
// image missing it links cleanly and then faults on the first managed call.
//
// The linker gathers .tls$* contributions between these two markers and emits
// the directory from the _tls_used structure, which must live in .rdata$T.
//
#pragma section(".tls", long, read, write)
#pragma section(".tls$ZZZ", long, read, write)
#pragma section(".CRT$XLA", long, read)
#pragma section(".CRT$XLZ", long, read)
#pragma section(".rdata$T", long, read)

__declspec(allocate(".tls")) char _tls_start = 0;
__declspec(allocate(".tls$ZZZ")) char _tls_end = 0;

__declspec(allocate(".CRT$XLA")) PIMAGE_TLS_CALLBACK __xl_a = NULL;
__declspec(allocate(".CRT$XLZ")) PIMAGE_TLS_CALLBACK __xl_z = NULL;

__declspec(allocate(".rdata$T")) const IMAGE_TLS_DIRECTORY64 _tls_used =
{
    (ULONGLONG)&_tls_start,
    (ULONGLONG)&_tls_end,
    (ULONGLONG)&_tls_index,
    (ULONGLONG)(&__xl_a + 1),
    0,
    0
};

//
// The PE load configuration directory.
//
// This is what publishes the address of __security_cookie to the loader, and
// it is also where the linker records Control Flow Guard and CET metadata. The
// /CETCOMPAT switch that NativeAOT passes by default has nowhere to record
// itself without it.
//
// The Control Flow Guard tables are synthesized by the linker, which then
// verifies that the load config already points at them and warns -- it does not
// error -- if it does not. A load config that leaves these zero therefore links
// with /guard:cf and produces an image the loader does not treat as guarded:
// indirect calls are never validated and CFG silently does nothing.
//
// The address of each _count symbol is the count; the address of __guard_flags
// is the flags word. They are absolute symbols, not storage.
//
extern BYTE __guard_fids_table[];
extern BYTE __guard_fids_count;
extern BYTE __guard_flags;
extern BYTE __guard_iat_table[];
extern BYTE __guard_iat_count;
extern BYTE __guard_longjmp_table[];
extern BYTE __guard_longjmp_count;
extern BYTE __guard_eh_cont_table[];
extern BYTE __guard_eh_cont_count;

__declspec(allocate(".rdata$T")) const IMAGE_LOAD_CONFIG_DIRECTORY64 _load_config_used =
{
    .Size = sizeof(IMAGE_LOAD_CONFIG_DIRECTORY64),
    .SecurityCookie = (ULONGLONG)&__security_cookie,
    .GuardCFCheckFunctionPointer = (ULONGLONG)&__guard_check_icall_fptr,
    .GuardCFDispatchFunctionPointer = (ULONGLONG)&__guard_dispatch_icall_fptr,
    .GuardCFFunctionTable = (ULONGLONG)&__guard_fids_table,
    .GuardCFFunctionCount = (ULONGLONG)&__guard_fids_count,
    .GuardFlags = (DWORD)(ULONG_PTR)&__guard_flags,
    .GuardAddressTakenIatEntryTable = (ULONGLONG)&__guard_iat_table,
    .GuardAddressTakenIatEntryCount = (ULONGLONG)&__guard_iat_count,
    .GuardLongJumpTargetTable = (ULONGLONG)&__guard_longjmp_table,
    .GuardLongJumpTargetCount = (ULONGLONG)&__guard_longjmp_count,
    .GuardEHContinuationTable = (ULONGLONG)&__guard_eh_cont_table,
    .GuardEHContinuationCount = (ULONGLONG)&__guard_eh_cont_count
};

//
// CPU feature level. Consumed by CRT string and memory routines that this
// library does not provide; zero selects the baseline implementation.
//
int __isa_available = 0;
int __isa_enabled = 0;

//
// Pure virtual call trap.
//
void __cdecl _purecall(void)
{
    __fastfail(FAST_FAIL_FATAL_APP_EXIT);
}

//
// atexit.
//
// The runtime registers a small, fixed number of handlers, so a static table
// avoids depending on an allocator during startup.
//
// Overflow fails fast rather than returning -1. A dropped handler is a silent
// correctness bug -- shutdown work simply never runs -- and callers routinely
// ignore the return value, so there would be nothing to diagnose. The measured
// requirement is far below this bound; see AOTCRT_MAX_ATEXIT selection notes.
//
#ifndef AOTCRT_MAX_ATEXIT
#define AOTCRT_MAX_ATEXIT 64
#endif

typedef void(__cdecl* AotCrtVoidFunc)(void);

static AotCrtVoidFunc s_atexitTable[AOTCRT_MAX_ATEXIT];
static LONG s_atexitCount;

int __cdecl atexit(AotCrtVoidFunc func)
{
    if (func == NULL)
    {
        return -1;
    }

    LONG slot = _InterlockedIncrement(&s_atexitCount) - 1;
    if (slot >= AOTCRT_MAX_ATEXIT)
    {
        __fastfail(FAST_FAIL_FATAL_APP_EXIT);
    }

    s_atexitTable[slot] = func;
    return 0;
}

static void AotCrtRunAtExit(void)
{
    LONG count = s_atexitCount;
    if (count > AOTCRT_MAX_ATEXIT)
    {
        count = AOTCRT_MAX_ATEXIT;
    }

    // Handlers run in reverse registration order.
    for (LONG i = count - 1; i >= 0; i--)
    {
        if (s_atexitTable[i] != NULL)
        {
            s_atexitTable[i]();
        }
    }
}

//
// C++ dynamic initializers.
//
// The compiler emits pointers into .CRT$XCU, which the linker sorts between
// these two markers.
//
#pragma section(".CRT$XCA", long, read)
#pragma section(".CRT$XCZ", long, read)

__declspec(allocate(".CRT$XCA")) AotCrtVoidFunc __xc_a[] = { NULL };
__declspec(allocate(".CRT$XCZ")) AotCrtVoidFunc __xc_z[] = { NULL };

#pragma comment(linker, "/merge:.CRT=.rdata")

static void AotCrtRunInitializers(void)
{
    for (AotCrtVoidFunc* p = __xc_a; p < __xc_z; p++)
    {
        if (*p != NULL)
        {
            (*p)();
        }
    }
}

//
// Command line parsing.
//
// Reproduces the argument splitting rules the MSVC CRT applies, so the argv
// handed to wmain matches what a normally linked executable would see.
// CommandLineToArgvW would do this for us but lives in shell32.dll, which
// NativeAOT does not otherwise link against.
//
// Called twice: once with NULL outputs to count, once to fill.
//

static BOOL AotCrtIsSpace(wchar_t c)
{
    return c == L' ' || c == L'\t';
}

static int AotCrtParseCommandLine(const wchar_t* cmdline, wchar_t** argv, wchar_t* buffer)
{
    int argc = 0;
    const wchar_t* src = cmdline;
    wchar_t* dst = buffer;

    while (*src != L'\0')
    {
        while (AotCrtIsSpace(*src))
        {
            src++;
        }

        if (*src == L'\0')
        {
            break;
        }

        if (argv != NULL)
        {
            argv[argc] = dst;
        }
        argc++;

        BOOL inQuotes = FALSE;
        while (*src != L'\0' && (inQuotes || !AotCrtIsSpace(*src)))
        {
            if (*src == L'\\')
            {
                // Backslashes are only special when they precede a quote.
                int slashes = 0;
                while (*src == L'\\')
                {
                    slashes++;
                    src++;
                }

                if (*src == L'"')
                {
                    // Each pair collapses to one backslash; a trailing odd one
                    // escapes the quote.
                    for (int i = 0; i < slashes / 2; i++)
                    {
                        if (buffer != NULL)
                        {
                            *dst = L'\\';
                        }
                        dst++;
                    }

                    if ((slashes % 2) != 0)
                    {
                        if (buffer != NULL)
                        {
                            *dst = L'"';
                        }
                        dst++;
                        src++;
                    }
                    else
                    {
                        inQuotes = !inQuotes;
                        src++;
                    }
                }
                else
                {
                    for (int i = 0; i < slashes; i++)
                    {
                        if (buffer != NULL)
                        {
                            *dst = L'\\';
                        }
                        dst++;
                    }
                }
            }
            else if (*src == L'"')
            {
                src++;
                if (inQuotes && *src == L'"')
                {
                    // "" inside a quoted run is a literal quote.
                    if (buffer != NULL)
                    {
                        *dst = L'"';
                    }
                    dst++;
                    src++;
                }
                else
                {
                    inQuotes = !inQuotes;
                }
            }
            else
            {
                if (buffer != NULL)
                {
                    *dst = *src;
                }
                dst++;
                src++;
            }
        }

        if (buffer != NULL)
        {
            *dst = L'\0';
        }
        dst++;
    }

    return argc;
}

//
// Entry point.
//

extern int __cdecl wmain(int argc, wchar_t* argv[]);

__declspec(noreturn) void __cdecl wmainCRTStartup(void)
{
    __security_init_cookie();

    AotCrtRunInitializers();

    const wchar_t* cmdline = GetCommandLineW();

    int argc = AotCrtParseCommandLine(cmdline, NULL, NULL);

    size_t cmdlineChars = 0;
    while (cmdline[cmdlineChars] != L'\0')
    {
        cmdlineChars++;
    }

    size_t argvBytes = (size_t)(argc + 1) * sizeof(wchar_t*);
    size_t bufferBytes = (cmdlineChars + (size_t)argc + 1) * sizeof(wchar_t);

    wchar_t** argv = (wchar_t**)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, argvBytes + bufferBytes);
    if (argv == NULL)
    {
        ExitProcess((UINT)-1);
    }

    wchar_t* buffer = (wchar_t*)((BYTE*)argv + argvBytes);
    AotCrtParseCommandLine(cmdline, argv, buffer);
    argv[argc] = NULL;

    int exitCode = wmain(argc, argv);

    AotCrtRunAtExit();

    ExitProcess((UINT)exitCode);
}

#if defined(__cplusplus)
}
#endif
