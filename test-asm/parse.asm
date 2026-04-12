section export 
    inttostr

section import

section data rw
; first 32 bytes for output
; last 32 bytes for reverse
buffer: d8 repeat(64, 0)

section code rx
; in: rax - integer number
; out: rax - pointer to null-terminated string representing number
inttostr:
    xor rcx, rcx
    lea rbx, [buffer]
    add rbx, 32
    mov r8, 10
ps_1:
    xor rdx, rdx
    div r8
    ; rdx - last digit
    ; rax - number without last digit
    add rdx, "0"
    mov [rbx+rcx], dl
    inc rcx
    test rax, rax
    jnz ps_1
    
    ; buffer[32..32+rcx-1] contains number bytes in reverse order
    lea r8, [buffer]
ps_2:
    mov dl, [rbx+rcx-1]
    mov [r8+rax], dl
    inc rax
    dec rcx
    test rcx, rcx
    jnz ps_2
    
    mov p8 [r8+rax], 0 ; null after number bytes
    mov rax, r8
    
    ret