; Licensed to the .NET Foundation under one or more agreements.
; The .NET Foundation licenses this file to you under the MIT license.

        .686P
        .XMM
        .model  flat
        option  casemap:none
        .code

        EXTERN  ___security_cookie : DWORD
        EXTERN  ___report_gsfailure : PROC

        PUBLIC  @__security_check_cookie@4
        PUBLIC  __tls_array
        PUBLIC  __dtol3
        PUBLIC  __dtoul3_legacy
        PUBLIC  __ftol3
        PUBLIC  __ltod3
        PUBLIC  __ltof3
        PUBLIC  __ultod3
        PUBLIC  __ultof3

; Offset of ThreadLocalStoragePointer in the x86 TEB. The compiler references
; this absolute symbol when accessing statically allocated thread locals.
__tls_array EQU 02Ch

; MSVC passes the frame cookie in ecx and requires all other registers to be
; preserved. The failure helper does not return.
@__security_check_cookie@4 PROC
        cmp     ecx, ___security_cookie
        jne     AotCrtCookieFailure
        ret
AotCrtCookieFailure:
        call    ___report_gsfailure
        int     3
@__security_check_cookie@4 ENDP

; Convert the floating-point value in xmm0 to a signed 64-bit integer in
; edx:eax. The x87 control word is changed only for the duration of the
; conversion so the operation truncates toward zero.
__dtol3 PROC
        sub     esp, 12
        movsd   QWORD PTR [esp], xmm0
        fld     QWORD PTR [esp]
        fnstcw  WORD PTR [esp + 8]
        mov     ax, WORD PTR [esp + 8]
        or      ax, 0C00h
        mov     WORD PTR [esp + 10], ax
        fldcw   WORD PTR [esp + 10]
        fistp   QWORD PTR [esp]
        fldcw   WORD PTR [esp + 8]
        mov     eax, DWORD PTR [esp]
        mov     edx, DWORD PTR [esp + 4]
        add     esp, 12
        ret
__dtol3 ENDP

__ftol3 PROC
        sub     esp, 12
        movss   DWORD PTR [esp], xmm0
        fld     DWORD PTR [esp]
        fnstcw  WORD PTR [esp + 8]
        mov     ax, WORD PTR [esp + 8]
        or      ax, 0C00h
        mov     WORD PTR [esp + 10], ax
        fldcw   WORD PTR [esp + 10]
        fistp   QWORD PTR [esp]
        fldcw   WORD PTR [esp + 8]
        mov     eax, DWORD PTR [esp]
        mov     edx, DWORD PTR [esp + 4]
        add     esp, 12
        ret
__ftol3 ENDP

; Convert an unsigned double by reducing the upper half of the range to a
; signed conversion and restoring the high result bit.
__dtoul3_legacy PROC
        comisd  xmm0, QWORD PTR AotCrtTwoTo63
        jb      __dtol3
        subsd   xmm0, QWORD PTR AotCrtTwoTo63
        call    __dtol3
        or      edx, 80000000h
        ret
__dtoul3_legacy ENDP

; The integer-to-floating-point helpers receive the low and high halves in
; ecx and edx and return the result in xmm0.
__ltod3 PROC
        push    edx
        push    ecx
        fild    QWORD PTR [esp]
        fstp    QWORD PTR [esp]
        movsd   xmm0, QWORD PTR [esp]
        add     esp, 8
        ret
__ltod3 ENDP

__ltof3 PROC
        push    edx
        push    ecx
        fild    QWORD PTR [esp]
        fstp    DWORD PTR [esp]
        movss   xmm0, DWORD PTR [esp]
        add     esp, 8
        ret
__ltof3 ENDP

__ultod3 PROC
        test    edx, 80000000h
        jz      __ltod3
        mov     eax, ecx
        and     eax, 1
        shrd    ecx, edx, 1
        shr     edx, 1
        or      ecx, eax
        push    edx
        push    ecx
        fild    QWORD PTR [esp]
        fadd    st(0), st(0)
        fstp    QWORD PTR [esp]
        movsd   xmm0, QWORD PTR [esp]
        add     esp, 8
        ret
__ultod3 ENDP

__ultof3 PROC
        test    edx, 80000000h
        jz      __ltof3
        mov     eax, ecx
        and     eax, 1
        shrd    ecx, edx, 1
        shr     edx, 1
        or      ecx, eax
        push    edx
        push    ecx
        fild    QWORD PTR [esp]
        fadd    st(0), st(0)
        fstp    DWORD PTR [esp]
        movss   xmm0, DWORD PTR [esp]
        add     esp, 8
        ret
__ultof3 ENDP

        .const
        ALIGN   8
AotCrtTwoTo63 QWORD 43E0000000000000h

        END
