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
    .{ "p128", TokenType.p128 },
    .{ "syscall", TokenType.syscall },
    .{ "dec", TokenType.dec },
    .{ "div", TokenType.div },
    .{ "idiv", TokenType.idiv },
    .{ "inc", TokenType.inc },
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
    .{ "mul", TokenType.mul },
    .{ "neg", TokenType.neg },
    .{ "not", TokenType.not },
    .{ "pop", TokenType.pop },
    .{ "push", TokenType.push },
    .{ "call", TokenType.call },
    .{ "adc", TokenType.adc },
    .{ "add", TokenType.add },
    .{ "and", TokenType.@"and" },
    .{ "cmp", TokenType.cmp },
    .{ "lea", TokenType.lea },
    .{ "mov", TokenType.mov },
    .{ "movzx", TokenType.movzx },
    .{ "or", TokenType.@"or" },
    .{ "rcl", TokenType.rcl },
    .{ "rcr", TokenType.rcr },
    .{ "rol", TokenType.rol },
    .{ "ror", TokenType.ror },
    .{ "sal", TokenType.sal },
    .{ "sar", TokenType.sar },
    .{ "sbb", TokenType.sbb },
    .{ "shl", TokenType.shl },
    .{ "shr", TokenType.shr },
    .{ "sub", TokenType.sub },
    .{ "test", TokenType.@"test" },
    .{ "xor", TokenType.xor },
    .{ "ret", TokenType.ret },
    .{ "imul", TokenType.imul },
    .{ "movups", TokenType.movups },
    .{ "movhlps", TokenType.movhlps },
    .{ "movlps", TokenType.movlps },
    .{ "unpcklps", TokenType.unpcklps },
    .{ "unpckhps", TokenType.unpckhps },
    .{ "movlhps", TokenType.movlhps },
    .{ "movhps", TokenType.movhps },
    .{ "movaps", TokenType.movaps },
    .{ "cvtpi2ps", TokenType.cvtpi2ps },
    .{ "movntps", TokenType.movntps },
    .{ "ucomiss", TokenType.ucomiss },
    .{ "comiss", TokenType.comiss },
    .{ "movmskps", TokenType.movmskps },
    .{ "sqrtps", TokenType.sqrtps },
    .{ "rsqrtps", TokenType.rsqrtps },
    .{ "rcpps", TokenType.rcpps },
    .{ "andps", TokenType.andps },
    .{ "andnps", TokenType.andnps },
    .{ "orps", TokenType.orps },
    .{ "xorps", TokenType.xorps },
    .{ "addps", TokenType.addps },
    .{ "mulps", TokenType.mulps },
    .{ "cvtps2pd", TokenType.cvtps2pd },
    .{ "cvtdq2ps", TokenType.cvtdq2ps },
    .{ "subps", TokenType.subps },
    .{ "minps", TokenType.minps },
    .{ "divps", TokenType.divps },
    .{ "maxps", TokenType.maxps },
    .{ "movnti", TokenType.movnti },
    .{ "cmpps", TokenType.cmpps },
    .{ "shufps", TokenType.shufps },
    .{ "movupd", TokenType.movupd },
    .{ "movlpd", TokenType.movlpd },
    .{ "unpcklpd", TokenType.unpcklpd },
    .{ "unpckhpd", TokenType.unpckhpd },
    .{ "movhpd", TokenType.movhpd },
    .{ "movapd", TokenType.movapd },
    .{ "cvtpi2pd", TokenType.cvtpi2pd },
    .{ "movntpd", TokenType.movntpd },
    .{ "ucomisd", TokenType.ucomisd },
    .{ "comisd", TokenType.comisd },
    .{ "movmskpd", TokenType.movmskpd },
    .{ "sqrtpd", TokenType.sqrtpd },
    .{ "andpd", TokenType.andpd },
    .{ "andnpd", TokenType.andnpd },
    .{ "orpd", TokenType.orpd },
    .{ "xorpd", TokenType.xorpd },
    .{ "addpd", TokenType.addpd },
    .{ "mulpd", TokenType.mulpd },
    .{ "cvtpd2ps", TokenType.cvtpd2ps },
    .{ "cvtps2dq", TokenType.cvtps2dq },
    .{ "subpd", TokenType.subpd },
    .{ "minpd", TokenType.minpd },
    .{ "divpd", TokenType.divpd },
    .{ "maxpd", TokenType.maxpd },
    .{ "punpcklbw", TokenType.punpcklbw },
    .{ "punpcklwd", TokenType.punpcklwd },
    .{ "punpckldq", TokenType.punpckldq },
    .{ "packsswb", TokenType.packsswb },
    .{ "pcmpgtb", TokenType.pcmpgtb },
    .{ "pcmpgtw", TokenType.pcmpgtw },
    .{ "pcmpgtd", TokenType.pcmpgtd },
    .{ "packuswb", TokenType.packuswb },
    .{ "punpckhbw", TokenType.punpckhbw },
    .{ "punpckhwd", TokenType.punpckhwd },
    .{ "punpckhdq", TokenType.punpckhdq },
    .{ "packssdw", TokenType.packssdw },
    .{ "punpcklqdq", TokenType.punpcklqdq },
    .{ "punpckhqdq", TokenType.punpckhqdq },
    .{ "movd", TokenType.movd },
    .{ "movdqa", TokenType.movdqa },
    .{ "pcmpeqb", TokenType.pcmpeqb },
    .{ "pcmpeqw", TokenType.pcmpeqw },
    .{ "pcmpeqd", TokenType.pcmpeqd },
    .{ "haddpd", TokenType.haddpd },
    .{ "hsubpd", TokenType.hsubpd },
    .{ "psrldq", TokenType.psrldq },
    .{ "pslldq", TokenType.pslldq },
    .{ "addsubpd", TokenType.addsubpd },
    .{ "psrlw", TokenType.psrlw },
    .{ "psrld", TokenType.psrld },
    .{ "psrlq", TokenType.psrlq },
    .{ "paddq", TokenType.paddq },
    .{ "pmullw", TokenType.pmullw },
    .{ "movq", TokenType.movq },
    .{ "pmovmskb", TokenType.pmovmskb },
    .{ "psubusb", TokenType.psubusb },
    .{ "psubusw", TokenType.psubusw },
    .{ "pminub", TokenType.pminub },
    .{ "pand", TokenType.pand },
    .{ "paddusb", TokenType.paddusb },
    .{ "paddusw", TokenType.paddusw },
    .{ "pmaxub", TokenType.pmaxub },
    .{ "pandn", TokenType.pandn },
    .{ "pavgb", TokenType.pavgb },
    .{ "psraw", TokenType.psraw },
    .{ "psrad", TokenType.psrad },
    .{ "pavgw", TokenType.pavgw },
    .{ "pmulhuw", TokenType.pmulhuw },
    .{ "pmulhw", TokenType.pmulhw },
    .{ "cvttpd2dq", TokenType.cvttpd2dq },
    .{ "movntdq", TokenType.movntdq },
    .{ "psubsb", TokenType.psubsb },
    .{ "psubsw", TokenType.psubsw },
    .{ "pminsw", TokenType.pminsw },
    .{ "por", TokenType.por },
    .{ "paddsb", TokenType.paddsb },
    .{ "paddsw", TokenType.paddsw },
    .{ "pmaxsw", TokenType.pmaxsw },
    .{ "pxor", TokenType.pxor },
    .{ "psllw", TokenType.psllw },
    .{ "pslld", TokenType.pslld },
    .{ "psllq", TokenType.psllq },
    .{ "pmuludq", TokenType.pmuludq },
    .{ "pmaddwd", TokenType.pmaddwd },
    .{ "psadbw", TokenType.psadbw },
    .{ "maskmovdqu", TokenType.maskmovdqu },
    .{ "psubb", TokenType.psubb },
    .{ "psubw", TokenType.psubw },
    .{ "psubd", TokenType.psubd },
    .{ "psubq", TokenType.psubq },
    .{ "paddb", TokenType.paddb },
    .{ "paddw", TokenType.paddw },
    .{ "paddd", TokenType.paddd },
    .{ "pshufd", TokenType.pshufd },
    .{ "cmppd", TokenType.cmppd },
    .{ "pinsrw", TokenType.pinsrw },
    .{ "pextrw", TokenType.pextrw },
    .{ "shufpd", TokenType.shufpd },
    .{ "movss", TokenType.movss },
    .{ "movsldup", TokenType.movsldup },
    .{ "movshdup", TokenType.movshdup },
    .{ "cvtsi2ss", TokenType.cvtsi2ss },
    .{ "movntss", TokenType.movntss },
    .{ "cvttss2si", TokenType.cvttss2si },
    .{ "cvtss2si", TokenType.cvtss2si },
    .{ "sqrtss", TokenType.sqrtss },
    .{ "rsqrtss", TokenType.rsqrtss },
    .{ "rcpss", TokenType.rcpss },
    .{ "addss", TokenType.addss },
    .{ "mulss", TokenType.mulss },
    .{ "cvtss2sd", TokenType.cvtss2sd },
    .{ "cvttps2dq", TokenType.cvttps2dq },
    .{ "subss", TokenType.subss },
    .{ "minss", TokenType.minss },
    .{ "divss", TokenType.divss },
    .{ "maxss", TokenType.maxss },
    .{ "movdqu", TokenType.movdqu },
    .{ "cvtdq2pd", TokenType.cvtdq2pd },
    .{ "pshufhw", TokenType.pshufhw },
    .{ "cmpss", TokenType.cmpss },
    .{ "movsd", TokenType.movsd },
    .{ "movddup", TokenType.movddup },
    .{ "cvtsi2sd", TokenType.cvtsi2sd },
    .{ "movntsd", TokenType.movntsd },
    .{ "cvttsd2si", TokenType.cvttsd2si },
    .{ "cvtsd2si", TokenType.cvtsd2si },
    .{ "sqrtsd", TokenType.sqrtsd },
    .{ "addsd", TokenType.addsd },
    .{ "mulsd", TokenType.mulsd },
    .{ "cvtsd2ss", TokenType.cvtsd2ss },
    .{ "subsd", TokenType.subsd },
    .{ "minsd", TokenType.minsd },
    .{ "divsd", TokenType.divsd },
    .{ "maxsd", TokenType.maxsd },
    .{ "haddps", TokenType.haddps },
    .{ "hsubps", TokenType.hsubps },
    .{ "addsubps", TokenType.addsubps },
    .{ "cvtpd2dq", TokenType.cvtpd2dq },
    .{ "lddqu", TokenType.lddqu },
    .{ "pshuflw", TokenType.pshuflw },
    .{ "cmpsd", TokenType.cmpsd },
    .{ "pshufb", TokenType.pshufb },
    .{ "phaddw", TokenType.phaddw },
    .{ "phaddd", TokenType.phaddd },
    .{ "phaddsw", TokenType.phaddsw },
    .{ "pmaddubsw", TokenType.pmaddubsw },
    .{ "phsubw", TokenType.phsubw },
    .{ "phsubd", TokenType.phsubd },
    .{ "phsubsw", TokenType.phsubsw },
    .{ "psignb", TokenType.psignb },
    .{ "psignw", TokenType.psignw },
    .{ "psignd", TokenType.psignd },
    .{ "pmulhrsw", TokenType.pmulhrsw },
    .{ "pblendvb", TokenType.pblendvb },
    .{ "blendvps", TokenType.blendvps },
    .{ "blendvpd", TokenType.blendvpd },
    .{ "ptest", TokenType.ptest },
    .{ "pabsb", TokenType.pabsb },
    .{ "pabsw", TokenType.pabsw },
    .{ "pabsd", TokenType.pabsd },
    .{ "pmovsxbw", TokenType.pmovsxbw },
    .{ "pmovsxbd", TokenType.pmovsxbd },
    .{ "pmovsxbq", TokenType.pmovsxbq },
    .{ "pmovsxwd", TokenType.pmovsxwd },
    .{ "pmovsxwq", TokenType.pmovsxwq },
    .{ "pmovsxdq", TokenType.pmovsxdq },
    .{ "pmuldq", TokenType.pmuldq },
    .{ "pcmpeqq", TokenType.pcmpeqq },
    .{ "movntdqa", TokenType.movntdqa },
    .{ "packusdw", TokenType.packusdw },
    .{ "pmovzxbw", TokenType.pmovzxbw },
    .{ "pmovzxbd", TokenType.pmovzxbd },
    .{ "pmovzxbq", TokenType.pmovzxbq },
    .{ "pmovzxwd", TokenType.pmovzxwd },
    .{ "pmovzxwq", TokenType.pmovzxwq },
    .{ "pmovzxdq", TokenType.pmovzxdq },
    .{ "pcmpgtq", TokenType.pcmpgtq },
    .{ "pminsb", TokenType.pminsb },
    .{ "pminsd", TokenType.pminsd },
    .{ "pminuw", TokenType.pminuw },
    .{ "pminud", TokenType.pminud },
    .{ "pmaxsb", TokenType.pmaxsb },
    .{ "pmaxsd", TokenType.pmaxsd },
    .{ "pmaxuw", TokenType.pmaxuw },
    .{ "pmaxud", TokenType.pmaxud },
    .{ "pmulld", TokenType.pmulld },
    .{ "phminposuw", TokenType.phminposuw },
    .{ "roundps", TokenType.roundps },
    .{ "roundpd", TokenType.roundpd },
    .{ "roundss", TokenType.roundss },
    .{ "roundsd", TokenType.roundsd },
    .{ "blendps", TokenType.blendps },
    .{ "blendpd", TokenType.blendpd },
    .{ "pblendw", TokenType.pblendw },
    .{ "palignr", TokenType.palignr },
    .{ "pextrb", TokenType.pextrb },
    .{ "pextrq", TokenType.pextrq },
    .{ "pextrd", TokenType.pextrd },
    .{ "extractps", TokenType.extractps },
    .{ "pinsrb", TokenType.pinsrb },
    .{ "insertps", TokenType.insertps },
    .{ "pinsrd", TokenType.pinsrd },
    .{ "pinsrq", TokenType.pinsrq },
    .{ "dpps", TokenType.dpps },
    .{ "dppd", TokenType.dppd },
    .{ "mpsadbw", TokenType.mpsadbw },
    .{ "pclmulqdq", TokenType.pclmulqdq },
    .{ "pcmpestrm", TokenType.pcmpestrm },
    .{ "pcmpestri", TokenType.pcmpestri },
    .{ "pcmpistrm", TokenType.pcmpistrm },
    .{ "pcmpistri", TokenType.pcmpistri },
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
