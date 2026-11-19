; mouse_coords.asm -- Linux x86-64 / NASM
;
; Enables SGR 1006 mouse reporting + "any motion" (1003) in the terminal,
; then reads the escape sequences the terminal sends and prints the
; pointer's column/row as X: .../Y: ...
;
; Build:
;   nasm -felf64 mouse_coords.asm -o mouse_coords.o
;   ld mouse_coords.o -o mouse_coords
;
; Run:  ./mouse_coords      (move the mouse inside the terminal window)
; Quit: Ctrl-C (terminal state is restored automatically)
;
; Note: coordinates are reported by the terminal (1-based column/row).

BITS 64
default rel

section .data
    enable_mouse  db 1bh, '[?1006h', 1bh, '[?1003h'
    enable_len    equ $ - enable_mouse
    disable_mouse db 1bh, '[?1003l', 1bh, '[?1006l'
    disable_len   equ $ - disable_mouse

    lbl_x    db 'X: '
    lbl_xlen equ $ - lbl_x
    lbl_y    db ' Y: '
    lbl_ylen equ $ - lbl_y
    nl       db 10

section .bss
    inbuf  resb 1        ; one byte read from stdin
    outbuf resb 32       ; scratch for integer -> string
    state  resb 1        ; 0=idle 1=ESC 2='[' 3=number
    field    resb 1        ; 0=button 1=X 2=Y
    cur    resq 1        ; accumulator for the number being parsed
    btn    resq 1        ; button/motion flags (unused)
    xpos   resq 1
    ypos   resq 1

    TCGETS    equ 0x5401
    TCSETS    equ 0x5402
    ; termios.c_lflag bits we clear: ISIG(1) | ICANON(2) | ECHO(8)
    LFLAG_CLEAR equ 0FFFFFFF4h
    term_orig resb 36    ; kernel struct termios on x86-64
    term_raw  resb 36

section .text
global _start

_start:
    ; Put stdin into raw mode so mouse escape sequences arrive immediately.
    ; (If stdin is not a tty, TCGETS fails and we simply continue.)
    mov rax, 16                ; sys_ioctl
    xor rdi, rdi               ; stdin
    mov rsi, TCGETS
    mov rdx, term_orig
    syscall
    test rax, rax
    js .no_raw

    cld
    mov rsi, term_orig
    mov rdi, term_raw
    mov rcx, 9                 ; 36 bytes = 9 dwords
    rep movsd
    and dword [term_raw+12], LFLAG_CLEAR   ; clear ICANON/ECHO/ISIG

    mov rax, 16
    xor rdi, rdi
    mov rsi, TCSETS
    mov rdx, term_raw
    syscall
.no_raw:

    ; Turn on SGR extended mouse reporting and any-motion events.
    mov rax, 1                 ; sys_write
    mov rdi, 1                 ; stdout
    mov rsi, enable_mouse
    mov rdx, enable_len
    syscall

.main_loop:
    ; Read a single byte from stdin.
    mov rax, 0                 ; sys_read
    xor rdi, rdi               ; stdin
    mov rsi, inbuf
    mov rdx, 1
    syscall
    test rax, rax
    jle .done                  ; EOF or error -> restore terminal

    movzx rax, byte [inbuf]    ; current character
    movzx rcx, byte [state]

    cmp rcx, 0
    je .st0
    cmp rcx, 1
    je .st1
    cmp rcx, 2
    je .st2
    jmp .num                   ; state 3: inside a number

.st0:                          ; idle, waiting for ESC (or Ctrl-C to quit)
    cmp rax, 3
    je .done
    cmp rax, 1bh
    jne .main_loop
    mov byte [state], 1
    jmp .main_loop

.st1:                          ; saw ESC, expect '['
    cmp rax, '['
    je .st1_ok
    mov byte [state], 0
    cmp rax, 1bh               ; allow a fresh ESC
    jne .main_loop
    mov byte [state], 1
    jmp .main_loop
.st1_ok:
    mov byte [state], 2
    jmp .main_loop

.st2:                          ; saw '[', expect '<' (SGR format)
    cmp rax, '<'
    jne .st2_fail
    mov qword [cur], 0
    mov byte [field], 0
    mov byte [state], 3
    jmp .main_loop
.st2_fail:
    mov byte [state], 0
    jmp .main_loop

.num:                          ; accumulate digits: Cb;Cx;CyM
    cmp rax, '0'
    jb .num_non
    cmp rax, '9'
    ja .num_non
    sub rax, '0'
    mov rbx, [cur]
    imul rbx, 10
    add rbx, rax
    mov [cur], rbx
    jmp .main_loop

.num_non:
    cmp rax, ';'
    je .semi
    cmp rax, 'M'
    je .final
    cmp rax, 'm'               ; button release also ends a report
    je .final
    mov byte [state], 0        ; unexpected byte -> resync
    jmp .main_loop

.semi:
    movzx rcx, byte [field]
    cmp rcx, 0
    je .save_btn
    cmp rcx, 1
    je .save_x
    mov byte [state], 0        ; too many fields -> resync
    jmp .main_loop
.save_btn:
    mov rbx, [cur]
    mov [btn], rbx
    jmp .next_field
.save_x:
    mov rbx, [cur]
    mov [xpos], rbx
.next_field:
    inc byte [field]
    mov qword [cur], 0
    jmp .main_loop

.final:
    mov rbx, [cur]
    mov [ypos], rbx
    call print_coords
    mov byte [state], 0
    jmp .main_loop

.done:
    ; Restore the original terminal mode (including ISIG/CANON/ECHO).
    mov rax, 16                ; sys_ioctl
    xor rdi, rdi
    mov rsi, TCSETS
    mov rdx, term_orig
    syscall

    ; Disable mouse tracking before exiting.
    mov rax, 1
    mov rdi, 1
    mov rsi, disable_mouse
    mov rdx, disable_len
    syscall

    mov rax, 60                ; sys_exit
    xor rdi, rdi
    syscall

; ------------------------------------------------------------------
; print_coords: emit "X: <x> Y: <y>\n" using the values in xpos/ypos.
; ------------------------------------------------------------------
print_coords:
    mov rax, 1
    mov rdi, 1
    mov rsi, lbl_x
    mov rdx, lbl_xlen
    syscall

    mov rdi, [xpos]
    call print_num

    mov rax, 1
    mov rdi, 1
    mov rsi, lbl_y
    mov rdx, lbl_ylen
    syscall

    mov rdi, [ypos]
    call print_num

    mov rax, 1
    mov rdi, 1
    mov rsi, nl
    mov rdx, 1
    syscall
    ret

; ------------------------------------------------------------------
; print_num: rdi = unsigned integer -> decimal string on stdout.
; ------------------------------------------------------------------
print_num:
    mov rax, rdi
    mov rbx, 10
    mov rcx, outbuf + 32
    test rax, rax
    jnz .loop
    dec rcx
    mov byte [rcx], '0'
    jmp .write
.loop:
    xor rdx, rdx
    div rbx
    add rdx, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz .loop
.write:
    mov rax, 1
    mov rdi, 1
    mov rsi, rcx
    mov rdx, outbuf + 32
    sub rdx, rcx
    syscall
    ret
