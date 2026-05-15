; CGATEST - BIOS-only smoke test for CGA105.COM.
;
; This program deliberately does not write B800h and does not touch CGA
; ports directly. It only uses INT 11h and INT 10h calls that CGA105 hooks.
;
; Run after installing CGA105.COM:
;   CGA105
;   CGATEST

        .model tiny
        .8086
        .code
        org     100h

start:
        push    cs
        pop     ds

        mov     dx, offset title_msg
        call    print_string

        int     11h
        mov     dx, offset equip_msg
        call    print_string
        call    print_hex_word
        call    print_crlf

        mov     ah, 0Fh
        int     10h
        push    ax
        mov     dx, offset state_msg
        call    print_string
        pop     ax
        push    ax
        xor     ah, ah
        call    print_hex_word
        mov     dx, offset cols_msg
        call    print_string
        pop     ax
        mov     al, ah
        xor     ah, ah
        call    print_hex_word
        call    print_crlf

        mov     dx, offset prompt_msg
        call    print_string
        xor     ax, ax
        int     16h

        mov     ax, 0006h
        int     10h
        call    draw_mode6
        xor     ax, ax
        int     16h

        mov     ax, 0004h
        int     10h
        call    draw_mode4
        xor     ax, ax
        int     16h

        mov     ax, 0007h
        int     10h
        mov     ax, 4C00h
        int     21h

draw_mode6 proc near
        ; Border.
        mov     dx, 0
        mov     cx, 0
m6_top:
        mov     al, 1
        call    putpix
        inc     cx
        cmp     cx, 639
        jbe     m6_top

        mov     dx, 199
        mov     cx, 0
m6_bottom:
        mov     al, 1
        call    putpix
        inc     cx
        cmp     cx, 639
        jbe     m6_bottom

        mov     cx, 0
        mov     dx, 0
m6_left:
        mov     al, 1
        call    putpix
        inc     dx
        cmp     dx, 199
        jbe     m6_left

        mov     cx, 639
        mov     dx, 0
m6_right:
        mov     al, 1
        call    putpix
        inc     dx
        cmp     dx, 199
        jbe     m6_right

        ; Diagonal-ish stripes.
        mov     dx, 0
m6_diag_y:
        mov     cx, dx
        shl     cx, 1
        shl     cx, 1
        mov     al, 1
        call    putpix
        add     cx, 1
        call    putpix
        add     cx, 78
        cmp     cx, 639
        ja      m6_diag_next
        call    putpix
m6_diag_next:
        inc     dx
        cmp     dx, 199
        jbe     m6_diag_y
        ret
draw_mode6 endp

draw_mode4 proc near
        ; Four vertical bands using CGA colors 0..3. CGA105 should dither
        ; these into increasing monochrome density.
        xor     dx, dx
m4_y:
        xor     cx, cx
m4_x:
        mov     ax, cx
        cmp     ax, 80
        jb      m4_c0
        cmp     ax, 160
        jb      m4_c1
        cmp     ax, 240
        jb      m4_c2
        mov     al, 3
        jmp     m4_draw
m4_c0:
        xor     al, al
        jmp     m4_draw
m4_c1:
        mov     al, 1
        jmp     m4_draw
m4_c2:
        mov     al, 2
m4_draw:
        call    putpix
        inc     cx
        cmp     cx, 319
        jbe     m4_x
        inc     dx
        cmp     dx, 199
        jbe     m4_y
        ret
draw_mode4 endp

putpix proc near
        ; AL=color, CX=x, DX=y.
        push    bx
        mov     ah, 0Ch
        xor     bh, bh
        int     10h
        pop     bx
        ret
putpix endp

print_string proc near
        mov     ah, 09h
        int     21h
        ret
print_string endp

print_crlf proc near
        mov     al, 0Dh
        call    print_char
        mov     al, 0Ah
        call    print_char
        ret
print_crlf endp

print_char proc near
        push    dx
        mov     dl, al
        mov     ah, 02h
        int     21h
        pop     dx
        ret
print_char endp

print_hex_word proc near
        push    ax
        mov     al, ah
        call    print_hex_byte
        pop     ax
        call    print_hex_byte
        ret
print_hex_word endp

print_hex_byte proc near
        push    ax
        push    bx
        push    cx
        mov     bl, al
        mov     cl, 4
        shr     al, cl
        call    print_hex_nibble
        mov     al, bl
        and     al, 0Fh
        call    print_hex_nibble
        pop     cx
        pop     bx
        pop     ax
        ret
print_hex_byte endp

print_hex_nibble proc near
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     print_hex_digit
        add     al, 7
print_hex_digit:
        call    print_char
        ret
print_hex_nibble endp

title_msg       db      'CGA105 BIOS smoke test',0Dh,0Ah,'$'
equip_msg       db      'INT 11h equipment word: $'
state_msg       db      'INT 10h AH=0Fh mode: $'
cols_msg        db      ' columns: $'
prompt_msg      db      'Press a key for mode 6, then another for mode 4, then another to exit.',0Dh,0Ah,'$'

        end     start
