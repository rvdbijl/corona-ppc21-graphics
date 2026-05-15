; Corona PPC-21 graphics page scanner.
;
; MASM/TASM tiny-model .COM program:
;   tasm CPROBE.ASM
;   tlink /t CPROBE.OBJ
;
; Runtime behavior:
;   - Move the stack inside this .COM image.
;   - Shrink this .COM program's DOS memory block to its actual size.
;   - Allocate the largest free DOS memory block.
;   - Find the first 32 KiB boundary inside that allocated block.
;   - Print the discovered block and candidate page list.
;   - Ask whether to proceed.
;   - Draw a two-digit hex segment label into each candidate 32 KiB page.
;   - Switch to the PPC-21 graphics mode.
;   - Press any non-Esc key to advance to the next candidate page.
;   - Press Esc to return to DOS text mode.

        .model tiny
        .8086
        .code
        org     100h

PAGE_STEP       equ     0800h
MODE_CONTROL    equ     0A9h
PROG_PARAS      equ     (program_end + 15) / 16

start:
        cli
        mov     ax, cs
        mov     ss, ax
        mov     sp, offset stack_top
        sti

        push    cs
        pop     ds

        call    find_candidate_range
        cmp     word ptr [page_count], 0
        jne     have_pages

        call    free_alloc
        mov     dx, offset no_pages_msg
        mov     ah, 09h
        int     21h
        mov     ax, 4C01h
        int     21h

have_pages:
        call    print_preflight
        call    flush_keyboard
        call    ask_proceed
        jc      exit_program

        call    draw_all_pages
        call    enter_graphics
        call    flush_keyboard

        mov     ax, [start_seg]
        mov     [cur_seg], ax

page_loop:
        mov     ax, [cur_seg]
        call    select_display_seg

        xor     ax, ax
        int     16h
        cmp     al, 1Bh
        je      exit_program

        mov     ax, [cur_seg]
        add     ax, PAGE_STEP
        mov     bx, ax
        add     bx, PAGE_STEP
        cmp     bx, [top_seg]
        jbe     page_ok
        mov     ax, [start_seg]

page_ok:
        mov     [cur_seg], ax
        jmp     page_loop

exit_program:
        mov     ax, 0007h
        int     10h
        call    free_alloc
        mov     ax, 4C00h
        int     21h

find_candidate_range proc near
        ; Free the unused tail of the .COM program's allocation. This makes
        ; DOS expose a genuine free block that we can allocate and safely
        ; scribble into for page probing.
        mov     ax, cs
        mov     es, ax
        mov     bx, PROG_PARAS
        mov     ah, 4Ah
        int     21h
        jc      no_range

        ; Ask for an impossibly large block. DOS returns the largest
        ; available block size in BX.
        mov     bx, 0FFFFh
        mov     ah, 48h
        int     21h
        cmp     bx, PAGE_STEP
        jb      no_range

        ; Allocate that largest block so the probe owns the memory it writes.
        mov     ah, 48h
        int     21h
        jc      no_range

        mov     [alloc_seg], ax
        mov     dx, ax
        add     dx, bx
        mov     [top_seg], dx

        ; First candidate is the next 32 KiB boundary inside the allocated
        ; block.
        mov     ax, [alloc_seg]
        add     ax, PAGE_STEP - 1
        and     ax, 0F800h
        mov     [start_seg], ax
        mov     [cur_seg], ax

        xor     cx, cx

count_loop:
        mov     bx, ax
        add     bx, PAGE_STEP
        cmp     bx, [top_seg]
        ja      count_done
        inc     cx
        add     ax, PAGE_STEP
        jmp     count_loop

count_done:
        mov     [page_count], cx
        ret

no_range:
        xor     ax, ax
        mov     [alloc_seg], ax
        mov     [start_seg], ax
        mov     [top_seg], ax
        mov     [cur_seg], ax
        mov     [page_count], ax
        ret
find_candidate_range endp

free_alloc proc near
        mov     ax, [alloc_seg]
        or      ax, ax
        jz      free_done
        mov     es, ax
        mov     ah, 49h
        int     21h
        xor     ax, ax
        mov     [alloc_seg], ax
free_done:
        ret
free_alloc endp

flush_keyboard proc near
flush_loop:
        mov     ah, 01h
        int     16h
        jz      flush_done
        xor     ax, ax
        int     16h
        jmp     flush_loop
flush_done:
        ret
flush_keyboard endp

print_preflight proc near
        mov     dx, offset title_msg
        call    print_string

        mov     dx, offset alloc_msg
        call    print_string
        mov     ax, [alloc_seg]
        call    print_hex_word
        mov     dx, offset to_msg
        call    print_string
        mov     ax, [top_seg]
        call    print_hex_word
        call    print_crlf

        mov     dx, offset first_msg
        call    print_string
        mov     ax, [start_seg]
        call    print_hex_word
        call    print_crlf

        mov     dx, offset last_msg
        call    print_string
        mov     ax, [start_seg]
        mov     cx, [page_count]
        dec     cx
        jz      last_ready
last_calc_loop:
        add     ax, PAGE_STEP
        loop    last_calc_loop
last_ready:
        call    print_hex_word
        call    print_crlf

        mov     dx, offset count_msg
        call    print_string
        mov     ax, [page_count]
        call    print_hex_word
        call    print_crlf

        mov     dx, offset list_msg
        call    print_string
        mov     ax, [start_seg]
        mov     cx, [page_count]
list_loop:
        push    ax
        call    print_hex_word
        mov     al, ' '
        call    print_char
        pop     ax
        add     ax, PAGE_STEP
        loop    list_loop
        call    print_crlf
        ret
print_preflight endp

ask_proceed proc near
        mov     dx, offset ask_msg
        call    print_string
        xor     ax, ax
        int     16h
        cmp     al, 'Y'
        je      proceed_yes
        cmp     al, 'y'
        je      proceed_yes
        call    print_crlf
        stc
        ret
proceed_yes:
        mov     al, 'Y'
        call    print_char
        call    print_crlf
        clc
        ret
ask_proceed endp

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

draw_all_pages proc near
        mov     ax, [start_seg]
        mov     cx, [page_count]

draw_page_loop:
        or      cx, cx
        jz      draw_pages_done
        push    cx
        push    ax
        call    clear_page
        pop     ax
        push    ax
        call    draw_page_label
        pop     ax
        add     ax, PAGE_STEP
        pop     cx
        loop    draw_page_loop

draw_pages_done:
        ret
draw_all_pages endp

clear_page proc near
        mov     es, ax
        xor     di, di
        xor     ax, ax
        mov     cx, 4000h
        cld
        rep     stosw
        ret
clear_page endp

draw_page_label proc near
        ; AX = candidate segment. Draw the segment high byte, e.g. 38.
        push    ax

        call    draw_border

        pop     ax
        mov     bl, ah          ; segment high byte

        mov     al, bl
        mov     cl, 4
        shr     al, cl
        mov     cx, 232
        mov     dx, 104
        call    draw_digit

        mov     al, bl
        and     al, 0Fh
        mov     cx, 326
        mov     dx, 104
        call    draw_digit

        ret
draw_page_label endp

draw_border proc near
        mov     cx, 60
        mov     si, 580
        mov     dx, 48
        call    draw_hline

        mov     cx, 60
        mov     si, 580
        mov     dx, 276
        call    draw_hline

        mov     cx, 60
        mov     dx, 48
        mov     si, 276
        call    draw_vline

        mov     cx, 580
        mov     dx, 48
        mov     si, 276
        call    draw_vline

        ret
draw_border endp

draw_digit proc near
        ; AL = hex digit 0..F, CX = x base, DX = y base.
        push    ax
        push    bx
        push    cx
        push    dx
        push    si

        xor     ah, ah
        mov     bx, ax
        mov     al, [digit_masks + bx]
        mov     [digit_mask], al
        mov     [digit_x], cx
        mov     [digit_y], dx

        test    byte ptr [digit_mask], 01h
        jz      no_seg_a
        mov     cx, [digit_x]
        add     cx, 8
        mov     si, [digit_x]
        add     si, 54
        mov     dx, [digit_y]
        call    draw_hseg
no_seg_a:
        test    byte ptr [digit_mask], 02h
        jz      no_seg_b
        mov     cx, [digit_x]
        add     cx, 62
        mov     dx, [digit_y]
        add     dx, 8
        mov     si, [digit_y]
        add     si, 48
        call    draw_vseg
no_seg_b:
        test    byte ptr [digit_mask], 04h
        jz      no_seg_c
        mov     cx, [digit_x]
        add     cx, 62
        mov     dx, [digit_y]
        add     dx, 58
        mov     si, [digit_y]
        add     si, 98
        call    draw_vseg
no_seg_c:
        test    byte ptr [digit_mask], 08h
        jz      no_seg_d
        mov     cx, [digit_x]
        add     cx, 8
        mov     si, [digit_x]
        add     si, 54
        mov     dx, [digit_y]
        add     dx, 106
        call    draw_hseg
no_seg_d:
        test    byte ptr [digit_mask], 10h
        jz      no_seg_e
        mov     cx, [digit_x]
        mov     dx, [digit_y]
        add     dx, 58
        mov     si, [digit_y]
        add     si, 98
        call    draw_vseg
no_seg_e:
        test    byte ptr [digit_mask], 20h
        jz      no_seg_f
        mov     cx, [digit_x]
        mov     dx, [digit_y]
        add     dx, 8
        mov     si, [digit_y]
        add     si, 48
        call    draw_vseg
no_seg_f:
        test    byte ptr [digit_mask], 40h
        jz      no_seg_g
        mov     cx, [digit_x]
        add     cx, 8
        mov     si, [digit_x]
        add     si, 54
        mov     dx, [digit_y]
        add     dx, 53
        call    draw_hseg
no_seg_g:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
draw_digit endp

draw_hseg proc near
        call    draw_hline
        inc     dx
        call    draw_hline
        inc     dx
        call    draw_hline
        ret
draw_hseg endp

draw_vseg proc near
        call    draw_vline
        inc     cx
        call    draw_vline
        inc     cx
        call    draw_vline
        ret
draw_vseg endp

draw_hline proc near
        push    cx
        push    dx

draw_hline_loop:
        call    set_pixel
        inc     cx
        cmp     cx, si
        jbe     draw_hline_loop

        pop     dx
        pop     cx
        ret
draw_hline endp

draw_vline proc near
        push    cx
        push    dx

draw_vline_loop:
        call    set_pixel
        inc     dx
        cmp     dx, si
        jbe     draw_vline_loop

        pop     dx
        pop     cx
        ret
draw_vline endp

enter_graphics proc near
        push    ds
        mov     ax, 0040h
        mov     ds, ax
        or      byte ptr [0010h], 30h
        pop     ds

        mov     ax, 0007h
        int     10h

        mov     dx, 03B8h
        mov     al, MODE_CONTROL
        out     dx, al
        ret
enter_graphics endp

select_display_seg proc near
        ; AX = candidate segment. CRTC start high is the segment high byte.
        push    bx
        mov     bl, ah

        mov     dx, 03B8h
        mov     al, MODE_CONTROL
        out     dx, al

        mov     dx, 03B4h
        mov     al, 0Ch
        out     dx, al
        inc     dx
        mov     al, bl
        out     dx, al

        dec     dx
        mov     al, 0Dh
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al

        pop     bx
        ret
select_display_seg endp

set_pixel proc near
        ; ES = framebuffer segment, CX = x, DX = y.
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     si, cx

        mov     ax, dx
        mov     bl, 13
        div     bl              ; AL = y / 13, AH = y MOD 13

        xor     bx, bx
        mov     bl, ah
        mov     cl, 11
        shl     bx, cl
        mov     di, bx

        xor     ah, ah
        mov     bx, ax
        mov     cl, 6
        shl     ax, cl
        mov     dx, bx
        mov     cl, 4
        shl     dx, cl
        add     ax, dx
        add     di, ax

        mov     ax, si
        mov     cl, 3
        shr     ax, cl
        add     di, ax

        mov     bx, si
        and     bl, 07h
        mov     al, 01h

mask_loop:
        cmp     bl, 0
        je      mask_ready
        shl     al, 1
        dec     bl
        jmp     mask_loop

mask_ready:
        or      es:[di], al

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
set_pixel endp

start_seg       dw      0
top_seg         dw      0
cur_seg         dw      0
page_count      dw      0
alloc_seg       dw      0
digit_x         dw      0
digit_y         dw      0
digit_mask      db      0

digit_masks     db      3Fh,06h,5Bh,4Fh,66h,6Dh,7Dh,07h
                db      7Fh,6Fh,77h,7Ch,39h,5Eh,79h,71h

title_msg       db      0Dh,0Ah,'Corona PPC-21 graphics page probe',0Dh,0Ah,'$'
alloc_msg       db      'Allocated free block: $'
to_msg          db      ' to $'
first_msg       db      'First 32K page:     $'
last_msg        db      'Last 32K page:      $'
count_msg       db      'Page count:         $'
list_msg        db      'Pages to test:      $'
ask_msg         db      'Proceed with graphics test (Y/N)? $'
no_pages_msg    db      'No 32K candidate pages found in free DOS memory.$'

stack_area      db      256 dup (0)
stack_top:

program_end:
        end     start
