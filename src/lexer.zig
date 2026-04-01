const std = @import("std");
const Program = @import("program").Program;
const stdbuffers = @import("stdbuffers");

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
    Export,
    Import,
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
    line: u16,
    type: TokenType,
    value: []u8,
};

fn analyzeWord(word: String, line: u16) Token {
    var token_type: TokenType = undefined;
    // Keywords
    if (word.is("d8")) {
        token_type = .D8;
    } else if (word.is("d16")) {
        token_type = .D16;
    } else if (word.is("d32")) {
        token_type = .D32;
    } else if (word.is("d64")) {
        token_type = .D64;
    } else if (word.is("p8")) {
        token_type = .P8;
    } else if (word.is("p16")) {
        token_type = .P16;
    } else if (word.is("p32")) {
        token_type = .P32;
    } else if (word.is("p64")) {
        token_type = .P64;
    } else if (word.is("data")) {
        token_type = .Data;
    } else if (word.is("code")) {
        token_type = .Code;
    } else if (word.is("entry")) {
        token_type = .Entry;
    } else if (word.is("section")) {
        token_type = .Section;
    } else if (word.is("repeat")) {
        token_type = .Repeat;
    } else if (word.is("export")) {
        token_type = .Export;
    } else if (word.is("import")) {
        token_type = .Import;
    }
    // Instructions
    else if (word.is("mov")) {
        token_type = .Mov;
    } else if (word.is("cmp")) {
        token_type = .Cmp;
    } else if (word.is("je")) {
        token_type = .Je;
    } else if (word.is("jne")) {
        token_type = .Jne;
    } else if (word.is("ja")) {
        token_type = .Ja;
    } else if (word.is("jz")) {
        token_type = .Jz;
    } else if (word.is("call")) {
        token_type = .Call;
    } else if (word.is("ret")) {
        token_type = .Ret;
    } else if (word.is("syscall")) {
        token_type = .Syscall;
    } else if (word.is("jmp")) {
        token_type = .Jmp;
    } else if (word.is("xor")) {
        token_type = .Xor;
    } else if (word.is("add")) {
        token_type = .Add;
    } else if (word.is("sub")) {
        token_type = .Sub;
    } else if (word.is("imul")) {
        token_type = .Imul;
    } else if (word.is("div")) {
        token_type = .Div;
    } else if (word.is("inc")) {
        token_type = .Inc;
    } else if (word.is("dec")) {
        token_type = .Dec;
    } else if (word.is("test")) {
        token_type = .Test;
    } else if (word.is("lea")) {
        token_type = .Lea;
    } else if (word.is("push")) {
        token_type = .Push;
    } else if (word.is("pop")) {
        token_type = .Pop;
    }
    // Registers
    else if (word.is("rax")) {
        token_type = .Rax;
    } else if (word.is("rbx")) {
        token_type = .Rbx;
    } else if (word.is("rcx")) {
        token_type = .Rcx;
    } else if (word.is("rdx")) {
        token_type = .Rdx;
    } else if (word.is("rsi")) {
        token_type = .Rsi;
    } else if (word.is("rdi")) {
        token_type = .Rdi;
    } else if (word.is("rsp")) {
        token_type = .Rsp;
    } else if (word.is("rbp")) {
        token_type = .Rbp;
    } else if (word.is("rip")) {
        token_type = .Rip;
    } else if (word.is("r8")) {
        token_type = .R8;
    } else if (word.is("r9")) {
        token_type = .R9;
    } else if (word.is("r10")) {
        token_type = .R10;
    } else if (word.is("r11")) {
        token_type = .R11;
    } else if (word.is("r12")) {
        token_type = .R12;
    } else if (word.is("r13")) {
        token_type = .R13;
    } else if (word.is("r14")) {
        token_type = .R14;
    } else if (word.is("r15")) {
        token_type = .R15;
    } else if (word.is("eax")) {
        token_type = .Eax;
    } else if (word.is("ebx")) {
        token_type = .Ebx;
    } else if (word.is("ecx")) {
        token_type = .Ecx;
    } else if (word.is("edx")) {
        token_type = .Edx;
    } else if (word.is("edi")) {
        token_type = .Edi;
    } else if (word.is("esi")) {
        token_type = .Esi;
    } else if (word.is("esp")) {
        token_type = .Esp;
    } else if (word.is("ebp")) {
        token_type = .Ebp;
    } else if (word.is("eip")) {
        token_type = .Eip;
    } else if (word.is("r8d")) {
        token_type = .R8d;
    } else if (word.is("r9d")) {
        token_type = .R9d;
    } else if (word.is("r10d")) {
        token_type = .R10d;
    } else if (word.is("r11d")) {
        token_type = .R11d;
    } else if (word.is("r12d")) {
        token_type = .R12d;
    } else if (word.is("r13d")) {
        token_type = .R13d;
    } else if (word.is("r14d")) {
        token_type = .R14d;
    } else if (word.is("r15d")) {
        token_type = .R15d;
    } else if (word.is("ax")) {
        token_type = .Ax;
    } else if (word.is("bx")) {
        token_type = .Bx;
    } else if (word.is("cx")) {
        token_type = .Cx;
    } else if (word.is("dx")) {
        token_type = .Dx;
    } else if (word.is("di")) {
        token_type = .Di;
    } else if (word.is("si")) {
        token_type = .Si;
    } else if (word.is("sp")) {
        token_type = .Sp;
    } else if (word.is("bp")) {
        token_type = .Bp;
    } else if (word.is("r8w")) {
        token_type = .R8w;
    } else if (word.is("r9w")) {
        token_type = .R9w;
    } else if (word.is("r10w")) {
        token_type = .R10w;
    } else if (word.is("r11w")) {
        token_type = .R11w;
    } else if (word.is("r12w")) {
        token_type = .R12w;
    } else if (word.is("r13w")) {
        token_type = .R13w;
    } else if (word.is("r14w")) {
        token_type = .R14w;
    } else if (word.is("r15w")) {
        token_type = .R15w;
    } else if (word.is("ah")) {
        token_type = .Ah;
    } else if (word.is("al")) {
        token_type = .Al;
    } else if (word.is("bh")) {
        token_type = .Bh;
    } else if (word.is("bl")) {
        token_type = .Bl;
    } else if (word.is("ch")) {
        token_type = .Ch;
    } else if (word.is("cl")) {
        token_type = .Cl;
    } else if (word.is("dh")) {
        token_type = .Dh;
    } else if (word.is("dl")) {
        token_type = .Dl;
    } else if (word.is("sil")) {
        token_type = .Sil;
    } else if (word.is("dil")) {
        token_type = .Dil;
    } else if (word.is("bpl")) {
        token_type = .Bpl;
    } else if (word.is("spl")) {
        token_type = .Spl;
    } else if (word.is("r8b")) {
        token_type = .R8b;
    } else if (word.is("r9b")) {
        token_type = .R9b;
    } else if (word.is("r10b")) {
        token_type = .R10b;
    } else if (word.is("r11b")) {
        token_type = .R11b;
    } else if (word.is("r12b")) {
        token_type = .R12b;
    } else if (word.is("r13b")) {
        token_type = .R13b;
    } else if (word.is("r14b")) {
        token_type = .R14b;
    } else if (word.is("r15b")) {
        token_type = .R15b;
    } else {
        token_type = .Ident;
    }

    return Token{ .type = token_type, .value = switch (token_type) {
        .Ident => word.slice,
        else => word.slice[0..0],
    }, .line = line };
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

pub const LexerError = error{LexerAnalyzisFailed} || std.mem.Allocator.Error;

pub fn tokenizeContent(allocator: std.mem.Allocator, content: []const u8, file_name: []const u8) LexerError!std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;

    var line: u16 = 1;
    errdefer tokens.deinit(allocator);

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
                        stdbuffers.printSourceError(file_name, "invalid character after digit", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .MinusSign => {
                        const minus = Token{ .type = .Minus, .value = content[0..0], .line = line };
                        try tokens.append(allocator, minus);
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .Word;
                    },
                    .PlusSign => {
                        const plus = Token{ .type = .Plus, .value = content[0..0], .line = line };
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
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .MinusSign => {
                        const minus = Token{ .type = .Minus, .value = content[0..0], .line = line };
                        try tokens.append(allocator, minus);
                    },
                    .PlusSign => {
                        const plus = Token{ .type = .Minus, .value = content[0..0], .line = line };
                        try tokens.append(allocator, plus);
                    },
                    .TopLevel => {
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .String => {
                        const token = Token{ .type = .StringLiteral, .value = word.slice, .line = line };
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
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
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
                        stdbuffers.printSourceError(file_name, "not closed string literal", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "unexpected end of line", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                const newline = Token{ .type = .NewLine, .value = content[0..0], .line = line };
                try tokens.append(allocator, newline);
                line += 1;
                state = .TopLevel;
            },
            '-' => {
                switch (state) {
                    .TopLevel => {},
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or -", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                state = .MinusSign;
            },
            '+' => {
                switch (state) {
                    .TopLevel => {},
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or -", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                state = .PlusSign;
            },
            '*' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or - and *", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const asteriks = Token{ .type = .Asteriks, .value = content[0..0], .line = line };
                try tokens.append(allocator, asteriks);
                state = .TopLevel;
            },
            ':' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or - and :", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const colon = Token{ .type = .Colon, .value = content[0..0], .line = line };
                try tokens.append(allocator, colon);
                state = .TopLevel;
            },
            ',' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or - and ,", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const comma = Token{ .type = .Comma, .value = content[0..0], .line = line };
                try tokens.append(allocator, comma);
                state = .TopLevel;
            },
            '[' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber, .PosNumber, .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "unexpected [", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const obrac = Token{ .type = .OpenBracket, .value = content[0..0], .line = line };
                try tokens.append(allocator, obrac);
                state = .TopLevel;
            },
            ']' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or - and ]", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const cbrac = Token{ .type = .CloseBracket, .value = content[0..0], .line = line };
                try tokens.append(allocator, cbrac);
                state = .TopLevel;
            },
            '(' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber, .PosNumber, .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "unexpected (", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const oparen = Token{ .type = .OpenParenthes, .value = content[0..0], .line = line };
                try tokens.append(allocator, oparen);
                state = .TopLevel;
            },
            ')' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or - and )", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const cparen = Token{ .type = .CloseParenthes, .value = content[0..0], .line = line };
                try tokens.append(allocator, cparen);
                state = .TopLevel;
            },
            ';' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = analyzeWord(word, line);
                        try tokens.append(allocator, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .NegNumber => {
                        const token = Token{ .type = .NegNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .PosNumber => {
                        const token = Token{ .type = .PosNumLiteral, .value = word.slice, .line = line };
                        try tokens.append(allocator, token);
                    },
                    .MinusSign, .PlusSign => {
                        stdbuffers.printSourceError(file_name, "invalid sequence of + or - and ;", content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                state = .Comment;
            },
            else => {
                stdbuffers.printSourceError(file_name, "unknown character", content, line);
                return LexerError.LexerAnalyzisFailed;
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
            std.debug.print("{t}  \x1b[36m{s}\x1b[0m\n", .{ token.type, token.value });
        } else if (token.type == .NumberLiteral) {
            std.debug.print("{t}  \x1b[31m{s}\x1b[0m\n", .{ token.type, token.value });
        } else if (token.type == .NegNumLiteral) {
            std.debug.print("{t}  \x1b[32m-{s}\x1b[0m\n", .{ token.type, token.value });
        } else if (token.type == .PosNumLiteral) {
            std.debug.print("{t}  \x1b[33m+{s}\x1b[0m\n", .{ token.type, token.value });
        } else {
            std.debug.print("{t}  {s}\n", .{ token.type, token.value });
        }
    }
}
