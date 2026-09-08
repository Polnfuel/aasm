const std = @import("std");
const utils = @import("utils");
const Program = @import("Program");
const Lexer = @This();

const String = struct {
    slice: []u8,
    col: u16,

    pub fn new(ptr: [*]const u8, col: u16) String {
        return String{ .slice = ptr[0..0], .col = col };
    }

    pub fn addByte(self: *String) void {
        self.slice.len += 1;
    }
};

pub const TokenType = enum(u8) {
    // zig fmt: off
    //Keywords
    entry, data, code, import, bss,
    repeat,
    d8, d16, d32, d64,
    p8, p16, p32, p64,

    //Instruction mnemonics
    adc, add, @"and", call, cmp, dec, div, 
    idiv, imul, inc,
    ja,  jae, jb,   jbe,  jc,   je,   jg,  jge, 
    jl,  jle, jna,  jnae, jnb,  jnbe, jnc, 
    jne, jng, jnge, jnl,  jnle, jno,  jnp, jns, 
    jnz, jo,  jp,   jpe,  jpo,  js,   jz,  jmp,
    lea, mov, movdqa, movdqu, movzx, mul, neg, 
    not, @"or", pop, push, rcl, rcr, ret, rol, ror,
    sal, sar, sbb, shl, shr, sub, syscall, @"test", xor,

    //Registers
    //128-bit
    xmm0, xmm1,  xmm2,  xmm3,  xmm4,  xmm5,  xmm6,  xmm7,
    xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15,
    //64-bit
    rax, rbx, rcx, rdx, rdi, rsi, rsp, rbp, rip,
    r8,  r9,  r10, r11, r12, r13, r14, r15,
    //32-bit
    eax, ebx, ecx,  edx,  edi,  esi,  esp,  ebp,
    r8d, r9d, r10d, r11d, r12d, r13d, r14d, r15d,
    //16-bit
    ax,  bx,  cx,   dx,   di,   si,   sp,   bp,
    r8w, r9w, r10w, r11w, r12w, r13w, r14w, r15w,
    //8-bit
    ah,  al,  bh,   bl,   ch,   cl,   dh,   dl,   sil, dil, bpl, spl,
    r8b, r9b, r10b, r11b, r12b, r13b, r14b, r15b,

    //Literals
    Ident, HashIdent, DotIdent,
    StringLiteral,
    NumberLiteral,
    HexNumLiteral,
    BinNumLiteral,

    //Punctuation
    Colon, Comma,
    Plus, Minus, Asteriks,
    OpenBracket, CloseBracket,
    OpenParenthes, CloseParenthes,
    NewLine,
    Eof,

    // zig fmt: on

    pub fn isReg(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.xmm0);
        const upper = @intFromEnum(TokenType.r15b);
        const r = @intFromEnum(self);
        if (r >= lower and r <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isMnemonic(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.adc);
        const upper = @intFromEnum(TokenType.xor);
        const m = @intFromEnum(self);
        if (m >= lower and m <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isPointerSize(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.p8);
        const upper = @intFromEnum(TokenType.p64);
        const p = @intFromEnum(self);
        if (p >= lower and p <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isAdditionalReg(self: TokenType) bool {
        const r = @intFromEnum(self);
        const is = (r >= @intFromEnum(TokenType.r8) and r <= @intFromEnum(TokenType.r15)) or
            (r >= @intFromEnum(TokenType.r8d) and r <= @intFromEnum(TokenType.r15d)) or
            (r >= @intFromEnum(TokenType.r8w) and r <= @intFromEnum(TokenType.r15w)) or
            (r >= @intFromEnum(TokenType.r8b) and r <= @intFromEnum(TokenType.r15b)) or
            (r >= @intFromEnum(TokenType.xmm8) and r <= @intFromEnum(TokenType.xmm15));
        return is;
    }

    pub fn isByteRegAdditional(self: TokenType) bool {
        switch (self) {
            TokenType.spl, TokenType.bpl, TokenType.sil, TokenType.dil => {
                return true;
            },
            else => {
                return false;
            },
        }
    }

    pub fn isByteRegHigh(self: TokenType) bool {
        switch (self) {
            TokenType.ah, TokenType.dh, TokenType.ch, TokenType.bh => {
                return true;
            },
            else => {
                return false;
            },
        }
    }

    pub fn isDataDirective(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.d8);
        const upper = @intFromEnum(TokenType.d64);
        const d = @intFromEnum(self);
        if (d >= lower and d <= upper) {
            return true;
        } else {
            return false;
        }
    }

    pub fn isAccumulator(self: TokenType) bool {
        switch (self) {
            TokenType.al, TokenType.ax, TokenType.eax, TokenType.rax => {
                return true;
            },
            else => {
                return false;
            },
        }
    }

    pub fn isBlockDecl(self: TokenType) bool {
        switch (self) {
            TokenType.entry, TokenType.import, TokenType.data, TokenType.code, TokenType.bss => {
                return true;
            },
            else => {
                return false;
            },
        }
    }

    pub fn isAnyIdent(self: TokenType) bool {
        switch (self) {
            TokenType.Ident, TokenType.HashIdent, TokenType.DotIdent => {
                return true;
            },
            else => {
                return false;
            },
        }
    }

    pub fn isSign(self: TokenType) bool {
        if (self == TokenType.Minus or self == TokenType.Plus) {
            return true;
        }
        return false;
    }
};

pub const Token = struct {
    type: TokenType,
    val_ind: u16,
    line: u16,
    col: u16,
};

pub const LexerError = error{LexerAnalyzisFailed} || std.mem.Allocator.Error;

const LexerState = enum {
    TopLevel,
    Word,
    Number,

    PlusSign,
    MinusSign,
};

const keywords: std.StaticStringMap(TokenType) = .initComptime(&.{
    .{ "@entry", TokenType.entry },
    .{ "@data", TokenType.data },
    .{ "@code", TokenType.code },
    .{ "@import", TokenType.import },
    .{ "@bss", TokenType.bss },
    .{ "repeat", TokenType.repeat },
    .{ "d8", TokenType.d8 },
    .{ "d16", TokenType.d16 },
    .{ "d32", TokenType.d32 },
    .{ "d64", TokenType.d64 },
    .{ "p8", TokenType.p8 },
    .{ "p16", TokenType.p16 },
    .{ "p32", TokenType.p32 },
    .{ "p64", TokenType.p64 },
    .{ "adc", TokenType.adc },
    .{ "add", TokenType.add },
    .{ "and", TokenType.@"and" },
    .{ "call", TokenType.call },
    .{ "cmp", TokenType.cmp },
    .{ "dec", TokenType.dec },
    .{ "div", TokenType.div },
    .{ "idiv", TokenType.idiv },
    .{ "imul", TokenType.imul },
    .{ "inc", TokenType.inc },
    .{ "jae", TokenType.jae },
    .{ "ja", TokenType.ja },
    .{ "jbe", TokenType.jbe },
    .{ "jb", TokenType.jb },
    .{ "jc", TokenType.jc },
    .{ "je", TokenType.je },
    .{ "jge", TokenType.jge },
    .{ "jg", TokenType.jg },
    .{ "jle", TokenType.jle },
    .{ "jl", TokenType.jl },
    .{ "jmp", TokenType.jmp },
    .{ "jnae", TokenType.jnae },
    .{ "jna", TokenType.jna },
    .{ "jnbe", TokenType.jnbe },
    .{ "jnb", TokenType.jnb },
    .{ "jnc", TokenType.jnc },
    .{ "jne", TokenType.jne },
    .{ "jnge", TokenType.jnge },
    .{ "jng", TokenType.jng },
    .{ "jnle", TokenType.jnle },
    .{ "jnl", TokenType.jnl },
    .{ "jno", TokenType.jno },
    .{ "jnp", TokenType.jnp },
    .{ "jns", TokenType.jns },
    .{ "jnz", TokenType.jnz },
    .{ "jo", TokenType.jo },
    .{ "jpe", TokenType.jpe },
    .{ "jpo", TokenType.jpo },
    .{ "jp", TokenType.jp },
    .{ "js", TokenType.js },
    .{ "jz", TokenType.jz },
    .{ "lea", TokenType.lea },
    .{ "mov", TokenType.mov },
    .{ "movdqa", TokenType.movdqa },
    .{ "movdqu", TokenType.movdqu },
    .{ "movzx", TokenType.movzx },
    .{ "mul", TokenType.mul },
    .{ "neg", TokenType.neg },
    .{ "not", TokenType.not },
    .{ "or", TokenType.@"or" },
    .{ "pop", TokenType.pop },
    .{ "push", TokenType.push },
    .{ "rcl", TokenType.rcl },
    .{ "rcr", TokenType.rcr },
    .{ "ret", TokenType.ret },
    .{ "rol", TokenType.rol },
    .{ "ror", TokenType.ror },
    .{ "sal", TokenType.sal },
    .{ "sar", TokenType.sar },
    .{ "sbb", TokenType.sbb },
    .{ "shl", TokenType.shl },
    .{ "shr", TokenType.shr },
    .{ "sub", TokenType.sub },
    .{ "syscall", TokenType.syscall },
    .{ "test", TokenType.@"test" },
    .{ "xor", TokenType.xor },
    .{ "xmm0", TokenType.xmm0 },
    .{ "xmm1", TokenType.xmm1 },
    .{ "xmm2", TokenType.xmm2 },
    .{ "xmm3", TokenType.xmm3 },
    .{ "xmm4", TokenType.xmm4 },
    .{ "xmm5", TokenType.xmm5 },
    .{ "xmm6", TokenType.xmm6 },
    .{ "xmm7", TokenType.xmm7 },
    .{ "xmm8", TokenType.xmm8 },
    .{ "xmm9", TokenType.xmm9 },
    .{ "xmm10", TokenType.xmm10 },
    .{ "xmm11", TokenType.xmm11 },
    .{ "xmm12", TokenType.xmm12 },
    .{ "xmm13", TokenType.xmm13 },
    .{ "xmm14", TokenType.xmm14 },
    .{ "xmm15", TokenType.xmm15 },
    .{ "rax", TokenType.rax },
    .{ "rbx", TokenType.rbx },
    .{ "rcx", TokenType.rcx },
    .{ "rdx", TokenType.rdx },
    .{ "rdi", TokenType.rdi },
    .{ "rsi", TokenType.rsi },
    .{ "rsp", TokenType.rsp },
    .{ "rbp", TokenType.rbp },
    .{ "rip", TokenType.rip },
    .{ "r8", TokenType.r8 },
    .{ "r9", TokenType.r9 },
    .{ "r10", TokenType.r10 },
    .{ "r11", TokenType.r11 },
    .{ "r12", TokenType.r12 },
    .{ "r13", TokenType.r13 },
    .{ "r14", TokenType.r14 },
    .{ "r15", TokenType.r15 },
    .{ "eax", TokenType.eax },
    .{ "ebx", TokenType.ebx },
    .{ "ecx", TokenType.ecx },
    .{ "edx", TokenType.edx },
    .{ "edi", TokenType.edi },
    .{ "esi", TokenType.esi },
    .{ "esp", TokenType.esp },
    .{ "ebp", TokenType.ebp },
    .{ "r8d", TokenType.r8d },
    .{ "r9d", TokenType.r9d },
    .{ "r10d", TokenType.r10d },
    .{ "r11d", TokenType.r11d },
    .{ "r12d", TokenType.r12d },
    .{ "r13d", TokenType.r13d },
    .{ "r14d", TokenType.r14d },
    .{ "r15d", TokenType.r15d },
    .{ "ax", TokenType.ax },
    .{ "bx", TokenType.bx },
    .{ "cx", TokenType.cx },
    .{ "dx", TokenType.dx },
    .{ "di", TokenType.di },
    .{ "si", TokenType.si },
    .{ "sp", TokenType.sp },
    .{ "bp", TokenType.bp },
    .{ "r8w", TokenType.r8w },
    .{ "r9w", TokenType.r9w },
    .{ "r10w", TokenType.r10w },
    .{ "r11w", TokenType.r11w },
    .{ "r12w", TokenType.r12w },
    .{ "r13w", TokenType.r13w },
    .{ "r14w", TokenType.r14w },
    .{ "r15w", TokenType.r15w },
    .{ "ah", TokenType.ah },
    .{ "al", TokenType.al },
    .{ "bh", TokenType.bh },
    .{ "bl", TokenType.bl },
    .{ "ch", TokenType.ch },
    .{ "cl", TokenType.cl },
    .{ "dh", TokenType.dh },
    .{ "dl", TokenType.dl },
    .{ "sil", TokenType.sil },
    .{ "dil", TokenType.dil },
    .{ "bpl", TokenType.bpl },
    .{ "spl", TokenType.spl },
    .{ "r8b", TokenType.r8b },
    .{ "r9b", TokenType.r9b },
    .{ "r10b", TokenType.r10b },
    .{ "r11b", TokenType.r11b },
    .{ "r12b", TokenType.r12b },
    .{ "r13b", TokenType.r13b },
    .{ "r14b", TokenType.r14b },
    .{ "r15b", TokenType.r15b },
});

program: *Program,

pub fn init(program: *Program) Lexer {
    return Lexer{ .program = program };
}

fn analyzeWord(self: *Lexer, word: String, line: u16) LexerError!Token {
    var token_type: TokenType = undefined;
    if (keywords.get(word.slice)) |keyword| {
        token_type = keyword;
    } else {
        if (word.slice[0] == '#') {
            if (word.slice.len > 1 and byteIsLetter(word.slice[1])) {
                token_type = .HashIdent;
            } else {
                utils.printSrcLineColError("expected label name", self.program, line, word.col + 1);
                return LexerError.LexerAnalyzisFailed;
            }
        } else if (word.slice[0] == '.') {
            if (word.slice.len > 1 and byteIsLetter(word.slice[1])) {
                token_type = .DotIdent;
            } else {
                utils.printSrcLineColError("expected label name", self.program, line, word.col + 1);
                return LexerError.LexerAnalyzisFailed;
            }
        } else if (word.slice[0] == '@') {
            utils.printSrcLineColError("unknown keyword name", self.program, line, word.col + 1);
            return LexerError.LexerAnalyzisFailed;
        } else {
            token_type = .Ident;
        }
    }

    return Token{ .type = token_type, .val_ind = switch (token_type) {
        .Ident, .DotIdent => try utils.putString(word.slice),
        .HashIdent => try utils.putString(word.slice[1..]),
        else => 0,
    }, .line = line, .col = word.col };
}

fn startNewWord(self: *Lexer, word: *String, i: usize, col: u16) void {
    word.* = String.new(self.program.content[i..i].ptr, col);
    word.addByte();
}

fn emitWord(self: *Lexer, word: String, line: u16) LexerError!void {
    const token = try self.analyzeWord(word, line);
    try self.program.tokens.append(utils.alloc, token);
}

fn emitNumber(self: *Lexer, word: String, num_type: TokenType, line: u16) LexerError!void {
    if (num_type != .NumberLiteral and word.slice.len < 3) {
        utils.printSrcLineColError("expected digit", self.program, line, word.col + 2);
        return LexerError.LexerAnalyzisFailed;
    }
    const token = Token{ .type = num_type, .val_ind = try utils.putString(word.slice), .line = line, .col = word.col };
    try self.program.tokens.append(utils.alloc, token);
}

fn emitSeparator(self: *Lexer, byte: u8, line: u16, col: u16) LexerError!void {
    const token = Token{ .type = switch (byte) {
        '*' => .Asteriks,
        ':' => .Colon,
        ',' => .Comma,
        '[' => .OpenBracket,
        ']' => .CloseBracket,
        '(' => .OpenParenthes,
        ')' => .CloseParenthes,
        else => unreachable,
    }, .val_ind = 0, .line = line, .col = col };
    try self.program.tokens.append(utils.alloc, token);
}

fn emitSign(self: *Lexer, state: LexerState, line: u16, col: u16) LexerError!void {
    const token = Token{ .type = if (state == .MinusSign) .Minus else .Plus, .val_ind = 0, .line = line, .col = col };
    try self.program.tokens.append(utils.alloc, token);
}

fn byteIsLetter(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn byteIsHex(byte: u8) bool {
    return switch (byte) {
        'A'...'F', 'a'...'f' => true,
        else => false,
    };
}

pub fn tokenizeContent(self: *Lexer) LexerError!void {
    const tokens = &self.program.tokens;
    const program = self.program;
    const content = self.program.content;

    var line: u16 = 1;
    var col: u16 = 0;

    var state: LexerState = .TopLevel;
    var word: String = String.new(content.ptr, col);

    var string = false;
    var comment = false;
    var two_signs = false;
    var start_zero = false;
    var num_type: TokenType = .NumberLiteral;
    var sign_col: u16 = 0;

    for (content, 0..) |byte, i| {
        col += 1;
        if (state != .MinusSign and state != .PlusSign and two_signs) {
            two_signs = false;
        }
        if (byte != '\n') {
            if (byte != '"' and string) {
                word.addByte();
                continue;
            } else if (comment) {
                continue;
            }
        }
        switch (byte) {
            'A'...'Z', 'a'...'z', '_' => {
                switch (state) {
                    .TopLevel => {
                        self.startNewWord(&word, i, col);
                        state = .Word;
                    },
                    .Word => word.addByte(),
                    .Number => {
                        if (start_zero) {
                            start_zero = false;
                            if (byte == 'x' or byte == 'b') {
                                num_type = if (byte == 'x') .HexNumLiteral else .BinNumLiteral;
                                word.addByte();
                                continue;
                            }
                        } else if (num_type == .HexNumLiteral and byteIsHex(byte)) {
                            word.addByte();
                            continue;
                        }
                        utils.printSrcLineColError("invalid character after digit", program, line, col);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .PlusSign, .MinusSign => {
                        try self.emitSign(state, line, sign_col);
                        self.startNewWord(&word, i, col);
                        state = .Word;
                    },
                }
            },
            '0'...'9' => {
                switch (state) {
                    .TopLevel => {
                        self.startNewWord(&word, i, col);
                        start_zero = byte == '0';
                        num_type = .NumberLiteral;
                    },
                    .Word, .Number => {
                        if (state == .Number and num_type == .BinNumLiteral and (byte != '0' and byte != '1')) {
                            utils.printSrcLineColError("invalid digit in binary number", program, line, col);
                            return LexerError.LexerAnalyzisFailed;
                        }
                        word.addByte();
                        continue;
                    },
                    .PlusSign, .MinusSign => {
                        try self.emitSign(state, line, sign_col);
                        self.startNewWord(&word, i, col);
                        start_zero = byte == '0';
                        num_type = .NumberLiteral;
                    },
                }
                state = .Number;
            },
            '"' => {
                if (string) {
                    const token = Token{ .type = .StringLiteral, .val_ind = try utils.putString(word.slice), .line = line, .col = word.col };
                    try tokens.append(utils.alloc, token);
                    state = .TopLevel;
                    string = false;
                    continue;
                }
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                    .PlusSign, .MinusSign => try self.emitSign(state, line, sign_col),
                }
                word = String.new(content[i..i].ptr + 1, col + 1);
                string = true;
            },
            ' ' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                    .PlusSign, .MinusSign => continue,
                }
                state = .TopLevel;
            },
            '\n' => {
                if (comment) {
                    line += 1;
                    col = 0;
                    state = .TopLevel;
                    comment = false;
                    continue;
                } else if (string) {
                    utils.printSrcLineColError("not closed string literal", program, line, col);
                    return LexerError.LexerAnalyzisFailed;
                }
                switch (state) {
                    .TopLevel => {
                        if (tokens.getLastOrNull()) |last| {
                            if (last.type == .NewLine) {
                                line += 1;
                                col = 0;
                                continue;
                            }
                        }
                    },
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                    .PlusSign, .MinusSign => {
                        utils.printSrcLineColError("unexpected end of line after sign", program, line, col);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                const newline = Token{ .type = .NewLine, .val_ind = 0, .line = line, .col = col };
                try tokens.append(utils.alloc, newline);
                line += 1;
                col = 0;
                state = .TopLevel;
                comment = false;
            },
            '+', '-' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                    .PlusSign, .MinusSign => {
                        if (two_signs) {
                            utils.printSrcLineColError("more than 2 math signs is not allowed", program, line, col);
                            return LexerError.LexerAnalyzisFailed;
                        }
                        try self.emitSign(state, line, sign_col);
                        two_signs = true;
                    },
                }
                sign_col = col;
                state = if (byte == '+') .PlusSign else .MinusSign;
            },
            '*', ':', ',', '[', ']', '(', ')' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                    .PlusSign, .MinusSign => {
                        utils.printSrcLineColError("unexpected character after sign", program, line, col);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                try self.emitSeparator(byte, line, col);
                state = .TopLevel;
            },
            ';' => {
                switch (state) {
                    .TopLevel => {
                        if (tokens.getLastOrNull()) |last| {
                            if (last.type != .NewLine) {
                                const newline = Token{ .type = .NewLine, .val_ind = 0, .line = line, .col = col };
                                try tokens.append(utils.alloc, newline);
                            }
                        }
                    },
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                    .PlusSign, .MinusSign => {
                        utils.printSrcLineColError("unexpected character after sign", program, line, col);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                comment = true;
            },
            '@', '#', '.' => {
                switch (state) {
                    .TopLevel => {
                        self.startNewWord(&word, i, col);
                        state = .Word;
                    },
                    .Word, .Number, .PlusSign, .MinusSign => {
                        utils.printSrcLineColError("unexpected character after sign", program, line, col);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
            },
            else => {
                utils.printSrcLineColError("unknown character", program, line, col);
                return LexerError.LexerAnalyzisFailed;
            },
        }
    }

    try program.tokens.append(utils.alloc, .{ .type = .Eof, .val_ind = 0, .line = 0, .col = 0 });
}

pub fn printTokens(program: *Program) void {
    for (program.tokens.items) |token| {
        std.debug.print("{any}\n", .{token});
    }
    for (program.tokens.items) |token| {
        if (token.type.isMnemonic()) {
            std.debug.print("\x1b[34m{t}\x1b[0m ", .{token.type});
        } else if (token.type.isReg()) {
            std.debug.print("\x1b[35m{t}\x1b[0m ", .{token.type});
        } else if (token.type == .NewLine) {
            std.debug.print("\\n\n", .{});
        } else if (token.type == .StringLiteral) {
            std.debug.print("\x1b[36m{s}\x1b[0m ", .{utils.stringValue(token.val_ind)});
        } else if (token.type == .NumberLiteral) {
            std.debug.print("\x1b[31m{s}\x1b[0m ", .{utils.stringValue(token.val_ind)});
        } else if (token.type == .HexNumLiteral) {
            std.debug.print("\x1b[32m{s}\x1b[0m ", .{utils.stringValue(token.val_ind)});
        } else if (token.type == .BinNumLiteral) {
            std.debug.print("\x1b[33m{s}\x1b[0m ", .{utils.stringValue(token.val_ind)});
        } else if (token.type == .OpenBracket) {
            std.debug.print("[ ", .{});
        } else if (token.type == .CloseBracket) {
            std.debug.print("] ", .{});
        } else if (token.type == .OpenParenthes) {
            std.debug.print("( ", .{});
        } else if (token.type == .CloseParenthes) {
            std.debug.print(") ", .{});
        } else if (token.type == .Plus) {
            std.debug.print("+ ", .{});
        } else if (token.type == .Minus) {
            std.debug.print("- ", .{});
        } else if (token.type == .Asteriks) {
            std.debug.print("* ", .{});
        } else if (token.type == .Comma) {
            std.debug.print(", ", .{});
        } else if (token.type == .Colon) {
            std.debug.print(": ", .{});
        } else if (token.type == .Ident or token.type == .HashIdent or token.type == .DotIdent) {
            std.debug.print("\x1b[37m{s}\x1b[0m ", .{utils.stringValue(token.val_ind)});
        } else {
            std.debug.print("{t} ", .{token.type});
        }
    }
    std.debug.print("\n", .{});
}
