section export 
    print, print_number

section import
    inttostr

section data rw


section code rx
; in: rsi - null-terminated string pointer
; out: rax - number of bytes written
print:
    xor rdx, rdx
pr_1:
    mov bl, [rsi + rdx]
    cmp bl, 0
    je pr_2
    inc rdx
    jmp pr_1
pr_2:
    mov rdi, 1
    mov rax, 1
    syscall

    ret

; in: rax - number to print
print_number:
    call inttostr

    mov rsi, rax
    call print
    ret