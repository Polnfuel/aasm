entry start

section export 
    exit

section import
    print, print_number

section data rw
main_msg:   d8 "Main module!",10,0
msg:        d8 "Your number is: ", 0
newline:    d8 10,0

section code rx
start:
    mov rsi, main_msg
    call print

    mov rsi, msg
    call print

    mov rax, 1234567890
    call print_number

    mov rsi, newline
    call print

exit:
    mov rax, 60
    mov rdi, 0
    syscall