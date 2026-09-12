pub const TokenType = enum(u16) {
    //  Instruction mnemonics

    //x86-64 original and other
    syscall = initInstr(0, 0, 0, 0),
    dec = initInstr(0, 0, 1, 0),
    div,
    idiv,
    inc,
    ja,
    jae,
    jb,
    jbe,
    jc,
    je,
    jg,
    jge,
    jl,
    jle,
    jna,
    jnae,
    jnb,
    jnbe,
    jnc,
    jne,
    jng,
    jnge,
    jnl,
    jnle,
    jno,
    jnp,
    jns,
    jnz,
    jo,
    jp,
    jpe,
    jpo,
    js,
    jz,
    jmp,
    mul,
    neg,
    not,
    pop,
    push,
    call,
    adc = initInstr(0, 0, 2, 0),
    add,
    @"and",
    cmp,
    lea,
    mov,
    movzx,
    @"or",
    rcl,
    rcr,
    rol,
    ror,
    sal,
    sar,
    sbb,
    shl,
    shr,
    sub,
    @"test",
    xor,
    ret = initInstr(0, 0, 4, 0),
    imul = initInstr(0, 0, 5, 0),

    //   SSE_

    // NP 0F <opcode> op1, op2
    movups = initInstr(1, 0, 2, 0x10),
    movhlps = initInstr(1, 0, 2, 0x12),
    movlps, // 0x13, but 0x12 and 0x13 actually
    unpcklps, // 0x14
    unpckhps, // 0x15
    movlhps, // 0x16
    movhps, // 0x17, but 0x16 and 0x17 actually
    movaps = initInstr(1, 0, 2, 0x28),
    cvtpi2ps = initInstr(1, 0, 2, 0x2A),
    movntps, // 0x2B
    ucomiss = initInstr(1, 0, 2, 0x2E),
    comiss, // 0x2F
    movmskps = initInstr(1, 0, 2, 0x50),
    sqrtps,
    rsqrtps,
    rcpps,
    andps,
    andnps,
    orps,
    xorps,
    addps,
    mulps,
    cvtps2pd,
    cvtdq2ps,
    subps,
    minps,
    divps,
    maxps,
    movnti = initInstr(1, 0, 2, 0xC3),

    // NP 0F <opcode> op1, op2, imm8
    cmpps = initInstr(1, 0, 3, 0xC2),
    shufps = initInstr(1, 0, 3, 0xC6),

    // 66 0F <opcode> op1, op2
    movupd = initInstr(1, 1, 2, 0x10),
    movlpd = initInstr(1, 1, 2, 0x12),
    unpcklpd = initInstr(1, 1, 2, 0x14),
    unpckhpd,
    movhpd, // 0x16
    movapd = initInstr(1, 1, 2, 0x28),
    cvtpi2pd = initInstr(1, 1, 2, 0x2A),
    movntpd, // 0x2B
    ucomisd = initInstr(1, 1, 2, 0x2E),
    comisd, // 0x2F
    movmskpd = initInstr(1, 1, 2, 0x50),
    sqrtpd,
    andpd = initInstr(1, 1, 2, 0x54),
    andnpd,
    orpd,
    xorpd,
    addpd,
    mulpd,
    cvtpd2ps,
    cvtps2dq,
    subpd,
    minpd,
    divpd,
    maxpd,
    punpcklbw,
    punpcklwd,
    punpckldq,
    packsswb,
    pcmpgtb,
    pcmpgtw,
    pcmpgtd,
    packuswb,
    punpckhbw,
    punpckhwd,
    punpckhdq,
    packssdw,
    punpcklqdq,
    punpckhqdq,
    movd,
    movdqa, // 0x6F
    pcmpeqb = initInstr(1, 1, 2, 0x74),
    pcmpeqw,
    pcmpeqd, // 0x76
    haddpd = initInstr(1, 1, 2, 0x7C),
    hsubpd,
    psrldq, // 0x7E, but 0x73 actually
    pslldq, // 0x7F, but 0x73 actually
    addsubpd = initInstr(1, 1, 2, 0xD0),
    psrlw,
    psrld,
    psrlq,
    paddq,
    pmullw,
    movq,
    pmovmskb,
    psubusb,
    psubusw,
    pminub,
    pand,
    paddusb,
    paddusw,
    pmaxub,
    pandn,
    pavgb,
    psraw,
    psrad,
    pavgw,
    pmulhuw,
    pmulhw,
    cvttpd2dq,
    movntdq,
    psubsb,
    psubsw,
    pminsw,
    por,
    paddsb,
    paddsw,
    pmaxsw,
    pxor, // 0xEF
    psllw = initInstr(1, 1, 2, 0xF1),
    pslld,
    psllq,
    pmuludq,
    pmaddwd,
    psadbw,
    maskmovdqu,
    psubb,
    psubw,
    psubd,
    psubq,
    paddb,
    paddw,
    paddd,

    // 66 0F <opcode> op1, op2, imm8
    pshufd = initInstr(1, 1, 3, 0x70),
    cmppd = initInstr(1, 1, 3, 0xC2),
    pinsrw = initInstr(1, 1, 3, 0xC4),
    shufpd,

    // F3 0F <opcode> op1, op2
    movss = initInstr(1, 2, 2, 0x10),
    movsldup = initInstr(1, 2, 2, 0x12),
    movshdup = initInstr(1, 2, 2, 0x16),
    cvtsi2ss = initInstr(1, 2, 2, 0x2A),
    movntss, // ???
    cvttss2si,
    cvtss2si, // 0x2D
    sqrtss = initInstr(1, 2, 2, 0x51),
    rsqrtss,
    rcpss, // 0x53
    addss = initInstr(1, 2, 2, 0x58),
    mulss,
    cvtss2sd,
    cvttps2dq,
    subss,
    minss,
    divss,
    maxss, // 0x5F
    movdqu = initInstr(1, 2, 2, 0x6F),
    cvtdq2pd = initInstr(1, 2, 2, 0xE6),

    // F3 0F <opcode> op1, op2, imm8
    pshufhw = initInstr(1, 2, 3, 0x70),
    cmpss = initInstr(1, 2, 3, 0xC2),

    // F2 0F <opcode> op1, op2
    movsd = initInstr(1, 3, 2, 0x10),
    movddup = initInstr(1, 3, 2, 0x12),
    cvtsi2sd = initInstr(1, 3, 2, 0x2A),
    movntsd,
    cvttsd2si,
    cvtsd2si, // 0x2D
    sqrtsd = initInstr(1, 3, 2, 0x51),
    addsd = initInstr(1, 3, 2, 0x58),
    mulsd,
    cvtsd2ss, // 0x5A
    subsd = initInstr(1, 3, 2, 0x5C),
    minsd,
    divsd,
    maxsd, // 0x5F
    haddps = initInstr(1, 3, 2, 0x7C),
    hsubps, // 0x7D
    addsubps = initInstr(1, 3, 2, 0xD0),
    cvtpd2dq = initInstr(1, 3, 2, 0xE6),
    lddqu = initInstr(1, 3, 2, 0xF0),

    // F2 0F <opcode> op1, op2, imm8
    pshuflw = initInstr(1, 3, 3, 0x70),
    cmpsd = initInstr(1, 3, 3, 0xC2),

    // 66 0F 38 <opcode> op1, op2
    pshufb = initInstr(2, 1, 2, 0x00),
    phaddw,
    phaddd,
    phaddsw,
    pmaddubsw,
    phsubw,
    phsubd,
    phsubsw,
    psignb,
    psignw,
    psignd,
    pmulhrsw, // 0x0B
    pblendvb = initInstr(2, 1, 2, 0x10),
    blendvps = initInstr(2, 1, 2, 0x14),
    blendvpd, // 0x15
    ptest = initInstr(2, 1, 2, 0x17),
    pabsb = initInstr(2, 1, 2, 0x1C),
    pabsw,
    pabsd, // 0x1E
    pmovsxbw = initInstr(2, 1, 2, 0x20),
    pmovsxbd,
    pmovsxbq,
    pmovsxwd,
    pmovsxwq,
    pmovsxdq, // 0x25
    pmuldq = initInstr(2, 1, 2, 0x28),
    pcmpeqq,
    movntdqa,
    packusdw, // 0x2B
    pmovzxbw = initInstr(2, 1, 2, 0x30),
    pmovzxbd,
    pmovzxbq,
    pmovzxwd,
    pmovzxwq,
    pmovzxdq, // 0x35
    pcmpgtq = initInstr(2, 1, 2, 0x37),
    pminsb,
    pminsd,
    pminuw,
    pminud,
    pmaxsb,
    pmaxsd,
    pmaxuw,
    pmaxud,
    pmulld,
    phminposuw,

    // 66 0F 3A <opcode> op1, op2, imm8
    roundps = initInstr(3, 1, 3, 0x08),
    roundpd,
    roundss,
    roundsd,
    blendps,
    blendpd,
    pblendw,
    palignr, // 0x0F
    pextrq = initInstr(3, 1, 3, 0x13), // 0x13, but actually 0x16
    pextrb,
    pextrw,
    pextrd,
    extractps, // 0x17
    pinsrb = initInstr(3, 1, 3, 0x20),
    insertps,
    pinsrd,
    pinsrq, // 0x23, but actually 0x22
    dpps = initInstr(3, 1, 3, 0x40),
    dppd,
    mpsadbw, // 0x42
    pclmulqdq = initInstr(3, 1, 3, 0x44),
    pcmpestrm = initInstr(3, 1, 3, 0x60),
    pcmpestri,
    pcmpistrm,
    pcmpistri,

    //  Registers
    reg0 = initReg(0, 0, 0),
    //128-bit
    xmm0 = initReg(0, 0, 16),
    xmm1 = initReg(1, 0, 16),
    xmm2 = initReg(2, 0, 16),
    xmm3 = initReg(3, 0, 16),
    xmm4 = initReg(4, 0, 16),
    xmm5 = initReg(5, 0, 16),
    xmm6 = initReg(6, 0, 16),
    xmm7 = initReg(7, 0, 16),
    xmm8 = initReg(0, 4, 16),
    xmm9 = initReg(1, 4, 16),
    xmm10 = initReg(2, 4, 16),
    xmm11 = initReg(3, 4, 16),
    xmm12 = initReg(4, 4, 16),
    xmm13 = initReg(5, 4, 16),
    xmm14 = initReg(6, 4, 16),
    xmm15 = initReg(7, 4, 16),
    //64-bit
    rax = initReg(0, 1, 8),
    rbx = initReg(3, 0, 8),
    rcx = initReg(1, 0, 8),
    rdx = initReg(2, 0, 8),
    rdi = initReg(7, 0, 8),
    rsi = initReg(6, 0, 8),
    rsp = initReg(4, 0, 8),
    rbp = initReg(5, 0, 8),
    rip = initReg(0, 0, 8),
    r8 = initReg(0, 4, 8),
    r9 = initReg(1, 4, 8),
    r10 = initReg(2, 4, 8),
    r11 = initReg(3, 4, 8),
    r12 = initReg(4, 4, 8),
    r13 = initReg(5, 4, 8),
    r14 = initReg(6, 4, 8),
    r15 = initReg(7, 4, 8),
    //32-bit
    eax = initReg(0, 1, 4),
    ebx = initReg(3, 0, 4),
    ecx = initReg(1, 0, 4),
    edx = initReg(2, 0, 4),
    edi = initReg(7, 0, 4),
    esi = initReg(6, 0, 4),
    esp = initReg(4, 0, 4),
    ebp = initReg(5, 0, 4),
    r8d = initReg(0, 4, 4),
    r9d = initReg(1, 4, 4),
    r10d = initReg(2, 4, 4),
    r11d = initReg(3, 4, 4),
    r12d = initReg(4, 4, 4),
    r13d = initReg(5, 4, 4),
    r14d = initReg(6, 4, 4),
    r15d = initReg(7, 4, 4),
    //16-bit
    ax = initReg(0, 1, 2),
    bx = initReg(3, 0, 2),
    cx = initReg(1, 0, 2),
    dx = initReg(2, 0, 2),
    di = initReg(7, 0, 2),
    si = initReg(6, 0, 2),
    sp = initReg(4, 0, 2),
    bp = initReg(5, 0, 2),
    r8w = initReg(0, 4, 2),
    r9w = initReg(1, 4, 2),
    r10w = initReg(2, 4, 2),
    r11w = initReg(3, 4, 2),
    r12w = initReg(4, 4, 2),
    r13w = initReg(5, 4, 2),
    r14w = initReg(6, 4, 2),
    r15w = initReg(7, 4, 2),
    //8-bit
    ah = initReg(4, 2, 1),
    al = initReg(0, 1, 1),
    bh = initReg(7, 2, 1),
    bl = initReg(3, 0, 1),
    ch = initReg(5, 2, 1),
    cl = initReg(1, 0, 1),
    dh = initReg(6, 2, 1),
    dl = initReg(2, 0, 1),
    sil = initReg(6, 3, 1),
    dil = initReg(7, 3, 1),
    bpl = initReg(5, 3, 1),
    spl = initReg(4, 3, 1),
    r8b = initReg(0, 4, 1),
    r9b = initReg(1, 4, 1),
    r10b = initReg(2, 4, 1),
    r11b = initReg(3, 4, 1),
    r12b = initReg(4, 4, 1),
    r13b = initReg(5, 4, 1),
    r14b = initReg(6, 4, 1),
    r15b = initReg(7, 4, 1),

    //Keywords
    entry = 0b1100000000000000,
    data,
    code,
    import,
    bss,
    repeat,
    d8,
    d16,
    d32,
    d64,
    p8,
    p16,
    p32,
    p64,
    p128,

    //Literals
    Ident,
    HashIdent,
    DotIdent,
    StringLiteral,
    NumberLiteral,
    HexNumLiteral,
    BinNumLiteral,

    //Punctuation
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
    Eof,

    pub fn isReg(self: TokenType) bool {
        return @intFromEnum(self) >> 14 == 0b10;
    }

    pub fn isAdditionalReg(self: TokenType) bool {
        return @intFromEnum(self) & 0x700 == 0x400;
    }

    pub fn isByteRegAdditional(self: TokenType) bool {
        return @intFromEnum(self) & 0x700 == 0x300;
    }

    pub fn isByteRegHigh(self: TokenType) bool {
        return @intFromEnum(self) & 0x700 == 0x200;
    }

    pub fn isAccumulator(self: TokenType) bool {
        return @intFromEnum(self) & 0x700 == 0x100;
    }

    pub fn isMnemonic(self: TokenType) bool {
        return @intFromEnum(self) < 0x8000;
    }

    pub fn isPointerSize(self: TokenType) bool {
        const lower = @intFromEnum(TokenType.p8);
        const upper = @intFromEnum(TokenType.p128);
        const p = @intFromEnum(self);
        if (p >= lower and p <= upper) {
            return true;
        } else {
            return false;
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

fn initReg(comptime digit: u3, comptime group: u3, comptime size: u8) comptime_int {
    comptime {
        var reg: u16 = 0b10 << 14;
        reg |= @as(u16, digit) << 11;
        reg |= @as(u16, group) << 8;
        reg |= size;
        return reg;
    }
}

fn initInstr(comptime opclen: u2, comptime pref: u2, comptime opcount: u3, comptime opcode: u8) comptime_int {
    comptime {
        const mnemtype = packed struct(u16) {
            opcode: u8,
            opcount: u3,
            pref: u2,
            opclen: u2,
            _bit: u1 = 0,
        };
        return @as(u16, @bitCast(mnemtype{ .opclen = opclen, .pref = pref, .opcount = opcount, .opcode = opcode }));
    }
}
