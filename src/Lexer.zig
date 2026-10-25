const std = @import("std");
const utils = @import("utils");
const Program = @import("Program");
const Lexer = @This();
pub const TokenType = @import("TokenType").TokenType;

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
};

const keywords: SortedKeywords = .init(&.{
    .{ "ah", TokenType.ah },
    .{ "al", TokenType.al },
    .{ "ax", TokenType.ax },
    .{ "bh", TokenType.bh },
    .{ "bl", TokenType.bl },
    .{ "bp", TokenType.bp },
    .{ "bx", TokenType.bx },
    .{ "ch", TokenType.ch },
    .{ "cl", TokenType.cl },
    .{ "cx", TokenType.cx },
    .{ "d8", TokenType.d8 },
    .{ "dh", TokenType.dh },
    .{ "di", TokenType.di },
    .{ "dl", TokenType.dl },
    .{ "dx", TokenType.dx },
    .{ "ja", TokenType.ja },
    .{ "jb", TokenType.jb },
    .{ "jc", TokenType.jc },
    .{ "je", TokenType.je },
    .{ "jg", TokenType.jg },
    .{ "jl", TokenType.jl },
    .{ "jo", TokenType.jo },
    .{ "jp", TokenType.jp },
    .{ "js", TokenType.js },
    .{ "jz", TokenType.jz },
    .{ "or", TokenType.@"or" },
    .{ "p8", TokenType.p8 },
    .{ "r8", TokenType.r8 },
    .{ "r9", TokenType.r9 },
    .{ "si", TokenType.si },
    .{ "sp", TokenType.sp },
    .{ "adc", TokenType.adc },
    .{ "add", TokenType.add },
    .{ "and", TokenType.@"and" },
    .{ "bpl", TokenType.bpl },
    .{ "clc", TokenType.clc },
    .{ "cli", TokenType.cli },
    .{ "cmp", TokenType.cmp },
    .{ "d16", TokenType.d16 },
    .{ "d32", TokenType.d32 },
    .{ "d64", TokenType.d64 },
    .{ "dec", TokenType.dec },
    .{ "dil", TokenType.dil },
    .{ "div", TokenType.div },
    .{ "eax", TokenType.eax },
    .{ "ebp", TokenType.ebp },
    .{ "ebx", TokenType.ebx },
    .{ "ecx", TokenType.ecx },
    .{ "edi", TokenType.edi },
    .{ "edx", TokenType.edx },
    .{ "esi", TokenType.esi },
    .{ "esp", TokenType.esp },
    .{ "hlt", TokenType.hlt },
    .{ "inc", TokenType.inc },
    .{ "jae", TokenType.jae },
    .{ "jbe", TokenType.jbe },
    .{ "jge", TokenType.jge },
    .{ "jle", TokenType.jle },
    .{ "jmp", TokenType.jmp },
    .{ "jna", TokenType.jna },
    .{ "jnb", TokenType.jnb },
    .{ "jnc", TokenType.jnc },
    .{ "jne", TokenType.jne },
    .{ "jng", TokenType.jng },
    .{ "jnl", TokenType.jnl },
    .{ "jno", TokenType.jno },
    .{ "jnp", TokenType.jnp },
    .{ "jns", TokenType.jns },
    .{ "jnz", TokenType.jnz },
    .{ "jpe", TokenType.jpe },
    .{ "jpo", TokenType.jpo },
    .{ "lea", TokenType.lea },
    .{ "ltr", TokenType.ltr },
    .{ "mov", TokenType.mov },
    .{ "mul", TokenType.mul },
    .{ "neg", TokenType.neg },
    .{ "not", TokenType.not },
    .{ "p16", TokenType.p16 },
    .{ "p32", TokenType.p32 },
    .{ "p64", TokenType.p64 },
    .{ "pop", TokenType.pop },
    .{ "por", TokenType.por },
    .{ "r10", TokenType.r10 },
    .{ "r11", TokenType.r11 },
    .{ "r12", TokenType.r12 },
    .{ "r13", TokenType.r13 },
    .{ "r14", TokenType.r14 },
    .{ "r15", TokenType.r15 },
    .{ "r8b", TokenType.r8b },
    .{ "r8d", TokenType.r8d },
    .{ "r8w", TokenType.r8w },
    .{ "r9b", TokenType.r9b },
    .{ "r9d", TokenType.r9d },
    .{ "r9w", TokenType.r9w },
    .{ "rax", TokenType.rax },
    .{ "rbp", TokenType.rbp },
    .{ "rbx", TokenType.rbx },
    .{ "rcl", TokenType.rcl },
    .{ "rcr", TokenType.rcr },
    .{ "rcx", TokenType.rcx },
    .{ "rdi", TokenType.rdi },
    .{ "rdx", TokenType.rdx },
    .{ "ret", TokenType.ret },
    .{ "rip", TokenType.rip },
    .{ "rol", TokenType.rol },
    .{ "ror", TokenType.ror },
    .{ "rsi", TokenType.rsi },
    .{ "rsp", TokenType.rsp },
    .{ "sal", TokenType.sal },
    .{ "sar", TokenType.sar },
    .{ "sbb", TokenType.sbb },
    .{ "shl", TokenType.shl },
    .{ "shr", TokenType.shr },
    .{ "sil", TokenType.sil },
    .{ "spl", TokenType.spl },
    .{ "sub", TokenType.sub },
    .{ "xor", TokenType.xor },
    .{ "@bss", TokenType.bss },
    .{ "call", TokenType.call },
    .{ "d128", TokenType.d128 },
    .{ "dppd", TokenType.dppd },
    .{ "dpps", TokenType.dpps },
    .{ "enum", TokenType.@"enum" },
    .{ "idiv", TokenType.idiv },
    .{ "imul", TokenType.imul },
    .{ "jnae", TokenType.jnae },
    .{ "jnbe", TokenType.jnbe },
    .{ "jnge", TokenType.jnge },
    .{ "jnle", TokenType.jnle },
    .{ "lgdt", TokenType.lgdt },
    .{ "lidt", TokenType.lidt },
    .{ "movd", TokenType.movd },
    .{ "movq", TokenType.movq },
    .{ "orpd", TokenType.orpd },
    .{ "orps", TokenType.orps },
    .{ "p128", TokenType.p128 },
    .{ "pand", TokenType.pand },
    .{ "push", TokenType.push },
    .{ "pxor", TokenType.pxor },
    .{ "r10b", TokenType.r10b },
    .{ "r10d", TokenType.r10d },
    .{ "r10w", TokenType.r10w },
    .{ "r11b", TokenType.r11b },
    .{ "r11d", TokenType.r11d },
    .{ "r11w", TokenType.r11w },
    .{ "r12b", TokenType.r12b },
    .{ "r12d", TokenType.r12d },
    .{ "r12w", TokenType.r12w },
    .{ "r13b", TokenType.r13b },
    .{ "r13d", TokenType.r13d },
    .{ "r13w", TokenType.r13w },
    .{ "r14b", TokenType.r14b },
    .{ "r14d", TokenType.r14d },
    .{ "r14w", TokenType.r14w },
    .{ "r15b", TokenType.r15b },
    .{ "r15d", TokenType.r15d },
    .{ "r15w", TokenType.r15w },
    .{ "test", TokenType.@"test" },
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
    .{ "@code", TokenType.code },
    .{ "@data", TokenType.data },
    .{ "addpd", TokenType.addpd },
    .{ "addps", TokenType.addps },
    .{ "addsd", TokenType.addsd },
    .{ "addss", TokenType.addss },
    .{ "andpd", TokenType.andpd },
    .{ "andps", TokenType.andps },
    .{ "cmppd", TokenType.cmppd },
    .{ "cmpps", TokenType.cmpps },
    .{ "cmpsd", TokenType.cmpsd },
    .{ "cmpss", TokenType.cmpss },
    .{ "divpd", TokenType.divpd },
    .{ "divps", TokenType.divps },
    .{ "divsd", TokenType.divsd },
    .{ "divss", TokenType.divss },
    .{ "iretq", TokenType.iretq },
    .{ "lddqu", TokenType.lddqu },
    .{ "maxpd", TokenType.maxpd },
    .{ "maxps", TokenType.maxps },
    .{ "maxsd", TokenType.maxsd },
    .{ "maxss", TokenType.maxss },
    .{ "minpd", TokenType.minpd },
    .{ "minps", TokenType.minps },
    .{ "minsd", TokenType.minsd },
    .{ "minss", TokenType.minss },
    .{ "movsd", TokenType.movsd },
    .{ "movss", TokenType.movss },
    .{ "movzx", TokenType.movzx },
    .{ "mulpd", TokenType.mulpd },
    .{ "mulps", TokenType.mulps },
    .{ "mulsd", TokenType.mulsd },
    .{ "mulss", TokenType.mulss },
    .{ "pabsb", TokenType.pabsb },
    .{ "pabsd", TokenType.pabsd },
    .{ "pabsw", TokenType.pabsw },
    .{ "paddb", TokenType.paddb },
    .{ "paddd", TokenType.paddd },
    .{ "paddq", TokenType.paddq },
    .{ "paddw", TokenType.paddw },
    .{ "pandn", TokenType.pandn },
    .{ "pavgb", TokenType.pavgb },
    .{ "pavgw", TokenType.pavgw },
    .{ "pslld", TokenType.pslld },
    .{ "psllq", TokenType.psllq },
    .{ "psllw", TokenType.psllw },
    .{ "psrad", TokenType.psrad },
    .{ "psraw", TokenType.psraw },
    .{ "psrld", TokenType.psrld },
    .{ "psrlq", TokenType.psrlq },
    .{ "psrlw", TokenType.psrlw },
    .{ "psubb", TokenType.psubb },
    .{ "psubd", TokenType.psubd },
    .{ "psubq", TokenType.psubq },
    .{ "psubw", TokenType.psubw },
    .{ "ptest", TokenType.ptest },
    .{ "rcpps", TokenType.rcpps },
    .{ "rcpss", TokenType.rcpss },
    .{ "subpd", TokenType.subpd },
    .{ "subps", TokenType.subps },
    .{ "subsd", TokenType.subsd },
    .{ "subss", TokenType.subss },
    .{ "xmm10", TokenType.xmm10 },
    .{ "xmm11", TokenType.xmm11 },
    .{ "xmm12", TokenType.xmm12 },
    .{ "xmm13", TokenType.xmm13 },
    .{ "xmm14", TokenType.xmm14 },
    .{ "xmm15", TokenType.xmm15 },
    .{ "xorpd", TokenType.xorpd },
    .{ "xorps", TokenType.xorps },
    .{ "@align", TokenType.@"align" },
    .{ "@const", TokenType.@"const" },
    .{ "@entry", TokenType.entry },
    .{ "@types", TokenType.types },
    .{ "andnpd", TokenType.andnpd },
    .{ "andnps", TokenType.andnps },
    .{ "comisd", TokenType.comisd },
    .{ "comiss", TokenType.comiss },
    .{ "haddpd", TokenType.haddpd },
    .{ "haddps", TokenType.haddps },
    .{ "hsubpd", TokenType.hsubpd },
    .{ "hsubps", TokenType.hsubps },
    .{ "invlpg", TokenType.invlpg },
    .{ "movapd", TokenType.movapd },
    .{ "movaps", TokenType.movaps },
    .{ "movdqa", TokenType.movdqa },
    .{ "movdqu", TokenType.movdqu },
    .{ "movhpd", TokenType.movhpd },
    .{ "movhps", TokenType.movhps },
    .{ "movlpd", TokenType.movlpd },
    .{ "movlps", TokenType.movlps },
    .{ "movnti", TokenType.movnti },
    .{ "movupd", TokenType.movupd },
    .{ "movups", TokenType.movups },
    .{ "packed", TokenType.@"packed" },
    .{ "paddsb", TokenType.paddsb },
    .{ "paddsw", TokenType.paddsw },
    .{ "pextrb", TokenType.pextrb },
    .{ "pextrd", TokenType.pextrd },
    .{ "pextrq", TokenType.pextrq },
    .{ "pextrw", TokenType.pextrw },
    .{ "phaddd", TokenType.phaddd },
    .{ "phaddw", TokenType.phaddw },
    .{ "phsubd", TokenType.phsubd },
    .{ "phsubw", TokenType.phsubw },
    .{ "pinsrb", TokenType.pinsrb },
    .{ "pinsrd", TokenType.pinsrd },
    .{ "pinsrq", TokenType.pinsrq },
    .{ "pinsrw", TokenType.pinsrw },
    .{ "pmaxsb", TokenType.pmaxsb },
    .{ "pmaxsd", TokenType.pmaxsd },
    .{ "pmaxsw", TokenType.pmaxsw },
    .{ "pmaxub", TokenType.pmaxub },
    .{ "pmaxud", TokenType.pmaxud },
    .{ "pmaxuw", TokenType.pmaxuw },
    .{ "pminsb", TokenType.pminsb },
    .{ "pminsd", TokenType.pminsd },
    .{ "pminsw", TokenType.pminsw },
    .{ "pminub", TokenType.pminub },
    .{ "pminud", TokenType.pminud },
    .{ "pminuw", TokenType.pminuw },
    .{ "pmuldq", TokenType.pmuldq },
    .{ "pmulhw", TokenType.pmulhw },
    .{ "pmulld", TokenType.pmulld },
    .{ "pmullw", TokenType.pmullw },
    .{ "psadbw", TokenType.psadbw },
    .{ "pshufb", TokenType.pshufb },
    .{ "pshufd", TokenType.pshufd },
    .{ "psignb", TokenType.psignb },
    .{ "psignd", TokenType.psignd },
    .{ "psignw", TokenType.psignw },
    .{ "pslldq", TokenType.pslldq },
    .{ "psrldq", TokenType.psrldq },
    .{ "psubsb", TokenType.psubsb },
    .{ "psubsw", TokenType.psubsw },
    .{ "repeat", TokenType.repeat },
    .{ "shufpd", TokenType.shufpd },
    .{ "shufps", TokenType.shufps },
    .{ "sizeof", TokenType.sizeof },
    .{ "sqrtpd", TokenType.sqrtpd },
    .{ "sqrtps", TokenType.sqrtps },
    .{ "sqrtsd", TokenType.sqrtsd },
    .{ "sqrtss", TokenType.sqrtss },
    .{ "struct", TokenType.@"struct" },
    .{ "@import", TokenType.import },
    .{ "alignof", TokenType.alignof },
    .{ "blendpd", TokenType.blendpd },
    .{ "blendps", TokenType.blendps },
    .{ "movddup", TokenType.movddup },
    .{ "movhlps", TokenType.movhlps },
    .{ "movlhps", TokenType.movlhps },
    .{ "movntdq", TokenType.movntdq },
    .{ "movntpd", TokenType.movntpd },
    .{ "movntps", TokenType.movntps },
    .{ "movntsd", TokenType.movntsd },
    .{ "movntss", TokenType.movntss },
    .{ "mpsadbw", TokenType.mpsadbw },
    .{ "paddusb", TokenType.paddusb },
    .{ "paddusw", TokenType.paddusw },
    .{ "palignr", TokenType.palignr },
    .{ "pblendw", TokenType.pblendw },
    .{ "pcmpeqb", TokenType.pcmpeqb },
    .{ "pcmpeqd", TokenType.pcmpeqd },
    .{ "pcmpeqq", TokenType.pcmpeqq },
    .{ "pcmpeqw", TokenType.pcmpeqw },
    .{ "pcmpgtb", TokenType.pcmpgtb },
    .{ "pcmpgtd", TokenType.pcmpgtd },
    .{ "pcmpgtq", TokenType.pcmpgtq },
    .{ "pcmpgtw", TokenType.pcmpgtw },
    .{ "phaddsw", TokenType.phaddsw },
    .{ "phsubsw", TokenType.phsubsw },
    .{ "pmaddwd", TokenType.pmaddwd },
    .{ "pmulhuw", TokenType.pmulhuw },
    .{ "pmuludq", TokenType.pmuludq },
    .{ "pshufhw", TokenType.pshufhw },
    .{ "pshuflw", TokenType.pshuflw },
    .{ "psubusb", TokenType.psubusb },
    .{ "psubusw", TokenType.psubusw },
    .{ "roundpd", TokenType.roundpd },
    .{ "roundps", TokenType.roundps },
    .{ "roundsd", TokenType.roundsd },
    .{ "roundss", TokenType.roundss },
    .{ "rsqrtps", TokenType.rsqrtps },
    .{ "rsqrtss", TokenType.rsqrtss },
    .{ "syscall", TokenType.syscall },
    .{ "ucomisd", TokenType.ucomisd },
    .{ "ucomiss", TokenType.ucomiss },
    .{ "addsubpd", TokenType.addsubpd },
    .{ "addsubps", TokenType.addsubps },
    .{ "blendvpd", TokenType.blendvpd },
    .{ "blendvps", TokenType.blendvps },
    .{ "cvtdq2pd", TokenType.cvtdq2pd },
    .{ "cvtdq2ps", TokenType.cvtdq2ps },
    .{ "cvtpd2dq", TokenType.cvtpd2dq },
    .{ "cvtpd2ps", TokenType.cvtpd2ps },
    .{ "cvtpi2pd", TokenType.cvtpi2pd },
    .{ "cvtpi2ps", TokenType.cvtpi2ps },
    .{ "cvtps2dq", TokenType.cvtps2dq },
    .{ "cvtps2pd", TokenType.cvtps2pd },
    .{ "cvtsd2si", TokenType.cvtsd2si },
    .{ "cvtsd2ss", TokenType.cvtsd2ss },
    .{ "cvtsi2sd", TokenType.cvtsi2sd },
    .{ "cvtsi2ss", TokenType.cvtsi2ss },
    .{ "cvtss2sd", TokenType.cvtss2sd },
    .{ "cvtss2si", TokenType.cvtss2si },
    .{ "insertps", TokenType.insertps },
    .{ "movmskpd", TokenType.movmskpd },
    .{ "movmskps", TokenType.movmskps },
    .{ "movntdqa", TokenType.movntdqa },
    .{ "movshdup", TokenType.movshdup },
    .{ "movsldup", TokenType.movsldup },
    .{ "packssdw", TokenType.packssdw },
    .{ "packsswb", TokenType.packsswb },
    .{ "packusdw", TokenType.packusdw },
    .{ "packuswb", TokenType.packuswb },
    .{ "pblendvb", TokenType.pblendvb },
    .{ "pmovmskb", TokenType.pmovmskb },
    .{ "pmovsxbd", TokenType.pmovsxbd },
    .{ "pmovsxbq", TokenType.pmovsxbq },
    .{ "pmovsxbw", TokenType.pmovsxbw },
    .{ "pmovsxdq", TokenType.pmovsxdq },
    .{ "pmovsxwd", TokenType.pmovsxwd },
    .{ "pmovsxwq", TokenType.pmovsxwq },
    .{ "pmovzxbd", TokenType.pmovzxbd },
    .{ "pmovzxbq", TokenType.pmovzxbq },
    .{ "pmovzxbw", TokenType.pmovzxbw },
    .{ "pmovzxdq", TokenType.pmovzxdq },
    .{ "pmovzxwd", TokenType.pmovzxwd },
    .{ "pmovzxwq", TokenType.pmovzxwq },
    .{ "pmulhrsw", TokenType.pmulhrsw },
    .{ "unpckhpd", TokenType.unpckhpd },
    .{ "unpckhps", TokenType.unpckhps },
    .{ "unpcklpd", TokenType.unpcklpd },
    .{ "unpcklps", TokenType.unpcklps },
    .{ "cvttpd2dq", TokenType.cvttpd2dq },
    .{ "cvttps2dq", TokenType.cvttps2dq },
    .{ "cvttsd2si", TokenType.cvttsd2si },
    .{ "cvttss2si", TokenType.cvttss2si },
    .{ "extractps", TokenType.extractps },
    .{ "pclmulqdq", TokenType.pclmulqdq },
    .{ "pcmpestri", TokenType.pcmpestri },
    .{ "pcmpestrm", TokenType.pcmpestrm },
    .{ "pcmpistri", TokenType.pcmpistri },
    .{ "pcmpistrm", TokenType.pcmpistrm },
    .{ "pmaddubsw", TokenType.pmaddubsw },
    .{ "punpckhbw", TokenType.punpckhbw },
    .{ "punpckhdq", TokenType.punpckhdq },
    .{ "punpckhwd", TokenType.punpckhwd },
    .{ "punpcklbw", TokenType.punpcklbw },
    .{ "punpckldq", TokenType.punpckldq },
    .{ "punpcklwd", TokenType.punpcklwd },
    .{ "maskmovdqu", TokenType.maskmovdqu },
    .{ "phminposuw", TokenType.phminposuw },
    .{ "punpckhqdq", TokenType.punpckhqdq },
    .{ "punpcklqdq", TokenType.punpcklqdq },
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

    return Token{ .type = token_type, .val_ind = if (token_type == .Ident or token_type == .DotIdent)
        try utils.putString(word.slice)
    else if (token_type == .HashIdent)
        try utils.putString(word.slice[1..])
    else if (token_type.isDataDirective()) switch (token_type) {
        .d8 => std.math.maxInt(u16) - 1,
        .d16 => std.math.maxInt(u16) - 2,
        .d32 => std.math.maxInt(u16) - 3,
        .d64 => std.math.maxInt(u16) - 4,
        .d128 => std.math.maxInt(u16) - 5,
        else => unreachable,
    } else 0, .line = line, .col = word.col };
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
        '(' => .OpenParen,
        ')' => .CloseParen,
        '{' => .OpenBrace,
        '}' => .CloseBrace,
        '.' => .Dot,
        '-' => .Minus,
        '+' => .Plus,
        '&' => .Ampersand,
        '|' => .Pipe,
        '^' => .Hat,
        '%' => .Percent,
        '/' => .Slash,
        '~' => .Tilde,
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
    var start_zero = false;
    var num_type: TokenType = .NumberLiteral;
    var angle_bracket = false;

    for (content, 0..) |byte, i| {
        col += 1;
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
                }
                state = .Number;
            },
            '"' => {
                if (string) {
                    const token = Token{ .type = .StringLiteral, .val_ind = try utils.putString(word.slice), .line = line, .col = word.col - 1 };
                    try tokens.append(utils.alloc, token);
                    state = .TopLevel;
                    string = false;
                    continue;
                }
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                }
                word = String.new(content[i..i].ptr + 1, col + 1);
                string = true;
            },
            ' ' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
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
                }
                const newline = Token{ .type = .NewLine, .val_ind = 0, .line = line, .col = col };
                try tokens.append(utils.alloc, newline);
                line += 1;
                col = 0;
                state = .TopLevel;
                comment = false;
            },
            '*', ':', ',', '[', ']', '(', ')', '{', '}', '-', '+', '&', '|', '^', '%', '/', '~' => {
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                }
                try self.emitSeparator(byte, line, col);
                state = .TopLevel;
            },
            '<', '>' => {
                if (angle_bracket) {
                    angle_bracket = false;
                    continue;
                } else if (content[i + 1] == byte) {
                    try self.program.tokens.append(utils.alloc, Token{ .type = if (byte == '<') .LessThan2 else .MoreThan2, .val_ind = 0, .line = line, .col = col });
                    angle_bracket = true;
                } else {
                    utils.printSrcLineColError("unexpected token", program, line, col);
                    return LexerError.LexerAnalyzisFailed;
                }
                switch (state) {
                    .TopLevel => {},
                    .Word => try self.emitWord(word, line),
                    .Number => try self.emitNumber(word, num_type, line),
                }
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
                }
                comment = true;
                state = .TopLevel;
            },
            '@', '#', '.' => {
                switch (state) {
                    .TopLevel => {
                        self.startNewWord(&word, i, col);
                        state = .Word;
                    },
                    .Word, .Number => {
                        if (byte == '.') {
                            if (state == .Word)
                                try self.emitWord(word, line)
                            else
                                try self.emitNumber(word, num_type, line);
                            try self.emitSeparator(byte, line, col);
                            state = .TopLevel;
                        } else {
                            utils.printSrcLineColError("unexpected character", program, line, col);
                            return LexerError.LexerAnalyzisFailed;
                        }
                    },
                }
            },
            else => {
                utils.printSrcLineColError("unknown character", program, line, col);
                return LexerError.LexerAnalyzisFailed;
            },
        }
    }

    try program.tokens.append(utils.alloc, .{ .type = .Eof, .val_ind = 0, .line = if (tokens.getLastOrNull()) |tok| tok.line + 1 else line, .col = 1 });
}

pub fn printTokens(program: *Program) void {
    // for (program.tokens.items) |token| {
    //     std.debug.print("{any}\n", .{token});
    // }
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
        } else if (token.type == .OpenParen) {
            std.debug.print("( ", .{});
        } else if (token.type == .CloseParen) {
            std.debug.print(") ", .{});
        } else if (token.type == .OpenBrace) {
            std.debug.print("{{ ", .{});
        } else if (token.type == .CloseBrace) {
            std.debug.print("}} ", .{});
        } else if (token.type == .Dot) {
            std.debug.print(". ", .{});
        } else if (token.type == .Tilde) {
            std.debug.print("~ ", .{});
        } else if (token.type == .Pipe) {
            std.debug.print("| ", .{});
        } else if (token.type == .Ampersand) {
            std.debug.print("& ", .{});
        } else if (token.type == .Hat) {
            std.debug.print("^ ", .{});
        } else if (token.type == .LessThan2) {
            std.debug.print("<< ", .{});
        } else if (token.type == .MoreThan2) {
            std.debug.print(">> ", .{});
        } else if (token.type == .Percent) {
            std.debug.print("% ", .{});
        } else if (token.type == .Slash) {
            std.debug.print("/ ", .{});
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
            std.debug.print("\x1b[94m{s}\x1b[0m ", .{utils.stringValue(token.val_ind)});
        } else {
            std.debug.print("{t} ", .{token.type});
        }
    }
    std.debug.print("\n", .{});
}

const SortedKeywords = struct {
    kvs: *const KVs = undefined,
    lens: [16]u16 = @splat(std.math.maxInt(u16)),
    min_len: u16 = std.math.maxInt(u16),
    max_len: u16 = 0,

    const Self = @This();
    const KVs = struct {
        keys: [*]const []const u8 = &[0][]const u8{},
        values: [*]const TokenType = &[0]TokenType{},
        len: u32 = 0,
    };
    const KV = struct { []const u8, TokenType };

    /// Assumes that pairs are sorted by length and then alphabetically
    pub inline fn init(comptime pairs: []const KV) Self {
        comptime {
            var self = Self{};
            var keys: [pairs.len][]const u8 = undefined;
            var values: [pairs.len]TokenType = undefined;
            var len: u16 = 2;
            var index: u16 = 0;
            for (pairs, 0..) |pair, i| {
                if (pair.@"0".len > len) {
                    self.lens[len] = index;
                    self.min_len = @min(self.min_len, pair.@"0".len, len);
                    self.max_len = pair.@"0".len;
                    index = @as(u16, @truncate(i));
                    len = pair.@"0".len;
                }
                keys[i] = pair.@"0";
                values[i] = pair.@"1";
            } else {
                self.lens[len] = index;
                self.lens[len + 1] = @truncate(pairs.len);
            }
            const sorted_keys = keys;
            const sorted_values = values;
            self.kvs = &.{
                .keys = &sorted_keys,
                .values = &sorted_values,
                .len = @truncate(pairs.len),
            };
            return self;
        }
    }

    pub fn get(self: *const Self, key: []const u8) ?TokenType {
        if (key.len < self.min_len or key.len > self.max_len) return null;
        const lower = self.lens[key.len];
        const upper = self.lens[key.len + 1];
        const index = std.sort.binarySearch([]const u8, self.kvs.keys[lower..upper], key, orderKey);
        if (index) |ind| {
            return self.kvs.values[lower + ind];
        }
        return null;
    }

    /// Assumes context and item have the same length
    fn orderKey(context: []const u8, item: []const u8) std.math.Order {
        for (context, item) |a, b| {
            if (a < b) {
                return .lt;
            } else if (a > b) {
                return .gt;
            }
        }
        return .eq;
    }
};
