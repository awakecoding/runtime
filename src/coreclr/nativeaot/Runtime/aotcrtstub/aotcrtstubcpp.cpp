// Copyright (c) 2026 Marc-André Moreau.
// Licensed under the MIT License.

//
// The C++ half of aotcrtstub: the global allocation operators and the TLS
// initialiser callback.
//
// The NativeAOT runtime's C++ components allocate through `new (std::nothrow)`
// and release through sized and array `delete`. The MSVC CRT implements these
// on top of malloc; here they go straight to the process heap, which removes
// the last reason those translation units would pull in libcmt.
//
// The declarations below are written out rather than taken from <new> so that
// this file has no dependency on the MSVC headers.
//

#include <windows.h>

namespace std
{
    struct nothrow_t
    {
    };

    extern const nothrow_t nothrow;
    const nothrow_t nothrow = {};
}

namespace
{
    inline void* AotCrtAlloc(size_t size)
    {
        // A zero-sized request must still return a distinct, freeable pointer.
        if (size == 0)
        {
            size = 1;
        }

        return HeapAlloc(GetProcessHeap(), 0, size);
    }

    inline void AotCrtFree(void* ptr)
    {
        if (ptr != nullptr)
        {
            HeapFree(GetProcessHeap(), 0, ptr);
        }
    }
}

void* __cdecl operator new(size_t size, const std::nothrow_t&) noexcept
{
    return AotCrtAlloc(size);
}

void* __cdecl operator new[](size_t size, const std::nothrow_t&) noexcept
{
    return AotCrtAlloc(size);
}

void __cdecl operator delete(void* ptr) noexcept
{
    AotCrtFree(ptr);
}

void __cdecl operator delete[](void* ptr) noexcept
{
    AotCrtFree(ptr);
}

void __cdecl operator delete(void* ptr, size_t) noexcept
{
    AotCrtFree(ptr);
}

void __cdecl operator delete[](void* ptr, size_t) noexcept
{
    AotCrtFree(ptr);
}

void __cdecl operator delete(void* ptr, const std::nothrow_t&) noexcept
{
    AotCrtFree(ptr);
}

void __cdecl operator delete[](void* ptr, const std::nothrow_t&) noexcept
{
    AotCrtFree(ptr);
}

extern "C"
{
    //
    // TLS initialiser callback.
    //
    // The loader invokes this for each thread attach when the image has a TLS
    // directory. Dynamic TLS initialisers are a C++ feature the runtime does
    // not use, so there is nothing to run.
    //
    BOOL WINAPI __dyn_tls_init(PVOID instance, DWORD reason, PVOID reserved)
    {
        (void)instance;
        (void)reason;
        (void)reserved;

        return TRUE;
    }
}
