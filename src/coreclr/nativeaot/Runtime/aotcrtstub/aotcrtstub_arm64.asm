;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

        AREA    |.text|, CODE, READONLY

        IMPORT  __security_cookie
        IMPORT  __report_gsfailure

        EXPORT  __security_check_cookie
        EXPORT  __guard_dispatch_icall_fptr

; ARM64 Windows passes the stack cookie in x0. Preserve the ABI registers and
; tail-call the common failure path when the cookie does not match.
__security_check_cookie PROC
        adrp    x1, __security_cookie
        ldr     x1, [x1, __security_cookie]
        cmp     x0, x1
        b.ne    AotCrtCookieFailure
        ret
AotCrtCookieFailure
        b       __report_gsfailure
__security_check_cookie ENDP

; The NativeAOT ARM64 dispatch stubs leave the indirect target in x9 and branch
; through this loader-managed function pointer.
AotCrtGuardDispatchIcallNop PROC
        br      x9
AotCrtGuardDispatchIcallNop ENDP

        AREA    |.data|, DATA, READWRITE
__guard_dispatch_icall_fptr DCQ AotCrtGuardDispatchIcallNop

        END
