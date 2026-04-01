section import 
    exit
    print_newline

section export
    print

section code rx

print:
    mov rdx, rbx
    mov rax, 0
    jmp exit
