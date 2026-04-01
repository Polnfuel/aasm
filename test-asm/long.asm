entry start

section export 
    exit, print_newline

section import
    print

section data rw
msg:        d8 "Sum of array: ", 0
newline:    d8 10

array:      d64 5, 10, 15, 20, 25
count:      d64 5

buffer:     d8 repeat(32, 0)

section code rx
start:
    ; rbx = pointer to array
    mov rbx, array

    ; rcx = count
    mov rcx, [count]

    xor rax, rax

loop_sum:
    add rax, p64 [rbx]
    add rbx, 8
    dec rcx
    jne loop_sum

    ; result now in rax

    push rax

    ; print message
    mov rax, 1
    mov rdi, 1
    mov rsi, msg
    mov rdx, 14
    syscall

    pop rax

    ; convert number to ascii
    mov rbx, buffer
    ;mov rcx, 0
    xor rcx, rcx

convert:
    xor rdx, rdx
    mov r8, 10
    div r8

    add rdx, "0"
    mov [rbx+rcx], dl

    inc rcx
    test rax, rax
    jne convert

    ; print digits in reverse
print_digits:
    test rcx, rcx
    je print_newline

    dec rcx

    push rcx

    mov rax, 1
    mov rdi, 1
    lea rsi, [rbx+rcx]
    mov rdx, 1
    syscall

    pop rcx

    jmp print_digits

print_newline:
    mov rax, 1
    mov rdi, 1
    mov rsi, newline
    mov rdx, 1
    syscall

exit:
    mov rax, 60
    mov rdi, 0
    syscall
