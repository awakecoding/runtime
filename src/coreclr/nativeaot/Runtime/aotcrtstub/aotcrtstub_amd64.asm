; Licensed to the .NET Foundation under one or more agreements.
; The .NET Foundation licenses this file to you under the MIT license.

;
; The two aotcrtstub symbols whose register contracts cannot be expressed in C.
;

    extern __security_cookie:QWORD
    extern __report_gsfailure:PROC

    .code

;
; __security_check_cookie
;
; Called on function exit with the frame's cookie in RCX. Every other register
; is live across the call, so this must not touch anything but RCX and flags.
;
__security_check_cookie PROC
    cmp     rcx, __security_cookie
    jne     AotCrtCookieFailure
    ret
AotCrtCookieFailure:
    ; __report_gsfailure takes the observed cookie in RCX; it is already there.
    jmp     __report_gsfailure
__security_check_cookie ENDP

;
; Control Flow Guard dispatch thunk.
;
; Unlike __guard_check_icall_fptr, which only validates, the dispatch form is
; responsible for performing the indirect call itself. The target arrives in
; RAX and the argument registers are already loaded, so the only safe action
; for an image without a guard CF table is to jump straight to it.
;
AotCrtGuardDispatchIcallNop PROC
    jmp     rax
AotCrtGuardDispatchIcallNop ENDP

    .data

    public __guard_dispatch_icall_fptr
__guard_dispatch_icall_fptr QWORD AotCrtGuardDispatchIcallNop

    end
