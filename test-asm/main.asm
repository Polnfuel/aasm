@entry start

@import
    print, print_number

@data
main_msg:   d8 "Main module!",10,0
msg:        d8 "Your number is: ", 0
#newline:    d8 10,0

@code
start:
    lea rsi, [main_msg]
    call print

    lea rsi, [msg]
    call print

    mov rax, 1234567890
    call print_number

    lea rsi, [newline]
    call print

#exit:
    mov rax, 60
    mov rdi, 0
    syscall