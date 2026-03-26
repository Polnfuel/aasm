const std = @import("std");

const String = struct {
    slice: []u8,

    pub fn new(ptr: [*]const u8) String {
        return String{ .slice = ptr[0..0] };
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
    PosNumLiteral,
    NegNumLiteral,

    //Punctuation
    Slash,
    Colon,
    Comma,
    Plus,
    Minus,
    Asteriks,
    OpenBracket,
    CloseBracket,
    OpenParenthes,
    CloseParenthes,
    NewLine,

    //Special
    NotPresent,

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

    pub fn isDataDirective(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.D8);
        const upper = @intFromEnum(TokenType.D64);
        const d = @intFromEnum(self);
        if (d >= lower and d <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isAccumulator(self: TokenType) bool {
        switch (self) {
            TokenType.Al, TokenType.Ax, TokenType.Eax, TokenType.Rax => {
                return true;
            },
            else => {
                return false;
            },
        }
    }
};

pub const Token = struct {
    type: TokenType,
    value: ?[]u8,
};

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
    } else if (word.is("ja")) {
        return Token{ .type = .Ja, .value = null };
    } else if (word.is("jz")) {
        return Token{ .type = .Jz, .value = null };
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

const LexerState = enum {
    TopLevel,
    Word,
    String,
    Number,
    Comment,

    PlusSign,
    MinusSign,
    PosNumber,
    NegNumber,
};

const LexerError = error{
    InvalidCharacher,
    NotClosedString,
    InvalidIdentifierName,
};

pub fn tokenizeContent(content: []const u8, allocator: std.mem.Allocator) !std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;

    var line: usize = 1;
    errdefer {
        std.debug.print("lexer error on line {d}\n", .{line});
        tokens.deinit(allocator);
    }

    var state: LexerState = .TopLevel;
    var word: String = String.new(content.ptr);

    for (content, 0..) |byte, i| {
        if (byte != '\n') {
            if (byte != '"' and state == .String) {
                word.addByte();
                continue;
            } else if (state == .Comment) {
                continue;
            }
        }
        switch (byte) {
            'A'...'Z', 'a'...'z', '_' => {
                switch (state) {
                    .Word => {
                        word.addByte();
                    },
                    .TopLevel => {
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .Word;
                    },
                    .Number, .PosNumber, .NegNumber => {
                        return LexerError.InvalidIdentifierName;
                    },
                    .MinusSign => {
                        const minus = Token{ .type = .Minus, .value = null };
                        try tokens.append(allocator, minus);
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .Word;
                    },
                    .PlusSign => {
                        const plus = Token{ .type = .Plus, .value = null };
                        try tokens.append(allocator, plus);
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .Word;
                    },
                    .Comment, .String => unreachable,
                }
            },
            '0'...'9' => {
                switch (state) {
                    .TopLevel => {
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .Number;
                    },
                    .Word, .Number, .NegNumber, .PosNumber => {
                        word.addByte();
                    },
                    .MinusSign => {
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .NegNumber;
                    },
                    .PlusSign => {
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .PosNumber;
                    },
                    .Comment, .String => unreachable,
                }
            },
            '"' => {
                switch (state) {
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .MinusSign => {
                        const minus = Token{ .type = .Minus, .value = null };
                        try tokens.append(allocator, minus);
                    },
                    .PlusSign => {
                        const plus = Token{ .type = .Minus, .value = null };
                        try tokens.append(allocator, plus);
                    },
                    .TopLevel => {
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .String => {
                        const token = Token{ .type = .StringLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                        state = .TopLevel;
                    },
                    .Comment => unreachable,
                }
            },
            ' ' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        continue;
                    },
                    .Comment, .String => unreachable,
                }
                state = .TopLevel;
            },
            '\n' => {
                switch (state) {
                    .TopLevel => {
                        if (tokens.getLastOrNull()) |last| {
                            if (last.type == .NewLine) {
                                line += 1;
                                continue;
                            }
                        }
                    },
                    .Comment => {
                        line += 1;
                        state = .TopLevel;
                        continue;
                    },
                    .String => {
                        return LexerError.NotClosedString;
                    },
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                }
                const newline = Token{ .type = .NewLine, .value = null };
                try tokens.append(allocator, newline);
                line += 1;
                state = .TopLevel;
            },
            '-' => {
                switch (state) {
                    .TopLevel => {},
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                state = .MinusSign;
            },
            '+' => {
                switch (state) {
                    .TopLevel => {},
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                state = .PlusSign;
            },
            '*' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                const asteriks = Token{ .type = .Asteriks, .value = null };
                try tokens.append(allocator, asteriks);
                state = .TopLevel;
            },
            ':' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                const colon = Token{ .type = .Colon, .value = null };
                try tokens.append(allocator, colon);
                state = .TopLevel;
            },
            ',' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                const comma = Token{ .type = .Comma, .value = null };
                try tokens.append(allocator, comma);
                state = .TopLevel;
            },
            '[' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber, .PosNumber, .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                const obrac = Token{ .type = .OpenBracket, .value = null };
                try tokens.append(allocator, obrac);
                state = .TopLevel;
            },
            ']' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                const cbrac = Token{ .type = .CloseBracket, .value = null };
                try tokens.append(allocator, cbrac);
                state = .TopLevel;
            },
            '(' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber, .PosNumber, .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                const oparen = Token{ .type = .OpenParenthes, .value = null };
                try tokens.append(allocator, oparen);
                state = .TopLevel;
            },
            ')' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                const cparen = Token{ .type = .CloseParenthes, .value = null };
                try tokens.append(allocator, cparen);
                state = .TopLevel;
            },
            ';' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        return LexerError.InvalidCharacher;
                    },
                    .Comment, .String => unreachable,
                }
                state = .Comment;
            },
            else => {
                return LexerError.InvalidCharacher;
            },
        }
    }
    return tokens;
}

pub fn printTokens(tokens: std.ArrayList(Token)) void {
    for (tokens.items) |token| {
        if (token.type.isMnemonic()) {
            std.debug.print("\x1b[34m{t}\x1b[0m\n", .{token.type});
        } else if (token.type.isReg()) {
            std.debug.print("\x1b[35m{t}\x1b[0m\n", .{token.type});
        } else if (token.type == .NewLine) {
            std.debug.print("\n", .{});
        } else if (token.type == .StringLiteral) {
            std.debug.print("{t}  \x1b[36m{s}\x1b[0m\n", .{ token.type, token.value.? });
        } else if (token.type == .NumberLiteral) {
            std.debug.print("{t}  \x1b[31m{s}\x1b[0m\n", .{ token.type, token.value.? });
        } else if (token.type == .NegNumLiteral) {
            std.debug.print("{t}  \x1b[32m-{s}\x1b[0m\n", .{ token.type, token.value.? });
        } else if (token.type == .PosNumLiteral) {
            std.debug.print("{t}  \x1b[33m+{s}\x1b[0m\n", .{ token.type, token.value.? });
        } else {
            std.debug.print("{t}  {s}\n", .{ token.type, token.value orelse "" });
        }
    }
}
