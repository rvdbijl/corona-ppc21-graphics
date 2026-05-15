; CGA105 - first-pass CGA BIOS shim for the Corona/Cordata PPC-21.
;
; MASM/TASM tiny-model .COM TSR:
;   tasm CGA105.ASM
;   tlink /t CGA105.OBJ
;
; This is API-level emulation, not hardware-level CGA emulation. It hooks:
;   INT 10h - selected CGA BIOS video functions
;   INT 11h - equipment word return value changed to CGA 80-column
;
; Implemented INT 10h functions:
;   AH=00h AL=04h/05h  set 320x200 4-color CGA-like mode
;   AH=00h AL=06h      set 640x200 mono CGA-like mode
;   AH=0Bh             remember CGA palette/background requests
;   AH=0Ch             write graphics pixel
;   AH=0Dh             read graphics pixel
;   AH=0Fh             get current video state while emulated mode is active
;
; The TSR reserves one 32 KiB-aligned Corona graphics page inside its own
; resident DOS memory block. That page must sit below segment 4000h because
; the PPC-21 CRTC path observed so far wraps at the 256 KiB boundary.
;
; Command line:
;   CGA105       install, stretch CGA 640x200 vertically to 640x325
;   CGA105 /N    install, leave 640x200 at the top of the 640x325 screen
;   CGA105 /U    unload, if CGA105 is still the top INT 10h/INT 11h hook
;
; Limitations:
;   - Direct B800h framebuffer writes are not trapped by an 8088 TSR.
;   - Direct CGA port writes to 03D8h/03D9h/03DAh are not trapped.
;   - Unsupported active graphics INT 10h functions are treated as no-ops.
;   - 320x200 color is dithered into the PPC-21's 1bpp monochrome display.

        .model tiny
        .8086
        .code
        org     100h

PAGE_STEP       equ     0800h
LOW_LIMIT       equ     4000h
MODE_CONTROL    equ     0A9h
SHADOW_SIZE     equ     4000h          ; CGA visible 16 KiB
INSTALL_SIG     equ     0C6A1h

start:
        cli
        mov     ax, cs
        mov     ss, ax
        mov     sp, offset install_stack_top
        sti

        push    cs
        pop     ds

        call    parse_command_tail
        cmp     byte ptr [unload_flag], 0
        je      install_tsr
        call    unload_tsr
        mov     ax, 4C00h
        int     21h

install_tsr:
        mov     dx, offset trace_title_msg
        call    print_string
        mov     dx, offset trace_parse_msg
        call    print_string
        call    free_own_environment

        mov     dx, offset trace_choose_msg
        call    print_string
        call    choose_frame_page
        jc      install_failed

        mov     dx, offset trace_frame_msg
        call    print_string
        mov     ax, [frame_seg]
        call    print_hex_word
        call    print_crlf

        mov     dx, offset trace_clear_shadow_msg
        call    print_string
        call    clear_shadow

        mov     dx, offset trace_clear_frame_msg
        call    print_string
        call    clear_frame

        ; Save original vectors.
        mov     dx, offset trace_save10_msg
        call    print_string
        mov     ax, 3510h
        int     21h
        push    cs
        pop     ds
        mov     [old10_off], bx
        mov     [old10_seg], es

        mov     dx, offset trace_save11_msg
        call    print_string
        mov     ax, 3511h
        int     21h
        push    cs
        pop     ds
        mov     [old11_off], bx
        mov     [old11_seg], es

        ; Install vectors.
        mov     dx, offset trace_hook10_msg
        call    print_string
        push    cs
        pop     ds
        mov     dx, offset int10_handler
        mov     ax, 2510h
        int     21h

        push    cs
        pop     ds
        mov     dx, offset trace_hook11_msg
        call    print_string
        push    cs
        pop     ds
        mov     dx, offset int11_handler
        mov     ax, 2511h
        int     21h

        push    cs
        pop     ds
        mov     dx, offset trace_bda_msg
        call    print_string
        push    cs
        pop     ds
        ; Leave the equipment word saying CGA so programs that read the BDA
        ; directly, including DOS MODE.COM on some versions, see a color
        ; display. Before calling the real Corona BIOS we temporarily switch
        ; it back to mono so the physical MDA-compatible console remains
        ; usable.
        call    set_bda_cga

        mov     dx, offset installed_msg
        call    print_string
        mov     ax, [frame_seg]
        call    print_hex_word
        mov     dx, offset installed_msg_2
        call    print_string
        cmp     byte ptr [line_stretch], 0
        je      stretch_is_off
        mov     dx, offset stretch_on_msg
        jmp     print_stretch
stretch_is_off:
        mov     dx, offset stretch_off_msg
print_stretch:
        call    print_string

        ; Stay resident through the end of the reserved 32 KiB page.
        mov     ax, [frame_seg]
        add     ax, PAGE_STEP
        mov     dx, ax
        mov     ax, cs
        sub     dx, ax
        mov     ax, 3100h
        int     21h

install_failed:
        mov     dx, offset failed_msg
        call    print_string
        mov     ax, 4C01h
        int     21h

; ---------------------------------------------------------------------------
; Install-time helpers

parse_command_tail proc near
        ; Default: stretch 640x200 to 640x325.
        mov     byte ptr [line_stretch], 1
        mov     byte ptr [unload_flag], 0
        mov     cl, [80h]
        xor     ch, ch
        jcxz    parse_done
        mov     si, 81h
parse_loop:
        lodsb
        cmp     al, 'n'
        je      no_stretch
        cmp     al, 'N'
        je      no_stretch
        cmp     al, 'u'
        je      unload_requested
        cmp     al, 'U'
        je      unload_requested
        loop    parse_loop
        ret
no_stretch:
        mov     byte ptr [line_stretch], 0
        jmp     parse_next
unload_requested:
        mov     byte ptr [unload_flag], 1
parse_next:
        loop    parse_loop
parse_done:
        ret
parse_command_tail endp

free_own_environment proc near
        push    ax
        push    es
        mov     ax, [002Ch]            ; PSP environment segment
        or      ax, ax
        jz      env_done
        mov     es, ax
        mov     ah, 49h
        int     21h
        xor     ax, ax
        mov     [002Ch], ax
env_done:
        pop     es
        pop     ax
        ret
free_own_environment endp

unload_tsr proc near
        mov     dx, offset unload_check_msg
        call    print_string

        mov     ax, 3510h
        int     21h
        push    cs
        pop     ds
        cmp     bx, offset int10_handler
        jne     unload_not_found
        cmp     word ptr es:[install_sig], INSTALL_SIG
        jne     unload_not_found
        mov     [resident_seg], es

        mov     ax, 3511h
        int     21h
        push    cs
        pop     ds
        cmp     bx, offset int11_handler
        jne     unload_blocked
        mov     ax, [resident_seg]
        push    es
        pop     bx
        cmp     ax, bx
        jne     unload_blocked

        ; Copy the original vectors out of resident memory before restoring
        ; or freeing anything.
        mov     ax, es:[old10_off]
        mov     [unload10_off], ax
        mov     ax, es:[old10_seg]
        mov     [unload10_seg], ax
        mov     ax, es:[old11_off]
        mov     [unload11_off], ax
        mov     ax, es:[old11_seg]
        mov     [unload11_seg], ax

        mov     dx, offset unload_restore_msg
        call    print_string

        mov     dx, [unload10_off]
        mov     ax, [unload10_seg]
        mov     ds, ax
        mov     ax, 2510h
        int     21h

        push    cs
        pop     ds
        mov     dx, [unload11_off]
        mov     ax, [unload11_seg]
        mov     ds, ax
        mov     ax, 2511h
        int     21h

        push    cs
        pop     ds
        call    set_bda_mono

        mov     ax, [resident_seg]
        mov     es, ax
        mov     ah, 49h
        int     21h
        jc      unload_free_failed

        push    cs
        pop     ds
        mov     dx, offset unload_done_msg
        call    print_string
        ret

unload_free_failed:
        push    cs
        pop     ds
        mov     dx, offset unload_free_failed_msg
        call    print_string
        ret

unload_not_found:
        mov     dx, offset unload_not_found_msg
        call    print_string
        ret

unload_blocked:
        mov     dx, offset unload_blocked_msg
        call    print_string
        ret
unload_tsr endp

choose_frame_page proc near
        ; Pick the first 32 KiB boundary after the resident code/data.
        ; DOS gives a .COM program one allocation block. We keep that block
        ; resident through the chosen graphics page, so DOS will not reuse it.
        mov     ax, cs
        add     ax, RESIDENT_PARAS
        add     ax, PAGE_STEP - 1
        and     ax, 0F800h
        mov     [frame_seg], ax

        mov     bx, ax
        add     bx, PAGE_STEP
        cmp     bx, LOW_LIMIT
        ja      no_page

        mov     dx, cs:[0002h]         ; end segment of this DOS allocation
        cmp     bx, dx
        ja      no_page

        clc
        ret
no_page:
        stc
        ret
choose_frame_page endp

; ---------------------------------------------------------------------------
; INT 11h equipment hook

int11_handler proc far
        pushf
        call    dword ptr cs:[old11_off]
        and     ax, 0FFCFh
        or      ax, 0020h              ; bits 4-5 = 10b, CGA 80-column
        iret
int11_handler endp

; ---------------------------------------------------------------------------
; INT 10h video hook

int10_handler proc far
        cmp     ah, 00h
        je      int10_set_mode
        cmp     ah, 0Bh
        je      int10_palette
        cmp     ah, 0Ch
        je      int10_write_pixel
        cmp     ah, 0Dh
        je      int10_read_pixel
        cmp     ah, 0Fh
        je      int10_get_state

        cmp     byte ptr cs:[active_flag], 0
        jne     int10_noop
        jmp     chain_old10

int10_noop:
        iret
int10_handler endp

int10_set_mode proc near
        cmp     al, 02h
        je      set_text_mode_80
        cmp     al, 03h
        je      set_text_mode_80
        cmp     al, 04h
        je      set_emulated_mode
        cmp     al, 05h
        je      set_emulated_mode
        cmp     al, 06h
        je      set_emulated_mode

        ; Leaving our emulated graphics mode.
        mov     byte ptr cs:[active_flag], 0
        jmp     chain_old10

set_text_mode_80:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es

        push    cs
        pop     ds

        mov     byte ptr [current_mode], 03h
        mov     byte ptr [active_flag], 0
        mov     byte ptr [current_page], 0

        call    set_bda_mono
        mov     ax, 0007h
        pushf
        call    dword ptr cs:[old10_off]
        call    set_bda_cga

        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

set_emulated_mode:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es

        push    cs
        pop     ds

        mov     bl, al
        and     bl, 7Fh
        mov     [current_mode], bl
        mov     byte ptr [active_flag], 1
        mov     byte ptr [current_page], 0

        ; Program the underlying Corona path through the original BIOS mode 7.
        call    set_bda_mono
        mov     ax, 0007h
        pushf
        call    dword ptr cs:[old10_off]
        call    enter_corona_graphics
        call    set_bda_cga
        call    update_bda_video_state

        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax

        test    al, 80h
        jnz     mode_no_clear
        push    ax
        push    ds
        push    cs
        pop     ds
        call    clear_shadow
        call    clear_frame
        pop     ds
        pop     ax
mode_no_clear:
        iret
int10_set_mode endp

int10_palette proc near
        cmp     byte ptr cs:[active_flag], 0
        je      chain_old10

        push    ds
        push    cs
        pop     ds
        cmp     bh, 0
        jne     set_palette_select
        mov     [bg_color], bl
        jmp     palette_done
set_palette_select:
        cmp     bh, 1
        jne     palette_done
        mov     [palette_mode], bl
palette_done:
        pop     ds
        iret
int10_palette endp

int10_get_state proc near
        cmp     byte ptr cs:[active_flag], 0
        jne     get_graphics_state
        cmp     byte ptr cs:[current_mode], 03h
        je      get_text_state
        jmp     chain_old10
get_text_state:
        mov     ax, 5003h
        mov     bh, cs:[current_page]
        iret
get_graphics_state:
        mov     al, cs:[current_mode]
        cmp     al, 06h
        je      state_80_cols
        mov     ah, 40
        jmp     state_cols_done
state_80_cols:
        mov     ah, 80
state_cols_done:
        mov     bh, cs:[current_page]
        iret
int10_get_state endp

int10_read_pixel proc near
        cmp     byte ptr cs:[active_flag], 0
        je      chain_old10

        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds

        push    cs
        pop     ds
        call    pixel_in_bounds
        jc      read_out_of_bounds
        call    get_cga_pixel
        jmp     read_done
read_out_of_bounds:
        xor     al, al
read_done:
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        iret
int10_read_pixel endp

int10_write_pixel proc near
        cmp     byte ptr cs:[active_flag], 0
        je      chain_old10

        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es

        push    cs
        pop     ds

        call    pixel_in_bounds
        jc      write_done

        mov     bl, al                  ; requested color, bit 7 may mean XOR
        test    bl, 80h
        jz      write_plain
        call    get_cga_pixel
        cmp     byte ptr [current_mode], 06h
        je      write_xor_mono
        and     bl, 03h
        xor     al, bl
        and     al, 03h
        jmp     write_store
write_xor_mono:
        and     bl, 01h
        xor     al, bl
        and     al, 01h
        jmp     write_store
write_plain:
        mov     al, bl
        cmp     byte ptr [current_mode], 06h
        je      write_plain_mono
        and     al, 03h
        jmp     write_store
write_plain_mono:
        and     al, 01h
write_store:
        call    put_cga_pixel
        call    draw_cga_pixel

write_done:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret
int10_write_pixel endp

chain_old10 proc near
        call    set_bda_mono
        pushf
        call    dword ptr cs:[old10_off]
        call    set_bda_cga
        iret
chain_old10 endp

; ---------------------------------------------------------------------------
; BIOS Data Area helpers

set_bda_mono proc near
        push    ax
        push    ds
        mov     ax, 0040h
        mov     ds, ax
        or      byte ptr [0010h], 30h
        pop     ds
        pop     ax
        ret
set_bda_mono endp

set_bda_cga proc near
        push    ax
        push    ds
        mov     ax, 0040h
        mov     ds, ax
        and     word ptr [0010h], 0FFCFh
        or      word ptr [0010h], 0020h
        pop     ds
        pop     ax
        ret
set_bda_cga endp

update_bda_video_state proc near
        push    ax
        push    ds
        mov     ax, 0040h
        mov     ds, ax
        mov     al, cs:[current_mode]
        mov     [0049h], al
        cmp     al, 06h
        je      bda_80
        mov     word ptr [004Ah], 40
        jmp     bda_cols_done
bda_80:
        mov     word ptr [004Ah], 80
bda_cols_done:
        mov     word ptr [004Ch], 4000h
        mov     word ptr [004Eh], 0000h
        mov     byte ptr [0062h], 0
        mov     word ptr [0063h], 03D4h
        pop     ds
        pop     ax
        ret
update_bda_video_state endp

; ---------------------------------------------------------------------------
; Corona graphics setup and memory clears

enter_corona_graphics proc near
        mov     dx, 03B8h
        mov     al, MODE_CONTROL
        out     dx, al

        mov     dx, 03B4h
        mov     al, 0Ch
        out     dx, al
        inc     dx
        mov     ax, [frame_seg]
        mov     al, ah
        out     dx, al

        dec     dx
        mov     al, 0Dh
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        ret
enter_corona_graphics endp

clear_shadow proc near
        push    ax
        push    cx
        push    di
        push    es
        push    ds
        pop     es
        xor     ax, ax
        mov     di, offset cga_shadow
        mov     cx, SHADOW_SIZE / 2
        cld
        rep     stosw
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret
clear_shadow endp

clear_frame proc near
        push    ax
        push    cx
        push    di
        push    es
        mov     ax, [frame_seg]
        mov     es, ax
        xor     ax, ax
        xor     di, di
        mov     cx, 4000h
        cld
        rep     stosw
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret
clear_frame endp

; ---------------------------------------------------------------------------
; CGA shadow-buffer pixel operations

pixel_in_bounds proc near
        cmp     dx, 200
        jae     pixel_bad
        cmp     byte ptr [current_mode], 06h
        je      pixel_640
        cmp     cx, 320
        jae     pixel_bad
        clc
        ret
pixel_640:
        cmp     cx, 640
        jae     pixel_bad
        clc
        ret
pixel_bad:
        stc
        ret
pixel_in_bounds endp

calc_cga_offset proc near
        ; Input CX=x, DX=y. Output DI=byte offset in CGA shadow.
        push    ax
        push    bx
        xor     di, di
        mov     ax, dx
        test    al, 1
        jz      cga_even
        mov     di, 2000h
cga_even:
        mov     ax, dx
        shr     ax, 1
        mov     bx, ax
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1                 ; (y/2) * 64
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1                 ; (y/2) * 16
        add     ax, bx                ; (y/2) * 80
        add     di, ax
        mov     ax, cx
        cmp     byte ptr [current_mode], 06h
        je      cga_x_640
        shr     ax, 1
        shr     ax, 1                 ; x / 4
        jmp     cga_x_done
cga_x_640:
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1                 ; x / 8
cga_x_done:
        add     di, ax
        pop     bx
        pop     ax
        ret
calc_cga_offset endp

get_cga_pixel proc near
        push    cx
        call    calc_cga_offset
        cmp     byte ptr [current_mode], 06h
        je      get_cga_640

        mov     al, [cga_shadow + di]
        mov     bl, cl
        and     bl, 03h
        mov     cl, 3
        sub     cl, bl
        shl     cl, 1
        shr     al, cl
        and     al, 03h
        pop     cx
        ret

get_cga_640:
        mov     bl, cl
        and     bl, 07h
        mov     ah, 80h
get_mask_loop:
        cmp     bl, 0
        je      get_mask_ready
        shr     ah, 1
        dec     bl
        jmp     get_mask_loop
get_mask_ready:
        xor     al, al
        test    [cga_shadow + di], ah
        jz      get_done
        inc     al
get_done:
        pop     cx
        ret
get_cga_pixel endp

put_cga_pixel proc near
        ; Input AL=color, CX=x, DX=y.
        push    ax
        push    bx
        push    cx
        push    di
        call    calc_cga_offset
        cmp     byte ptr [current_mode], 06h
        je      put_cga_640

        mov     bh, al
        mov     al, [cga_shadow + di]
        mov     bl, cl
        and     bl, 03h
        mov     cl, 3
        sub     cl, bl
        shl     cl, 1
        mov     bl, 03h
        shl     bl, cl
        not     bl
        and     al, bl
        mov     bl, bh
        and     bl, 03h
        shl     bl, cl
        or      al, bl
        mov     [cga_shadow + di], al
        jmp     put_done

put_cga_640:
        mov     bh, al
        mov     bl, cl
        and     bl, 07h
        mov     al, 80h
put_mask_loop:
        cmp     bl, 0
        je      put_mask_ready
        shr     al, 1
        dec     bl
        jmp     put_mask_loop
put_mask_ready:
        cmp     bh, 0
        je      put_clear_640
        or      [cga_shadow + di], al
        jmp     put_done
put_clear_640:
        not     al
        and     [cga_shadow + di], al
put_done:
        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret
put_cga_pixel endp

; ---------------------------------------------------------------------------
; Draw CGA pixels into the Corona 640x325 1bpp framebuffer

draw_cga_pixel proc near
        ; Input AL=color, CX=x, DX=y.
        cmp     byte ptr [current_mode], 06h
        je      draw_640_pixel
        jmp     draw_320_pixel
draw_cga_pixel endp

draw_320_pixel proc near
        push    ax
        push    bx
        push    cx
        push    dx
        push    bp

        mov     bl, al
        mov     bh, 0                  ; left pixel
        xor     bp, bp                 ; right pixel

        cmp     bl, 0
        je      draw_320_have_pattern
        cmp     bl, 3
        je      draw_320_full
        cmp     bl, 2
        je      draw_320_half

        ; Color 1: 25 percent checker.
        mov     ax, cx
        xor     ax, dx
        test    al, 1
        jnz     draw_320_have_pattern
        mov     bh, 1
        jmp     draw_320_have_pattern

draw_320_half:
        mov     ax, cx
        xor     ax, dx
        test    al, 1
        jz      draw_320_half_left
        mov     bp, 1
        jmp     draw_320_have_pattern
draw_320_half_left:
        mov     bh, 1
        jmp     draw_320_have_pattern

draw_320_full:
        mov     bh, 1
        mov     bp, 1

draw_320_have_pattern:
        shl     cx, 1                  ; destination x = source x * 2
        mov     al, bh
        call    write_corona_pixel
        inc     cx
        mov     ax, bp
        call    write_corona_pixel

        pop     bp
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
draw_320_pixel endp

draw_640_pixel proc near
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     bl, al                  ; color
        cmp     byte ptr [line_stretch], 0
        jne     draw_640_stretch

        mov     al, bl
        call    write_corona_pixel
        jmp     draw_640_done

draw_640_stretch:
        ; Map 200 source rows to all 325 Corona rows:
        ;   start = floor(y * 13 / 8)
        ;   end   = floor((y + 1) * 13 / 8) - 1
        call    scale_y_13_8
        mov     si, ax
        inc     dx
        call    scale_y_13_8
        dec     ax
        dec     dx
        mov     di, ax
        mov     dx, si
draw_640_row_loop:
        mov     al, bl
        call    write_corona_pixel
        cmp     dx, di
        jae     draw_640_done
        inc     dx
        jmp     draw_640_row_loop

draw_640_done:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
draw_640_pixel endp

scale_y_13_8 proc near
        ; Input DX=y. Output AX=floor(y*13/8).
        push    bx
        push    cx
        mov     ax, dx
        mov     bx, ax
        mov     cx, ax
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1                  ; y * 8
        shl     bx, 1
        shl     bx, 1                  ; y * 4
        add     ax, bx
        add     ax, cx                 ; y * 13
        mov     cl, 3
        shr     ax, cl
        pop     cx
        pop     bx
        ret
scale_y_13_8 endp

write_corona_pixel proc near
        ; Input AL=0/1, CX=x 0..639, DX=y 0..324.
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        mov     bp, ax                  ; keep requested 0/1 value
        mov     si, cx

        mov     ax, dx
        mov     bl, 13
        div     bl                      ; AL=y/13, AH=y mod 13

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
corona_mask_loop:
        cmp     bl, 0
        je      corona_mask_ready
        shl     al, 1
        dec     bl
        jmp     corona_mask_loop

corona_mask_ready:
        push    ax
        mov     ax, [frame_seg]
        mov     es, ax
        pop     ax
        cmp     bp, 0
        je      corona_clear
        or      es:[di], al
        jmp     corona_done
corona_clear:
        not     al
        and     es:[di], al
corona_done:
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
write_corona_pixel endp

; ---------------------------------------------------------------------------
; Text output helpers used only at install time

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

; ---------------------------------------------------------------------------
; Resident data

old10_off       dw      0
old10_seg       dw      0
old11_off       dw      0
old11_seg       dw      0
install_sig     dw      INSTALL_SIG
frame_seg       dw      0
current_mode    db      7
active_flag     db      0
current_page    db      0
line_stretch    db      1
unload_flag     db      0
palette_mode    db      0
bg_color        db      0
resident_seg    dw      0
unload10_off    dw      0
unload10_seg    dw      0
unload11_off    dw      0
unload11_seg    dw      0

install_stack   db      256 dup (0)
install_stack_top label byte

trace_title_msg db      'CGA105 install trace',0Dh,0Ah,'$'
trace_parse_msg db      '1 parse command tail',0Dh,0Ah,'$'
trace_choose_msg db     '2 choose Corona page',0Dh,0Ah,'$'
trace_frame_msg db      '  selected page segment $'
trace_clear_shadow_msg db '3 clear CGA shadow buffer',0Dh,0Ah,'$'
trace_clear_frame_msg db '4 clear Corona page',0Dh,0Ah,'$'
trace_save10_msg db     '5 save INT 10h vector',0Dh,0Ah,'$'
trace_save11_msg db     '6 save INT 11h vector',0Dh,0Ah,'$'
trace_hook10_msg db     '7 hook INT 10h',0Dh,0Ah,'$'
trace_hook11_msg db     '8 hook INT 11h',0Dh,0Ah,'$'
trace_bda_msg db        '9 set CGA equipment bits for DOS programs',0Dh,0Ah,'$'
installed_msg   db      'CGA105 resident. BDA/INT 11h report CGA. Corona buffer at $'
installed_msg_2 db      ':0000, mode 6 stretch $'
stretch_on_msg  db      'ON',0Dh,0Ah,'$'
stretch_off_msg db      'OFF',0Dh,0Ah,'$'
failed_msg      db      'CGA105: no 32K-aligned Corona graphics page is available below 40000h.',0Dh,0Ah,'$'
unload_check_msg db     'CGA105 unload: checking resident hooks...',0Dh,0Ah,'$'
unload_restore_msg db   'CGA105 unload: restoring vectors and mono state...',0Dh,0Ah,'$'
unload_done_msg db      'CGA105 unloaded.',0Dh,0Ah,'$'
unload_not_found_msg db 'CGA105 unload: resident copy is not installed.',0Dh,0Ah,'$'
unload_blocked_msg db   'CGA105 unload: another TSR is above CGA105; reboot or unload that TSR first.',0Dh,0Ah,'$'
unload_free_failed_msg db 'CGA105 unload: vectors restored, but DOS could not free resident memory.',0Dh,0Ah,'$'

cga_shadow      db      SHADOW_SIZE dup (0)

resident_end    label   byte
RESIDENT_PARAS  equ     (resident_end + 15) / 16

        end     start
