const std = @import("std");

const String = struct {
    slice: []u8,

    pub fn new(self: *String, ptr: [*]const u8) void {
        self.slice = ptr[0..0];
    }

    pub fn addByte(self: *String) void {
        self.slice.len += 1;
    }

    pub fn is(self: String, str: []const u8) bool {
        return std.mem.eql(u8, self.slice, str);
    }
};

pub const TokenType = enum(u8) {

    //Keywords
    Entry,
    Section,
    Data,
    Code,
    D8,
    D16,
    D32,
    D64,
    Repeat,
    P8,
    P16,
    P32,
    P64,

    //Instruction mnemonics
    Mov,
    Cmp,
    Ja,
    Je,
    Jne,
    Jz,
    Jmp,
    Call,
    Ret,
    Syscall,
    Xor,
    Add,
    Sub,
    Imul,
    Div,
    Inc,
    Dec,
    Test,
    Lea,
    Push,
    Pop,

    //Registers
    //64-bit
    Rax,
    Rbx,
    Rcx,
    Rdx,
    Rdi,
    Rsi,
    Rsp,
    Rbp,
    Rip,
    R8,
    R9,
    R10,
    R11,
    R12,
    R13,
    R14,
    R15,
    //32-bit
    Eax,
    Ebx,
    Ecx,
    Edx,
    Edi,
    Esi,
    Esp,
    Ebp,
    Eip,
    R8d,
    R9d,
    R10d,
    R11d,
    R12d,
    R13d,
    R14d,
    R15d,
    //16-bit
    Ax,
    Bx,
    Cx,
    Dx,
    Di,
    Si,
    Sp,
    Bp,
    R8w,
    R9w,
    R10w,
    R11w,
    R12w,
    R13w,
    R14w,
    R15w,
    //8-bit
    Ah,
    Al,
    Bh,
    Bl,
    Ch,
    Cl,
    Dh,
    Dl,
    Sil,
    Dil,
    Bpl,
    Spl,
    R8b,
    R9b,
    R10b,
    R11b,
    R12b,
    R13b,
    R14b,
    R15b,

    //Literals
    Ident,
    StringLiteral,
    NumberLiteral,

    //Punctuation
    Slash,
    Colon,
    Comma,
    Plus,
    OpenBracket,
    CloseBracket,
    OpenParenthes,
    CloseParenthes,
    NewLine,

    pub fn isReg(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.Rax);
        const upper = @intFromEnum(TokenType.R15b);
        const r = @intFromEnum(self);
        if (r >= lower and r <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isMnemonic(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.Mov);
        const upper = @intFromEnum(TokenType.Pop);
        const m = @intFromEnum(self);
        if (m >= lower and m <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isPointerSize(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.P8);
        const upper = @intFromEnum(TokenType.P64);
        const p = @intFromEnum(self);
        if (p >= lower and p <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isAdditionalReg(self: TokenType) bool {
        const r = @intFromEnum(self);
        const is = (r >= @intFromEnum(TokenType.R8) and r <= @intFromEnum(TokenType.R15)) or
            (r >= @intFromEnum(TokenType.R8d) and r <= @intFromEnum(TokenType.R15d)) or
            (r >= @intFromEnum(TokenType.R8w) and r <= @intFromEnum(TokenType.R15w)) or
            (r >= @intFromEnum(TokenType.R8b) and r <= @intFromEnum(TokenType.R15b));
        return is;
    }
};

pub const Token = struct {
    type: TokenType,
    value: ?[]u8,
};

pub var tokens: std.ArrayList(Token) = undefined;

fn analyzeWord(word: String) Token {
    // Keywords
    if (word.is("d8")) {
        return Token{ .type = .D8, .value = null };
    } else if (word.is("d16")) {
        return Token{ .type = .D16, .value = null };
    } else if (word.is("d32")) {
        return Token{ .type = .D32, .value = null };
    } else if (word.is("d64")) {
        return Token{ .type = .D64, .value = null };
    } else if (word.is("p8")) {
        return Token{ .type = .P8, .value = null };
    } else if (word.is("p16")) {
        return Token{ .type = .P16, .value = null };
    } else if (word.is("p32")) {
        return Token{ .type = .P32, .value = null };
    } else if (word.is("p64")) {
        return Token{ .type = .P64, .value = null };
    } else if (word.is("data")) {
        return Token{ .type = .Data, .value = null };
    } else if (word.is("code")) {
        return Token{ .type = .Code, .value = null };
    } else if (word.is("entry")) {
        return Token{ .type = .Entry, .value = null };
    } else if (word.is("section")) {
        return Token{ .type = .Section, .value = null };
    } else if (word.is("repeat")) {
        return Token{ .type = .Repeat, .value = null };
    }
    // Instructions
    else if (word.is("mov")) {
        return Token{ .type = .Mov, .value = null };
    } else if (word.is("cmp")) {
        return Token{ .type = .Cmp, .value = null };
    } else if (word.is("je")) {
        return Token{ .type = .Je, .value = null };
    } else if (word.is("jne")) {
        return Token{ .type = .Jne, .value = null };
    } else if (word.is("call")) {
        return Token{ .type = .Call, .value = null };
    } else if (word.is("ret")) {
        return Token{ .type = .Ret, .value = null };
    } else if (word.is("syscall")) {
        return Token{ .type = .Syscall, .value = null };
    } else if (word.is("jmp")) {
        return Token{ .type = .Jmp, .value = null };
    } else if (word.is("xor")) {
        return Token{ .type = .Xor, .value = null };
    } else if (word.is("add")) {
        return Token{ .type = .Add, .value = null };
    } else if (word.is("sub")) {
        return Token{ .type = .Sub, .value = null };
    } else if (word.is("imul")) {
        return Token{ .type = .Imul, .value = null };
    } else if (word.is("div")) {
        return Token{ .type = .Div, .value = null };
    } else if (word.is("inc")) {
        return Token{ .type = .Inc, .value = null };
    } else if (word.is("dec")) {
        return Token{ .type = .Dec, .value = null };
    } else if (word.is("test")) {
        return Token{ .type = .Test, .value = null };
    } else if (word.is("lea")) {
        return Token{ .type = .Lea, .value = null };
    } else if (word.is("push")) {
        return Token{ .type = .Push, .value = null };
    } else if (word.is("pop")) {
        return Token{ .type = .Pop, .value = null };
    }
    // Registers
    else if (word.is("rax")) {
        return Token{ .type = .Rax, .value = null };
    } else if (word.is("rbx")) {
        return Token{ .type = .Rbx, .value = null };
    } else if (word.is("rcx")) {
        return Token{ .type = .Rcx, .value = null };
    } else if (word.is("rdx")) {
        return Token{ .type = .Rdx, .value = null };
    } else if (word.is("rsi")) {
        return Token{ .type = .Rsi, .value = null };
    } else if (word.is("rdi")) {
        return Token{ .type = .Rdi, .value = null };
    } else if (word.is("rsp")) {
        return Token{ .type = .Rsp, .value = null };
    } else if (word.is("rbp")) {
        return Token{ .type = .Rbp, .value = null };
    } else if (word.is("rip")) {
        return Token{ .type = .Rip, .value = null };
    } else if (word.is("r8")) {
        return Token{ .type = .R8, .value = null };
    } else if (word.is("r9")) {
        return Token{ .type = .R9, .value = null };
    } else if (word.is("r10")) {
        return Token{ .type = .R10, .value = null };
    } else if (word.is("r11")) {
        return Token{ .type = .R11, .value = null };
    } else if (word.is("r12")) {
        return Token{ .type = .R12, .value = null };
    } else if (word.is("r13")) {
        return Token{ .type = .R13, .value = null };
    } else if (word.is("r14")) {
        return Token{ .type = .R14, .value = null };
    } else if (word.is("r15")) {
        return Token{ .type = .R15, .value = null };
    } else if (word.is("eax")) {
        return Token{ .type = .Eax, .value = null };
    } else if (word.is("ebx")) {
        return Token{ .type = .Ebx, .value = null };
    } else if (word.is("ecx")) {
        return Token{ .type = .Ecx, .value = null };
    } else if (word.is("edx")) {
        return Token{ .type = .Edx, .value = null };
    } else if (word.is("edi")) {
        return Token{ .type = .Edi, .value = null };
    } else if (word.is("esi")) {
        return Token{ .type = .Esi, .value = null };
    } else if (word.is("esp")) {
        return Token{ .type = .Esp, .value = null };
    } else if (word.is("ebp")) {
        return Token{ .type = .Ebp, .value = null };
    } else if (word.is("eip")) {
        return Token{ .type = .Eip, .value = null };
    } else if (word.is("r8d")) {
        return Token{ .type = .R8d, .value = null };
    } else if (word.is("r9d")) {
        return Token{ .type = .R9d, .value = null };
    } else if (word.is("r10d")) {
        return Token{ .type = .R10d, .value = null };
    } else if (word.is("r11d")) {
        return Token{ .type = .R11d, .value = null };
    } else if (word.is("r12d")) {
        return Token{ .type = .R12d, .value = null };
    } else if (word.is("r13d")) {
        return Token{ .type = .R13d, .value = null };
    } else if (word.is("r14d")) {
        return Token{ .type = .R14d, .value = null };
    } else if (word.is("r15d")) {
        return Token{ .type = .R15d, .value = null };
    } else if (word.is("ax")) {
        return Token{ .type = .Ax, .value = null };
    } else if (word.is("bx")) {
        return Token{ .type = .Bx, .value = null };
    } else if (word.is("cx")) {
        return Token{ .type = .Cx, .value = null };
    } else if (word.is("dx")) {
        return Token{ .type = .Dx, .value = null };
    } else if (word.is("di")) {
        return Token{ .type = .Di, .value = null };
    } else if (word.is("si")) {
        return Token{ .type = .Si, .value = null };
    } else if (word.is("sp")) {
        return Token{ .type = .Sp, .value = null };
    } else if (word.is("bp")) {
        return Token{ .type = .Bp, .value = null };
    } else if (word.is("r8w")) {
        return Token{ .type = .R8w, .value = null };
    } else if (word.is("r9w")) {
        return Token{ .type = .R9w, .value = null };
    } else if (word.is("r10w")) {
        return Token{ .type = .R10w, .value = null };
    } else if (word.is("r11w")) {
        return Token{ .type = .R11w, .value = null };
    } else if (word.is("r12w")) {
        return Token{ .type = .R12w, .value = null };
    } else if (word.is("r13w")) {
        return Token{ .type = .R13w, .value = null };
    } else if (word.is("r14w")) {
        return Token{ .type = .R14w, .value = null };
    } else if (word.is("r15w")) {
        return Token{ .type = .R15w, .value = null };
    } else if (word.is("ah")) {
        return Token{ .type = .Ah, .value = null };
    } else if (word.is("al")) {
        return Token{ .type = .Al, .value = null };
    } else if (word.is("bh")) {
        return Token{ .type = .Bh, .value = null };
    } else if (word.is("bl")) {
        return Token{ .type = .Bl, .value = null };
    } else if (word.is("ch")) {
        return Token{ .type = .Ch, .value = null };
    } else if (word.is("cl")) {
        return Token{ .type = .Cl, .value = null };
    } else if (word.is("dh")) {
        return Token{ .type = .Dh, .value = null };
    } else if (word.is("dl")) {
        return Token{ .type = .Dl, .value = null };
    } else if (word.is("sil")) {
        return Token{ .type = .Sil, .value = null };
    } else if (word.is("dil")) {
        return Token{ .type = .Dil, .value = null };
    } else if (word.is("bpl")) {
        return Token{ .type = .Bpl, .value = null };
    } else if (word.is("spl")) {
        return Token{ .type = .Spl, .value = null };
    } else if (word.is("r8b")) {
        return Token{ .type = .R8b, .value = null };
    } else if (word.is("r9b")) {
        return Token{ .type = .R9b, .value = null };
    } else if (word.is("r10b")) {
        return Token{ .type = .R10b, .value = null };
    } else if (word.is("r11b")) {
        return Token{ .type = .R11b, .value = null };
    } else if (word.is("r12b")) {
        return Token{ .type = .R12b, .value = null };
    } else if (word.is("r13b")) {
        return Token{ .type = .R13b, .value = null };
    } else if (word.is("r14b")) {
        return Token{ .type = .R14b, .value = null };
    } else if (word.is("r15b")) {
        return Token{ .type = .R15b, .value = null };
    } else {
        return Token{ .type = .Ident, .value = word.slice };
    }
}

pub fn tokenizeContent(content: []const u8, allocator: std.mem.Allocator) !void {
    tokens = .empty;
    var word: String = undefined;
    word.new(content.ptr);
    var in_word = true;
    var in_strlit = false;
    var in_numlit = false;
    var in_comment = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const byte = content[i];
        if (in_comment and byte != '\n') {
            continue;
        }
        if (in_strlit and byte != '"' and byte != '\n') {
            word.addByte();
            continue;
        }
        switch (byte) {
            ' ' => {
                if (in_word) {
                    if (in_numlit) {
                        try tokens.append(allocator, .{ .type = .NumberLiteral, .value = word.slice });
                        in_word = false;
                        in_numlit = false;
                    } else {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                        in_word = false;
                    }
                }
            },
            '\n' => {
                if (in_word) {
                    if (in_numlit) {
                        try tokens.append(allocator, .{ .type = .NumberLiteral, .value = word.slice });
                        in_word = false;
                        in_numlit = false;
                    } else if (in_strlit) {
                        // not closed string literal  -- error
                    } else {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                        in_word = false;
                    }
                    try tokens.append(allocator, Token{ .type = .NewLine, .value = null });
                } else if (in_comment) {
                    in_comment = false;
                } else if (tokens.getLastOrNull().?.type == .NewLine) {
                    // skip empty string
                    continue;
                } else {
                    try tokens.append(allocator, Token{ .type = .NewLine, .value = null });
                }
            },
            '/' => {
                if (in_word) {
                    const token = analyzeWord(word);
                    try tokens.append(allocator, token);
                    in_word = false;
                }
                try tokens.append(allocator, .{ .type = .Slash, .value = null });
            },
            ':' => {
                if (in_word) {
                    const token = analyzeWord(word);
                    try tokens.append(allocator, token);
                    in_word = false;
                }
                try tokens.append(allocator, .{ .type = .Colon, .value = null });
            },
            ',' => {
                if (in_word) {
                    if (in_numlit) {
                        try tokens.append(allocator, .{ .type = .NumberLiteral, .value = word.slice });
                        in_word = false;
                        in_numlit = false;
                    } else {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                        in_word = false;
                    }
                }
                try tokens.append(allocator, .{ .type = .Comma, .value = null });
            },
            '[' => {
                if (in_word) {
                    const token = analyzeWord(word);
                    try tokens.append(allocator, token);
                    in_word = false;
                }
                try tokens.append(allocator, .{ .type = .OpenBracket, .value = null });
            },
            ']' => {
                if (in_word) {
                    const token = analyzeWord(word);
                    try tokens.append(allocator, token);
                    in_word = false;
                }
                try tokens.append(allocator, .{ .type = .CloseBracket, .value = null });
            },
            '(' => {
                if (in_word) {
                    const token = analyzeWord(word);
                    try tokens.append(allocator, token);
                    in_word = false;
                }
                try tokens.append(allocator, .{ .type = .OpenParenthes, .value = null });
            },
            ')' => {
                if (in_word) {
                    if (in_numlit) {
                        try tokens.append(allocator, .{ .type = .NumberLiteral, .value = word.slice });
                        in_word = false;
                        in_numlit = false;
                    } else {
                        // should not be -- error?
                    }
                }
                try tokens.append(allocator, .{ .type = .CloseParenthes, .value = null });
            },
            '"' => {
                if (!in_strlit) {
                    //string literal starts
                    in_strlit = true;
                    word.new(content[i..i].ptr + 1);
                } else {
                    //string literal ends
                    try tokens.append(allocator, .{ .type = .StringLiteral, .value = word.slice });
                    in_strlit = false;
                    in_word = false;
                }
            },
            ';' => {
                in_comment = true;
                if (in_word) {
                    const token = analyzeWord(word);
                    try tokens.append(allocator, token);
                }
                in_word = false;
            },
            'A'...'Z', 'a'...'z' => {
                if (!in_word) {
                    word.new(content[i..i].ptr);
                }
                if (in_numlit) {
                    in_numlit = false;
                    //9d   - error
                }
                word.addByte();
                in_word = true;
            },
            '0'...'9' => {
                if (!in_word) {
                    in_numlit = true;
                    word.new(content[i..i].ptr);
                }
                word.addByte();
                in_word = true;
            },
            '+' => {
                if (in_word) {
                    const token = analyzeWord(word);
                    try tokens.append(allocator, token);
                    in_word = false;
                }
                try tokens.append(allocator, .{ .type = .Plus, .value = null });
            },
            else => {
                if (in_word) {
                    word.addByte();
                }
            },
        }
    }
}

pub fn printTokens() void {
    for (tokens.items) |token| {
        if (token.type.isMnemonic()) {
            std.debug.print("\x1b[34m{any}\x1b[0m\n", .{token.type});
        } else if (token.type.isReg()) {
            std.debug.print("\x1b[35m{any}\x1b[0m\n", .{token.type});
        } else if (token.type == .NewLine) {
            std.debug.print("\n", .{});
        } else {
            std.debug.print("{any}  {s}\n", .{ token.type, token.value orelse "" });
        }
    }
}
