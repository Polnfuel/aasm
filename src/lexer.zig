const std = @import("std");
const utils = @import("utils");

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

    //Punctuation
    Colon, Comma,
    Plus, Minus, Asteriks,
    OpenBracket, CloseBracket,
    OpenParenthes, CloseParenthes,
    NewLine,

    //Special
    NotPresent,
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
    line: u16,
    type: TokenType,
    value: []u8,
};

pub const LexerError = error{LexerAnalyzisFailed} || std.mem.Allocator.Error;

fn analyzeWord(word: String, line: u16, file_name: []const u8, content: []const u8) LexerError!Token {
    var token_type: TokenType = undefined;
    // Keywords
    if (word.is("d8")) {
        token_type = .d8;
    } else if (word.is("d16")) {
        token_type = .d16;
    } else if (word.is("d32")) {
        token_type = .d32;
    } else if (word.is("d64")) {
        token_type = .d64;
    } else if (word.is("p8")) {
        token_type = .p8;
    } else if (word.is("p16")) {
        token_type = .p16;
    } else if (word.is("p32")) {
        token_type = .p32;
    } else if (word.is("p64")) {
        token_type = .p64;
    } else if (word.is("@data")) {
        token_type = .data;
    } else if (word.is("@code")) {
        token_type = .code;
    } else if (word.is("@entry")) {
        token_type = .entry;
    } else if (word.is("@import")) {
        token_type = .import;
    } else if (word.is("@bss")) {
        token_type = .bss;
    } else if (word.is("repeat")) {
        token_type = .repeat;
    }
    // Instructions
    else if (word.is("adc")) {
        token_type = .adc;
    } else if (word.is("add")) {
        token_type = .add;
    } else if (word.is("and")) {
        token_type = .@"and";
    } else if (word.is("call")) {
        token_type = .call;
    } else if (word.is("cmp")) {
        token_type = .cmp;
    } else if (word.is("dec")) {
        token_type = .dec;
    } else if (word.is("div")) {
        token_type = .div;
    } else if (word.is("idiv")) {
        token_type = .idiv;
    } else if (word.is("imul")) {
        token_type = .imul;
    } else if (word.is("inc")) {
        token_type = .inc;
    } else if (word.is("ja")) {
        token_type = .ja;
    } else if (word.is("jae")) {
        token_type = .jae;
    } else if (word.is("jb")) {
        token_type = .jb;
    } else if (word.is("jbe")) {
        token_type = .jbe;
    } else if (word.is("jc")) {
        token_type = .jc;
    } else if (word.is("je")) {
        token_type = .je;
    } else if (word.is("jg")) {
        token_type = .jg;
    } else if (word.is("jge")) {
        token_type = .jge;
    } else if (word.is("jl")) {
        token_type = .jl;
    } else if (word.is("jle")) {
        token_type = .jle;
    } else if (word.is("jmp")) {
        token_type = .jmp;
    } else if (word.is("jna")) {
        token_type = .jna;
    } else if (word.is("jnae")) {
        token_type = .jnae;
    } else if (word.is("jnb")) {
        token_type = .jnb;
    } else if (word.is("jnbe")) {
        token_type = .jnbe;
    } else if (word.is("jnc")) {
        token_type = .jnc;
    } else if (word.is("jne")) {
        token_type = .jne;
    } else if (word.is("jng")) {
        token_type = .jng;
    } else if (word.is("jnge")) {
        token_type = .jnge;
    } else if (word.is("jnl")) {
        token_type = .jnl;
    } else if (word.is("jnle")) {
        token_type = .jnle;
    } else if (word.is("jno")) {
        token_type = .jno;
    } else if (word.is("jnp")) {
        token_type = .jnp;
    } else if (word.is("jns")) {
        token_type = .jns;
    } else if (word.is("jnz")) {
        token_type = .jnz;
    } else if (word.is("jo")) {
        token_type = .jo;
    } else if (word.is("jp")) {
        token_type = .jp;
    } else if (word.is("jpe")) {
        token_type = .jpe;
    } else if (word.is("jpo")) {
        token_type = .jpo;
    } else if (word.is("js")) {
        token_type = .js;
    } else if (word.is("jz")) {
        token_type = .jz;
    } else if (word.is("lea")) {
        token_type = .lea;
    } else if (word.is("mul")) {
        token_type = .mul;
    } else if (word.is("mov")) {
        token_type = .mov;
    } else if (word.is("movzx")) {
        token_type = .movzx;
    } else if (word.is("neg")) {
        token_type = .neg;
    } else if (word.is("not")) {
        token_type = .not;
    } else if (word.is("or")) {
        token_type = .@"or";
    } else if (word.is("pop")) {
        token_type = .pop;
    } else if (word.is("push")) {
        token_type = .push;
    } else if (word.is("ret")) {
        token_type = .ret;
    } else if (word.is("sal")) {
        token_type = .sal;
    } else if (word.is("sar")) {
        token_type = .sar;
    } else if (word.is("shl")) {
        token_type = .shl;
    } else if (word.is("shr")) {
        token_type = .shr;
    } else if (word.is("sbb")) {
        token_type = .sbb;
    } else if (word.is("sub")) {
        token_type = .sub;
    } else if (word.is("syscall")) {
        token_type = .syscall;
    } else if (word.is("test")) {
        token_type = .@"test";
    } else if (word.is("xor")) {
        token_type = .xor;
    }
    // Registers
    else if (word.is("rax")) {
        token_type = .rax;
    } else if (word.is("rbx")) {
        token_type = .rbx;
    } else if (word.is("rcx")) {
        token_type = .rcx;
    } else if (word.is("rdx")) {
        token_type = .rdx;
    } else if (word.is("rsi")) {
        token_type = .rsi;
    } else if (word.is("rdi")) {
        token_type = .rdi;
    } else if (word.is("rsp")) {
        token_type = .rsp;
    } else if (word.is("rbp")) {
        token_type = .rbp;
    } else if (word.is("r8")) {
        token_type = .r8;
    } else if (word.is("r9")) {
        token_type = .r9;
    } else if (word.is("r10")) {
        token_type = .r10;
    } else if (word.is("r11")) {
        token_type = .r11;
    } else if (word.is("r12")) {
        token_type = .r12;
    } else if (word.is("r13")) {
        token_type = .r13;
    } else if (word.is("r14")) {
        token_type = .r14;
    } else if (word.is("r15")) {
        token_type = .r15;
    } else if (word.is("rip")) {
        token_type = .rip;
    } else if (word.is("eax")) {
        token_type = .eax;
    } else if (word.is("ebx")) {
        token_type = .ebx;
    } else if (word.is("ecx")) {
        token_type = .ecx;
    } else if (word.is("edx")) {
        token_type = .edx;
    } else if (word.is("edi")) {
        token_type = .edi;
    } else if (word.is("esi")) {
        token_type = .esi;
    } else if (word.is("esp")) {
        token_type = .esp;
    } else if (word.is("ebp")) {
        token_type = .ebp;
    } else if (word.is("r8d")) {
        token_type = .r8d;
    } else if (word.is("r9d")) {
        token_type = .r9d;
    } else if (word.is("r10d")) {
        token_type = .r10d;
    } else if (word.is("r11d")) {
        token_type = .r11d;
    } else if (word.is("r12d")) {
        token_type = .r12d;
    } else if (word.is("r13d")) {
        token_type = .r13d;
    } else if (word.is("r14d")) {
        token_type = .r14d;
    } else if (word.is("r15d")) {
        token_type = .r15d;
    } else if (word.is("ax")) {
        token_type = .ax;
    } else if (word.is("bx")) {
        token_type = .bx;
    } else if (word.is("cx")) {
        token_type = .cx;
    } else if (word.is("dx")) {
        token_type = .dx;
    } else if (word.is("di")) {
        token_type = .di;
    } else if (word.is("si")) {
        token_type = .si;
    } else if (word.is("sp")) {
        token_type = .sp;
    } else if (word.is("bp")) {
        token_type = .bp;
    } else if (word.is("r8w")) {
        token_type = .r8w;
    } else if (word.is("r9w")) {
        token_type = .r9w;
    } else if (word.is("r10w")) {
        token_type = .r10w;
    } else if (word.is("r11w")) {
        token_type = .r11w;
    } else if (word.is("r12w")) {
        token_type = .r12w;
    } else if (word.is("r13w")) {
        token_type = .r13w;
    } else if (word.is("r14w")) {
        token_type = .r14w;
    } else if (word.is("r15w")) {
        token_type = .r15w;
    } else if (word.is("ah")) {
        token_type = .ah;
    } else if (word.is("al")) {
        token_type = .al;
    } else if (word.is("bh")) {
        token_type = .bh;
    } else if (word.is("bl")) {
        token_type = .bl;
    } else if (word.is("ch")) {
        token_type = .ch;
    } else if (word.is("cl")) {
        token_type = .cl;
    } else if (word.is("dh")) {
        token_type = .dh;
    } else if (word.is("dl")) {
        token_type = .dl;
    } else if (word.is("sil")) {
        token_type = .sil;
    } else if (word.is("dil")) {
        token_type = .dil;
    } else if (word.is("bpl")) {
        token_type = .bpl;
    } else if (word.is("spl")) {
        token_type = .spl;
    } else if (word.is("r8b")) {
        token_type = .r8b;
    } else if (word.is("r9b")) {
        token_type = .r9b;
    } else if (word.is("r10b")) {
        token_type = .r10b;
    } else if (word.is("r11b")) {
        token_type = .r11b;
    } else if (word.is("r12b")) {
        token_type = .r12b;
    } else if (word.is("r13b")) {
        token_type = .r13b;
    } else if (word.is("r14b")) {
        token_type = .r14b;
    } else if (word.is("r15b")) {
        token_type = .r15b;
    } else if (word.slice[0] == '#') {
        if (word.slice.len > 1) {
            token_type = .HashIdent;
        } else {
            utils.printSrcLineError("expected label name after #", file_name, content, line);
            return LexerError.LexerAnalyzisFailed;
        }
    } else if (word.slice[0] == '.') {
        if (word.slice.len > 1) {
            token_type = .DotIdent;
        } else {
            utils.printSrcLineError("expected label name after .", file_name, content, line);
            return LexerError.LexerAnalyzisFailed;
        }
    } else if (word.slice[0] == '@') {
        utils.printSrcLineError("unsupported keyword name after @", file_name, content, line);
        return LexerError.LexerAnalyzisFailed;
    } else {
        token_type = .Ident;
    }

    return Token{ .type = token_type, .value = switch (token_type) {
        .Ident, .DotIdent => word.slice,
        .HashIdent => word.slice[1..],
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
};

pub fn tokenizeContent(content: []const u8, file_name: []const u8) LexerError!std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(utils.alloc);

    var line: u16 = 1;

    var state: LexerState = .TopLevel;
    var word: String = String.new(content.ptr);

    var two_signs = false;

    for (content, 0..) |byte, i| {
        if (state != .MinusSign and state != .PlusSign and two_signs) {
            two_signs = false;
        }
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
                    .Number => {
                        utils.printSrcLineError("invalid character after digit", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .MinusSign => {
                        const minus = Token{ .type = .Minus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, minus);

                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .Word;
                    },
                    .PlusSign => {
                        const plus = Token{ .type = .Plus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, plus);

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
                    },
                    .Word, .Number => {
                        word.addByte();
                        continue;
                    },
                    .MinusSign => {
                        const minus = Token{ .type = .Minus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, minus);

                        word = String.new(content[i..i].ptr);
                        word.addByte();
                    },
                    .PlusSign => {
                        const plus = Token{ .type = .Plus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, plus);

                        word = String.new(content[i..i].ptr);
                        word.addByte();
                    },
                    .Comment, .String => unreachable,
                }
                state = .Number;
            },
            '"' => {
                switch (state) {
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .MinusSign => {
                        const minus = Token{ .type = .Minus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, minus);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .PlusSign => {
                        const plus = Token{ .type = .Plus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, plus);
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                        // utils.printSrcLineError("unexpected string after sign", file_name, content, line);
                        // return LexerError.LexerAnalyzisFailed;
                    },
                    .TopLevel => {
                        word = String.new(content[i..i].ptr + 1);
                        state = .String;
                    },
                    .String => {
                        const token = Token{ .type = .StringLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                        state = .TopLevel;
                    },
                    .Comment => unreachable,
                }
            },
            ' ' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
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
                        utils.printSrcLineError("not closed string literal", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected end of line after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                }
                const newline = Token{ .type = .NewLine, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, newline);
                line += 1;
                state = .TopLevel;
            },
            '-' => {
                switch (state) {
                    .TopLevel => {},
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        if (two_signs) {
                            utils.printSrcLineError("more than 2 math signs is not allowed", file_name, content, line);
                            return LexerError.LexerAnalyzisFailed;
                        }
                        const token = Token{ .type = if (state == .MinusSign) .Minus else .Plus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, token);
                        two_signs = true;
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
                        try tokens.append(utils.alloc, token);
                    },
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        if (two_signs) {
                            utils.printSrcLineError("more than 2 math signs is not allowed", file_name, content, line);
                            return LexerError.LexerAnalyzisFailed;
                        }
                        const token = Token{ .type = if (state == .MinusSign) .Minus else .Plus, .value = content[0..0], .line = line };
                        try tokens.append(utils.alloc, token);
                        two_signs = true;
                    },
                    .Comment, .String => unreachable,
                }
                state = .PlusSign;
            },
            '*' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected * after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const asteriks = Token{ .type = .Asteriks, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, asteriks);
                state = .TopLevel;
            },
            ':' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected : after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const colon = Token{ .type = .Colon, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, colon);
                state = .TopLevel;
            },
            ',' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected , after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const comma = Token{ .type = .Comma, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, comma);
                state = .TopLevel;
            },
            '[' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected [ after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const obrac = Token{ .type = .OpenBracket, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, obrac);
                state = .TopLevel;
            },
            ']' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected ] after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const cbrac = Token{ .type = .CloseBracket, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, cbrac);
                state = .TopLevel;
            },
            '(' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected ( after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const oparen = Token{ .type = .OpenParenthes, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, oparen);
                state = .TopLevel;
            },
            ')' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected ) after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                const cparen = Token{ .type = .CloseParenthes, .value = content[0..0], .line = line };
                try tokens.append(utils.alloc, cparen);
                state = .TopLevel;
            },
            ';' => {
                switch (state) {
                    .TopLevel => {
                        if (tokens.getLastOrNull()) |last| {
                            if (last.type != .NewLine) {
                                const newline = Token{ .type = .NewLine, .value = content[0..0], .line = line };
                                try tokens.append(utils.alloc, newline);
                            }
                        }
                    },
                    .Word => {
                        const token = try analyzeWord(word, line, file_name, content);
                        try tokens.append(utils.alloc, token);
                    },
                    .Number => {
                        const token = Token{ .type = .NumberLiteral, .value = word.slice, .line = line };
                        try tokens.append(utils.alloc, token);
                    },
                    .MinusSign, .PlusSign => {
                        utils.printSrcLineError("unexpected comment after sign", file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
                state = .Comment;
            },
            '@', '#', '.' => {
                switch (state) {
                    .TopLevel => {
                        word = String.new(content[i..i].ptr);
                        word.addByte();
                        state = .Word;
                    },
                    .Word, .Number, .MinusSign, .PlusSign => {
                        utils.printSrcLineErrorFmt("unexpected '{c}'", .{byte}, file_name, content, line);
                        return LexerError.LexerAnalyzisFailed;
                    },
                    .Comment, .String => unreachable,
                }
            },
            else => {
                utils.printSrcLineError("unknown character", file_name, content, line);
                return LexerError.LexerAnalyzisFailed;
            },
        }
    }

    return tokens;
}

pub fn printTokens(tokens: std.ArrayList(Token)) void {
    for (tokens.items) |token| {
        if (token.type.isMnemonic()) {
            std.debug.print("\x1b[34m{t}\x1b[0m ", .{token.type});
        } else if (token.type.isReg()) {
            std.debug.print("\x1b[35m{t}\x1b[0m ", .{token.type});
        } else if (token.type == .NewLine) {
            std.debug.print("\n", .{});
        } else if (token.type == .StringLiteral) {
            std.debug.print("\x1b[36m{s}\x1b[0m ", .{token.value});
        } else if (token.type == .NumberLiteral) {
            std.debug.print("\x1b[31m{s}\x1b[0m ", .{token.value});
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
            std.debug.print("\x1b[37m{s}\x1b[0m ", .{token.value});
        } else {
            std.debug.print("{t} ", .{token.type});
        }
    }
    std.debug.print("\n", .{});
}
