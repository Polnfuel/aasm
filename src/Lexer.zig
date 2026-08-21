const std = @import("std");
const utils = @import("utils");
const Program = @import("Program");
const Lexer = @This();

const String = struct {
    slice: []u8,

    pub fn new(ptr: [*]const u8) String {
        return String{ .slice = ptr[0..0] };
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
    adc, add, @"and", cmp, @"or", sbb, sub, xor,
    dec, div, idiv, inc, mul, neg, not,
    mov, movzx, lea, call, ret, syscall, 
    ja,  jae, jb,   jbe, jc,   je,  jg,  jge, jl,  jle, jna, jnae, jnb, jnbe, jnc, 
    jne, jng, jnge, jnl, jnle, jno, jnp, jns, jnz, jo,  jp,  jpe,  jpo, js,   jz, jmp,
    sal, sar, shl, shr,
    imul, @"test",
    push, pop,

    //Registers
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

    // zig fmt: on

    pub fn isReg(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.rax);
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
        const upper = @intFromEnum(TokenType.pop);
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
            (r >= @intFromEnum(TokenType.r8b) and r <= @intFromEnum(TokenType.r15b));
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
    .{ "cmp", TokenType.cmp },
    .{ "or", TokenType.@"or" },
    .{ "sbb", TokenType.sbb },
    .{ "sub", TokenType.sub },
    .{ "xor", TokenType.xor },
    .{ "dec", TokenType.dec },
    .{ "div", TokenType.div },
    .{ "idiv", TokenType.idiv },
    .{ "inc", TokenType.inc },
    .{ "mul", TokenType.mul },
    .{ "neg", TokenType.neg },
    .{ "not", TokenType.not },
    .{ "mov", TokenType.mov },
    .{ "movzx", TokenType.movzx },
    .{ "lea", TokenType.lea },
    .{ "call", TokenType.call },
    .{ "ret", TokenType.ret },
    .{ "syscall", TokenType.syscall },
    .{ "ja", TokenType.ja },
    .{ "jae", TokenType.jae },
    .{ "jb", TokenType.jb },
    .{ "jbe", TokenType.jbe },
    .{ "jc", TokenType.jc },
    .{ "je", TokenType.je },
    .{ "jg", TokenType.jg },
    .{ "jge", TokenType.jge },
    .{ "jl", TokenType.jl },
    .{ "jle", TokenType.jle },
    .{ "jna", TokenType.jna },
    .{ "jnae", TokenType.jnae },
    .{ "jnb", TokenType.jnb },
    .{ "jnbe", TokenType.jnbe },
    .{ "jnc", TokenType.jnc },
    .{ "jne", TokenType.jne },
    .{ "jng", TokenType.jng },
    .{ "jnge", TokenType.jnge },
    .{ "jnl", TokenType.jnl },
    .{ "jnle", TokenType.jnle },
    .{ "jno", TokenType.jno },
    .{ "jnp", TokenType.jnp },
    .{ "jns", TokenType.jns },
    .{ "jnz", TokenType.jnz },
    .{ "jo", TokenType.jo },
    .{ "jp", TokenType.jp },
    .{ "jpe", TokenType.jpe },
    .{ "jpo", TokenType.jpo },
    .{ "js", TokenType.js },
    .{ "jz", TokenType.jz },
    .{ "jmp", TokenType.jmp },
    .{ "sal", TokenType.sal },
    .{ "sar", TokenType.sar },
    .{ "shl", TokenType.shl },
    .{ "shr", TokenType.shr },
    .{ "imul", TokenType.imul },
    .{ "test", TokenType.@"test" },
    .{ "push", TokenType.push },
    .{ "pop", TokenType.pop },
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

fn addValue(self: *Lexer, value: []const u8) LexerError!u16 {
    try self.program.token_values.append(utils.alloc, value);
    return @truncate(self.program.token_values.items.len - 1);
}

fn analyzeWord(self: *Lexer, word: String, line: u16) LexerError!Token {
    var token_type: TokenType = undefined;
    if (keywords.get(word.slice)) |keyword| {
        token_type = keyword;
    } else {
        if (word.slice[0] == '#') {
            if (word.slice.len > 1) {
                token_type = .HashIdent;
            } else {
                utils.printSrcLineError("expected label name after #", self.program.file_name, self.program.content, line);
                return LexerError.LexerAnalyzisFailed;
            }
        } else if (word.slice[0] == '.') {
            if (word.slice.len > 1) {
                token_type = .DotIdent;
            } else {
                utils.printSrcLineError("expected label name after .", self.program.file_name, self.program.content, line);
                return LexerError.LexerAnalyzisFailed;
            }
        } else if (word.slice[0] == '@') {
            utils.printSrcLineError("unsupported keyword name after @", self.program.file_name, self.program.content, line);
            return LexerError.LexerAnalyzisFailed;
        } else {
            token_type = .Ident;
        }
    }

    return Token{ .type = token_type, .val_ind = switch (token_type) {
        .Ident, .DotIdent => try self.addValue(word.slice),
        .HashIdent => try self.addValue(word.slice[1..]),
        else => 0,
    }, .line = line };
}

fn startNewWord(self: *Lexer, word: *String, i: usize) void {
    word.* = String.new(self.program.content[i..i].ptr);
    word.addByte();
}

fn emitWord(self: *Lexer, word: String, line: u16) LexerError!void {
    const token = try self.analyzeWord(word, line);
    try self.program.tokens.append(utils.alloc, token);
}

fn emitNumber(self: *Lexer, word: String, line: u16, num_type: TokenType) LexerError!void {
    if (num_type != .NumberLiteral and word.slice.len < 3) {
        utils.printSrcLineErrorFmt("uxpected digits after {s}", .{word.slice}, self.program.file_name, self.program.content, line);
        return LexerError.LexerAnalyzisFailed;
    }
    const token = Token{ .type = num_type, .val_ind = try self.addValue(word.slice), .line = line };
    try self.program.tokens.append(utils.alloc, token);
}

fn emitSeparator(self: *Lexer, byte: u8, line: u16) LexerError!void {
    const token = Token{ .type = switch (byte) {
        '*' => .Asteriks,
        ':' => .Colon,
        ',' => .Comma,
        '[' => .OpenBracket,
        ']' => .CloseBracket,
        '(' => .OpenParenthes,
        ')' => .CloseParenthes,
        else => unreachable,
    }, .val_ind = 0, .line = line };
    try self.program.tokens.append(utils.alloc, token);
}

fn emitSign(self: *Lexer, state: LexerState, line: u16) LexerError!void {
    const token = Token{ .type = if (state == .MinusSign) .Minus else .Plus, .val_ind = 0, .line = line };
    try self.program.tokens.append(utils.alloc, token);
}

fn byteIsHex(byte: u8) bool {
    return switch (byte) {
        'A'...'F', 'a'...'f' => true,
        else => false,
    };
}

pub fn tokenizeContent(self: *Lexer) LexerError!void {
    const tokens = &self.program.tokens;
    const content = self.program.content;
    const file_name = self.program.file_name;

    var line: u16 = 1;

    var state: LexerState = .TopLevel;
    var word: String = String.new(content.ptr);

    var string = false;
    var comment = false;
    var two_signs = false;
    var start_zero = false;
    var num_type: TokenType = .NumberLiteral;

    for (content, 0..) |byte, i| {
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
                        self.startNewWord(&word, i);
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
                        utils.printSrcLineError("invalid character after digit", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .PlusSign, .MinusSign => {
                        try self.emitSign(state, line);
                        self.startNewWord(&word, i);
                        state = .Word;
                    },
                }
            },
            '0'...'9' => {
                switch (state) {
                    .TopLevel => {
                        self.startNewWord(&word, i);
                        start_zero = byte == '0';
                        num_type = .NumberLiteral;
                    },
                    .Word, .Number => {
                        if (state == .Number and num_type == .BinNumLiteral and (byte != '0' and byte != '1')) {
                            utils.printSrcLineError("invalid digit in binary number", file_name, content, line);
                            return LexerError.LexerAnalyzisFailed;
                        }
                        word.addByte();
                        continue;
                    },
                    .PlusSign, .MinusSign => {
                        try self.emitSign(state, line);
                        self.startNewWord(&word, i);
                        start_zero = byte == '0';
                        num_type = .NumberLiteral;
                    },
                }
                state = .Number;
            },
            '"' => {
                if (string) {
                    const token = Token{ .type = .StringLiteral, .val_ind = try self.addValue(word.slice), .line = line };
                    try tokens.append(utils.alloc, token);
                    state = .TopLevel;
                    string = false;
                    continue;
                }
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, line, num_type),
                    .PlusSign, .MinusSign => try self.emitSign(state, line),
                }
                word = String.new(content[i..i].ptr + 1);
                string = true;
            },
            ' ' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, line, num_type),
                    .PlusSign, .MinusSign => continue,
                }
                state = .TopLevel;
            },
            '\n' => {
                if (comment) {
                    line += 1;
                    state = .TopLevel;
                    comment = false;
                    continue;
                } else if (string) {
                    utils.printSrcLineError("not closed string literal", file_name, content, line);
                    return LexerError.LexerAnalyzisFailed;
                }
                switch (state) {
                    .TopLevel => {
                        if (tokens.getLastOrNull()) |last| {
                            if (last.type == .NewLine) {
                                line += 1;
                                continue;
                            }
                        }
                    },
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, line, num_type),
                    .PlusSign, .MinusSign => {
                        utils.printSrcLineError("unexpected end of line after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                const newline = Token{ .type = .NewLine, .val_ind = 0, .line = line };
                try tokens.append(utils.alloc, newline);
                line += 1;
                state = .TopLevel;
                comment = false;
            },
            '+', '-' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, line, num_type),
                    .PlusSign, .MinusSign => {
                        if (two_signs) {
                            utils.printSrcLineError("more than 2 math signs is not allowed", file_name, content, line);
                            return LexerError.LexerAnalyzisFailed;
                        }
                        try self.emitSign(state, line);
                        two_signs = true;
                    },
                }
                state = if (byte == '+') .PlusSign else .MinusSign;
            },
            '*', ':', ',', '[', ']', '(', ')' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, line, num_type),
                    .PlusSign, .MinusSign => {
                        utils.printSrcLineErrorFmt("unexpected '{c}' after sign", .{byte}, file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                try self.emitSeparator(byte, line);
                state = .TopLevel;
            },
            ';' => {
                switch (state) {
                    .TopLevel => {
                        if (tokens.getLastOrNull()) |last| {
                            if (last.type != .NewLine) {
                                const newline = Token{ .type = .NewLine, .val_ind = 0, .line = line };
                                try tokens.append(utils.alloc, newline);
                            }
                        }
                    },
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, line, num_type),
                    .PlusSign, .MinusSign => {
                        utils.printSrcLineError("unexpected comment after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                comment = true;
            },
            '@', '#', '.' => {
                switch (state) {
                    .TopLevel => {
                        self.startNewWord(&word, i);
                        state = .Word;
                    },
                    .Word, .Number, .PlusSign, .MinusSign => {
                        utils.printSrcLineErrorFmt("unexpected '{c}' after sign", .{byte}, file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
            },
            else => {
                utils.printSrcLineErrorFmt("unknown character '{c}'", .{byte}, file_name, content, line);
                return LexerError.LexerAnalyzisFailed;
            },
        }
    }
}

pub fn printTokens(program: *Program) void {
    for (program.tokens.items) |token| {
        if (token.type.isMnemonic()) {
            std.debug.print("\x1b[34m{t}\x1b[0m ", .{token.type});
        } else if (token.type.isReg()) {
            std.debug.print("\x1b[35m{t}\x1b[0m ", .{token.type});
        } else if (token.type == .NewLine) {
            std.debug.print("\n", .{});
        } else if (token.type == .StringLiteral) {
            std.debug.print("\x1b[36m{s}\x1b[0m ", .{program.token_values.items[token.val_ind]});
        } else if (token.type == .NumberLiteral) {
            std.debug.print("\x1b[31m{s}\x1b[0m ", .{program.token_values.items[token.val_ind]});
        } else if (token.type == .HexNumLiteral) {
            std.debug.print("\x1b[32m{s}\x1b[0m ", .{program.token_values.items[token.val_ind]});
        } else if (token.type == .BinNumLiteral) {
            std.debug.print("\x1b[33m{s}\x1b[0m ", .{program.token_values.items[token.val_ind]});
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
            std.debug.print("\x1b[37m{s}\x1b[0m ", .{program.token_values.items[token.val_ind]});
        } else {
            std.debug.print("{t} ", .{token.type});
        }
    }
    std.debug.print("\n", .{});
}
