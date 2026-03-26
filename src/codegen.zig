const std = @import("std");
const lexer = @import("lexer");
const parser = @import("parser");

fn regCode(reg: lexer.TokenType) u3 {
    switch (reg) {
        .Rax, .Eax, .Ax, .Al, .R8, .R8d, .R8w, .R8b => {
            return 0b000;
        },
        .Rcx, .Ecx, .Cx, .Cl, .R9, .R9d, .R9w, .R9b => {
            return 0b001;
        },
        .Rdx, .Edx, .Dx, .Dl, .R10, .R10d, .R10w, .R10b => {
            return 0b010;
        },
        .Rbx, .Ebx, .Bx, .Bl, .R11, .R11d, .R11w, .R11b => {
            return 0b011;
        },
        .Rsp, .Esp, .Sp, .Ah, .R12, .R12d, .R12w, .R12b => {
            return 0b100;
        },
        .Rbp, .Ebp, .Bp, .Ch, .R13, .R13d, .R13w, .R13b => {
            return 0b101;
        },
        .Rsi, .Esi, .Si, .Dh, .R14, .R14d, .R14w, .R14b => {
            return 0b110;
        },
        .Rdi, .Edi, .Di, .Bh, .R15, .R15d, .R15w, .R15b => {
            return 0b111;
        },
        else => {
            return 0;
        },
    }
}

fn digitToReg(digit: u8) parser.Register {
    switch (digit) {
        0 => {
            return parser.Register.init(.Eax);
        },
        1 => {
            return parser.Register.init(.Ecx);
        },
        2 => {
            return parser.Register.init(.Edx);
        },
        3 => {
            return parser.Register.init(.Ebx);
        },
        4 => {
            return parser.Register.init(.Esp);
        },
        5 => {
            return parser.Register.init(.Ebp);
        },
        6 => {
            return parser.Register.init(.Esi);
        },
        7 => {
            return parser.Register.init(.Edi);
        },
        else => unreachable,
    }
}

const CodegenError = error{
    InvalidIndex,
    DiffOperSizes,
    InvalidNumberOfOperands,
    InvalidOperand,
    ImmValueIsTooLarge,
    UnspecifiedMemoryPointerSize,
    WrongMemoryPointerSize,
    WrongRegisterSize,
};

const ModRmByte = packed struct {
    rm: u3,
    reg: u3,
    mod: u2,

    pub fn byte(self: *const ModRmByte) u8 {
        return (@as(u8, self.mod) << 6) | (@as(u8, self.reg) << 3) | (self.rm);
    }

    pub fn default() ModRmByte {
        return ModRmByte{ .rm = 0b000, .reg = 0b000, .mod = 0b00 };
    }
};

const SibByte = packed struct {
    base: u3,
    index: u3,
    ss: u2,

    pub fn byte(self: *const SibByte) u8 {
        return (@as(u8, self.ss) << 6) | (@as(u8, self.index) << 3) | (self.base);
    }

    pub fn default() SibByte {
        return SibByte{ .base = 0b000, .index = 0b000, .ss = 0b00 };
    }
};

const RexByte = packed struct {
    b: bool,
    x: bool,
    r: bool,
    w: bool,
    rex: u4 = 0b0100,

    pub fn default() RexByte {
        return RexByte{ .b = false, .x = false, .r = false, .w = false };
    }

    pub fn byte(self: RexByte) u8 {
        return @bitCast(self);
    }

    pub fn setB(self: *RexByte) void {
        self.b = true;
    }
    pub fn setX(self: *RexByte) void {
        self.x = true;
    }
    pub fn setR(self: *RexByte) void {
        self.r = true;
    }
    pub fn setW(self: *RexByte) void {
        self.w = true;
    }
};

const InstrBytes = struct {
    as: bool,
    os: bool,
    rex: RexByte,
    opcode: u8,
    modrm: ?ModRmByte,
    sib: ?SibByte,
    disp: ?parser.Displacement,
    disp_bytes: u8,
    need_sib: bool,

    pub fn init() InstrBytes {
        var ib: InstrBytes = undefined;
        ib.reset();
        return ib;
    }

    pub fn reset(self: *InstrBytes) void {
        self.as = false;
        self.os = false;
        self.rex = RexByte.default();
        self.opcode = 0x00;
        self.modrm = null;
        self.sib = null;
        self.disp = null;
        self.disp_bytes = 0;
        self.need_sib = false;
    }

    pub fn plusR(self: *InstrBytes, reg: lexer.TokenType) void {
        self.opcode += regCode(reg);
    }

    pub fn setOsRexW(self: *InstrBytes, size: u8) void {
        if (size == 2) {
            self.os = true;
        } else if (size == 8) {
            self.rex.setW();
        }
    }

    fn sibByte(self: *InstrBytes, base: ?parser.Register, index: ?parser.Register, scale: ?parser.Scale) void {
        var bs: u3 = undefined;
        var ind: u3 = undefined;
        var ss: u2 = undefined;

        if (scale) |sc| {
            switch (sc.num) {
                1 => ss = 0b00,
                2 => ss = 0b01,
                4 => ss = 0b10,
                8 => ss = 0b11,
                else => unreachable,
            }
        } else {
            ss = 0b00;
        }

        if (index) |i| {
            ind = regCode(i.name);
            if (i.name.isAdditionalReg()) {
                self.rex.setX();
            }
            if (i.size == 4) {
                self.as = true;
            } else {
                self.as = false;
            }
        } else {
            ind = 0b100;
        }

        if (base) |b| {
            bs = regCode(b.name);
            if (b.name.isAdditionalReg()) {
                self.rex.setB();
            }
            if (b.size == 4) {
                self.as = true;
            } else {
                self.as = false;
            }
        } else {
            bs = 0b101;
            if (self.modrm) |modrm| {
                if (self.disp == null) {
                    switch (modrm.mod) {
                        0b00 => {
                            self.disp = parser.Displacement{ .num = 0 };
                            self.disp_bytes = 4;
                        },
                        0b01 => {
                            self.disp = parser.Displacement{ .num = 0 };
                            self.disp_bytes = 1;
                        },
                        0b10 => {
                            self.disp = parser.Displacement{ .num = 0 };
                            self.disp_bytes = 4;
                        },
                        else => {},
                    }
                }
            }
        }

        self.sib = SibByte{ .base = bs, .index = ind, .ss = ss };
    }

    fn modRM(self: *InstrBytes, reg: parser.Register, rm: parser.Operand) void {
        var mod: u2 = undefined;
        var rm_code: u3 = undefined;
        const reg_code: u3 = regCode(reg.name);
        if (reg.size == 2) {
            self.os = true;
        } else if (reg.size == 8) {
            self.rex.setW();
        }
        if (reg.name.isAdditionalReg()) {
            self.rex.setR();
        }
        switch (rm) {
            .reg => {
                mod = 0b11;
                rm_code = regCode(rm.reg.name);
                if (rm.reg.name.isAdditionalReg()) {
                    self.rex.setB();
                }
            },
            .mem => {
                switch (rm.mem.mem) {
                    .label => {
                        // RIP-relative addressing
                        mod = 0b00;
                        rm_code = 0b101;
                        self.disp = parser.Displacement{ .num = 0 };
                        self.disp_bytes = 4;
                    },
                    .addr => {
                        const disp_size: u8 = if (rm.mem.mem.addr.disp) |disp| parser.dispMinSize(disp) else 0;
                        const baseIn = if (rm.mem.mem.addr.base != null) true else false;
                        const indexIn = if (rm.mem.mem.addr.index != null) true else false;
                        const dispIn = if (disp_size == 0) false else true;
                        if (!indexIn) {
                            if (baseIn) {
                                const base_code = regCode(rm.mem.mem.addr.base.?.name);
                                if (disp_size == 0) {
                                    if (base_code == 0b101) {
                                        if (rm.mem.mem.addr.base.?.name.isAdditionalReg()) {
                                            self.rex.setB();
                                        }
                                        if (rm.mem.mem.addr.base.?.size == 4) {
                                            self.as = true;
                                        } else {
                                            self.as = false;
                                        }
                                        mod = 0b01;
                                        rm_code = base_code;
                                        self.disp = parser.Displacement{ .num = 0 };
                                        self.disp_bytes = 1;
                                        self.need_sib = false;
                                    } else if (base_code == 0b100) {
                                        mod = 0b00;
                                        rm_code = base_code;
                                        self.need_sib = true;
                                    } else {
                                        if (rm.mem.mem.addr.base.?.name.isAdditionalReg()) {
                                            self.rex.setB();
                                        }
                                        if (rm.mem.mem.addr.base.?.size == 4) {
                                            self.as = true;
                                        } else {
                                            self.as = false;
                                        }
                                        mod = 0b00;
                                        rm_code = base_code;
                                        self.need_sib = false;
                                    }
                                } else if (disp_size == 1) {
                                    if (base_code == 0b100) {
                                        mod = 0b01;
                                        rm_code = base_code;
                                        self.disp = rm.mem.mem.addr.disp;
                                        self.disp_bytes = 1;
                                        self.need_sib = true;
                                    } else {
                                        if (rm.mem.mem.addr.base.?.name.isAdditionalReg()) {
                                            self.rex.setB();
                                        }
                                        if (rm.mem.mem.addr.base.?.size == 4) {
                                            self.as = true;
                                        } else {
                                            self.as = false;
                                        }
                                        mod = 0b01;
                                        rm_code = base_code;
                                        self.disp = rm.mem.mem.addr.disp;
                                        self.disp_bytes = 1;
                                        self.need_sib = false;
                                    }
                                } else if (disp_size <= 4) {
                                    if (base_code == 0b100) {
                                        mod = 0b10;
                                        rm_code = base_code;
                                        self.disp = rm.mem.mem.addr.disp;
                                        self.disp_bytes = 4;
                                        self.need_sib = true;
                                    } else {
                                        if (rm.mem.mem.addr.base.?.name.isAdditionalReg()) {
                                            self.rex.setB();
                                        }
                                        if (rm.mem.mem.addr.base.?.size == 4) {
                                            self.as = true;
                                        } else {
                                            self.as = false;
                                        }
                                        mod = 0b10;
                                        rm_code = base_code;
                                        self.disp = rm.mem.mem.addr.disp;
                                        self.disp_bytes = 4;
                                        self.need_sib = false;
                                    }
                                } else {
                                    unreachable;
                                }
                            } else if (dispIn) {
                                // Absolute disp32 addressing
                                self.need_sib = true;
                                mod = 0b00;
                                rm_code = 0b100;
                                self.disp = rm.mem.mem.addr.disp;
                                self.disp_bytes = 4;
                            } else {
                                unreachable;
                            }
                        } else {
                            self.need_sib = true;
                            if (disp_size == 0) {
                                if (baseIn) {
                                    const base_code = regCode(rm.mem.mem.addr.base.?.name);
                                    if (base_code == 0b101) {
                                        mod = 0b01;
                                        rm_code = 0b100;
                                        self.disp = parser.Displacement{ .num = 0 };
                                        self.disp_bytes = 1;
                                    } else {
                                        mod = 0b00;
                                        rm_code = 0b100;
                                    }
                                } else {
                                    mod = 0b00;
                                    rm_code = 0b100;
                                }
                            } else if (disp_size == 1) {
                                if (baseIn) {
                                    mod = 0b01;
                                    rm_code = 0b100;
                                    self.disp = rm.mem.mem.addr.disp;
                                    self.disp_bytes = 1;
                                } else {
                                    mod = 0b00;
                                    rm_code = 0b100;
                                    self.disp = rm.mem.mem.addr.disp;
                                    self.disp_bytes = 4;
                                }
                            } else if (disp_size <= 4) {
                                if (baseIn) {
                                    mod = 0b10;
                                    rm_code = 0b100;
                                    self.disp = rm.mem.mem.addr.disp;
                                    self.disp_bytes = 4;
                                } else {
                                    mod = 0b00;
                                    rm_code = 0b100;
                                    self.disp = rm.mem.mem.addr.disp;
                                    self.disp_bytes = 4;
                                }
                            } else {
                                unreachable;
                            }
                        }
                    },
                }
            },
            else => unreachable,
        }
        self.modrm = ModRmByte{ .mod = mod, .reg = reg_code, .rm = rm_code };
    }

    fn checkAndSwapBaseIndex(self: *const InstrBytes, mem: parser.ComplexAddress) !parser.ComplexAddress {
        _ = self;
        var output = mem;
        if (mem.index) |index| {
            var with_scale = false;
            if (mem.scale) |scale| {
                if (scale.num > 1) {
                    with_scale = true;
                }
            }
            const index_code = regCode(index.name);
            if (index_code == 0b100 and !index.name.isAdditionalReg()) {
                if (!with_scale) {
                    if (mem.base) |base| {
                        const base_code = regCode(base.name);
                        if ((base_code != 0b100 or base.name.isAdditionalReg())) {
                            const temp = output.base;
                            output.base = output.index;
                            output.index = temp;
                        } else {
                            return CodegenError.InvalidIndex;
                        }
                    } else {
                        return CodegenError.InvalidIndex;
                    }
                } else {
                    return CodegenError.InvalidIndex;
                }
            }
        }
        return output;
    }

    pub fn def(self: *InstrBytes, reg: parser.Register, rm: parser.Operand, opcode: u8) !void {
        self.reset();
        self.opcode = opcode;
        var checked: parser.Operand = rm;
        switch (rm) {
            .mem => {
                switch (rm.mem.mem) {
                    .addr => {
                        checked = parser.Operand{ .mem = .{ .mem = .{ .addr = try self.checkAndSwapBaseIndex(rm.mem.mem.addr) }, .size = rm.mem.size } };
                    },
                    else => {},
                }
            },
            else => {},
        }
        self.modRM(reg, checked);
        if (self.modrm) |_| {
            if (self.need_sib) {
                self.sibByte(checked.mem.mem.addr.base, checked.mem.mem.addr.index, checked.mem.mem.addr.scale);
            }
        }
    }
};

const Codegen = struct {
    ibytes: InstrBytes,
    allocator: std.mem.Allocator,
    section: *parser.CodeSection,

    pub fn init(section: *parser.CodeSection, allocator: std.mem.Allocator) Codegen {
        return Codegen{
            .ibytes = InstrBytes.init(),
            .allocator = allocator,
            .section = section,
        };
    }
    pub fn addToBuffer(self: *Codegen) !void {
        if (self.ibytes.as) {
            try self.section.buffer.append(self.allocator, 0x67);
        }
        if (self.ibytes.os) {
            try self.section.buffer.append(self.allocator, 0x66);
        }
        if (self.ibytes.rex.byte() > 0x40) {
            try self.section.buffer.append(self.allocator, self.ibytes.rex.byte());
        }
        try self.section.buffer.append(self.allocator, self.ibytes.opcode);
        if (self.ibytes.modrm) |modrm| {
            try self.section.buffer.append(self.allocator, modrm.byte());
        }
        if (self.ibytes.sib) |sib| {
            try self.section.buffer.append(self.allocator, sib.byte());
        }
        if (self.ibytes.disp) |disp| {
            try self.addDisplacement(disp, self.ibytes.disp_bytes);
        }
    }

    pub fn addImmediate(self: *Codegen, imm: parser.Immediate, bytes: u8) !void {
        const value: u64 = switch (imm) {
            .i => @bitCast(imm.i),
            .u => imm.u,
        };
        try self.section.buffer.append(self.allocator, @as(u8, @truncate(value)));
        if (bytes > 1) {
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 8)));
        }
        if (bytes > 2) {
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 16)));
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 24)));
        }
        if (bytes > 4) {
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 32)));
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 40)));
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 48)));
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 56)));
        }
    }

    pub fn addDisplacement(self: *Codegen, disp: parser.Displacement, bytes: u8) !void {
        const value: u32 = @bitCast(disp.num);
        try self.section.buffer.append(self.allocator, @as(u8, @truncate(value)));
        if (bytes > 1) {
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 8)));
        }
        if (bytes > 2) {
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 16)));
            try self.section.buffer.append(self.allocator, @as(u8, @truncate(value >> 24)));
        }
    }

    pub fn addRelocation(self: *Codegen, label: []u8, l_type: parser.RelType, till_next_instr: u8) !void {
        const rel_size: u8 = switch (l_type) {
            .Rel32D, .Rel32C, .Abs32D => 4,
            .Abs64D => 8,
        };
        const offset = self.section.buffer.items.len - rel_size;
        const addend = switch (l_type) {
            .Rel32D, .Rel32C => -@as(i32, (till_next_instr + rel_size)),
            .Abs32D, .Abs64D => 0,
        };
        const relocation = parser.Relocation{
            .type = l_type,
            .name = label,
            .offset = offset,
            .addend = addend,
        };
        try self.section.relocations.append(self.allocator, relocation);
    }
};

var gen: Codegen = undefined;

fn memEncoding(rmop: parser.Operand, opcode: u8, digit: u8, sizes_mask: u4, discard_rexw: bool) !void {
    var rm_size: u8 = undefined;
    switch (rmop) {
        .mem => {
            if (rmop.mem.size) |size| {
                rm_size = size;
            } else {
                return CodegenError.UnspecifiedMemoryPointerSize;
            }
        },
        .reg => {
            rm_size = rmop.reg.size;
        },
        else => unreachable,
    }

    if (rm_size & sizes_mask == rm_size) {
        const reg = digitToReg(digit);
        try gen.ibytes.def(reg, rmop, opcode);
        gen.ibytes.setOsRexW(rm_size);
        if (discard_rexw) {
            gen.ibytes.rex.w = false;
        }
        switch (rmop) {
            .mem => {
                switch (rmop.mem.mem) {
                    .addr => {
                        try gen.addToBuffer();
                    },
                    .label => {
                        try gen.addToBuffer();
                        try gen.addRelocation(rmop.mem.mem.label, .Rel32D, 0);
                    },
                }
            },
            .reg => {
                try gen.addToBuffer();
            },
            else => unreachable,
        }
    } else {
        return CodegenError.WrongMemoryPointerSize;
    }
}

fn memRegEncoding(rmop: parser.Operand, regop: parser.Register, opcode: u8) !void {
    const reg_size = regop.size;
    var rm_size: u8 = undefined;
    switch (rmop) {
        .reg => rm_size = rmop.reg.size,
        .mem => rm_size = rmop.mem.size orelse reg_size,
        else => return CodegenError.InvalidOperand,
    }
    if (rm_size == reg_size) {
        try gen.ibytes.def(regop, rmop, opcode);
        switch (rmop) {
            .reg => {
                try gen.addToBuffer();
            },
            .mem => {
                switch (rmop.mem.mem) {
                    .addr => {
                        try gen.addToBuffer();
                    },
                    .label => {
                        try gen.addToBuffer();
                        try gen.addRelocation(rmop.mem.mem.label, .Rel32D, 0);
                    },
                }
            },
            else => unreachable,
        }
    } else {
        return CodegenError.DiffOperSizes;
    }
}

fn regMemEncoding(regop: parser.Register, rmop: parser.Operand, opcode: u8, sizes_mask: u4) !void {
    const reg_size = regop.size;
    var rm_size: u8 = undefined;
    switch (rmop) {
        .reg => rm_size = rmop.reg.size,
        .mem => rm_size = rmop.mem.size orelse reg_size,
        else => return CodegenError.InvalidOperand,
    }
    if (rm_size == reg_size) {
        if (rm_size & sizes_mask == rm_size) {
            try gen.ibytes.def(regop, rmop, opcode);
            switch (rmop) {
                .reg => {
                    try gen.addToBuffer();
                },
                .mem => {
                    switch (rmop.mem.mem) {
                        .addr => {
                            try gen.addToBuffer();
                        },
                        .label => {
                            try gen.addToBuffer();
                            try gen.addRelocation(rmop.mem.mem.label, .Rel32D, 0);
                        },
                    }
                },
                else => unreachable,
            }
        } else {
            return CodegenError.InvalidOperand;
        }
    } else {
        return CodegenError.DiffOperSizes;
    }
}

fn opEncoding(reg: parser.Register, opcode: u8, sizes_mask: u4, discard_rexw: bool) !void {
    const reg_size = reg.size;
    if (reg_size & sizes_mask == reg_size) {
        gen.ibytes.reset();
        gen.ibytes.opcode = opcode;
        gen.ibytes.plusR(reg.name);
        gen.ibytes.setOsRexW(reg_size);
        if (reg.name.isAdditionalReg()) {
            gen.ibytes.rex.setB();
        }
        if (discard_rexw) {
            gen.ibytes.rex.w = false;
        }
        try gen.addToBuffer();
    } else {
        return CodegenError.WrongRegisterSize;
    }
}

fn opImmEncoding(reg: parser.Register, opcode: u8, imm: parser.Operand) !void {
    const reg_size = reg.size;
    var is_label: bool = undefined;
    var imm_size: u8 = undefined;
    switch (imm) {
        .imm => {
            is_label = false;
            imm_size = parser.immMinSize(imm.imm);
        },
        .label => {
            is_label = true;
            imm_size = 8;
        },
        else => unreachable,
    }
    if (reg_size >= imm_size) {
        if (reg_size == 8 and imm_size <= 4) {
            try memImmEncodingG1(.{ .reg = reg }, 0xC7, 0, imm.imm);
        } else {
            try gen.ibytes.def(reg, .{ .reg = parser.Register.init(.Eax) }, opcode);
            gen.ibytes.plusR(reg.name);
            gen.ibytes.modrm = null;
            try gen.addToBuffer();
            if (is_label) {
                try gen.addImmediate(.{ .u = 0 }, reg_size);
                try gen.addRelocation(imm.label, .Abs64D, 0);
            } else {
                try gen.addImmediate(imm.imm, reg_size);
            }
        }
    } else {
        return CodegenError.ImmValueIsTooLarge;
    }
}

fn memImmEncodingG1(rmop: parser.Operand, opcode: u8, digit: u8, imm: parser.Immediate) !void {
    const imm_size = parser.immMinSize(imm);
    var rm_size: u8 = undefined;
    switch (rmop) {
        .reg => {
            rm_size = rmop.reg.size;
        },
        .mem => {
            if (rmop.mem.size) |size| {
                rm_size = size;
            } else {
                return CodegenError.UnspecifiedMemoryPointerSize;
            }
        },
        else => unreachable,
    }
    if (rm_size >= imm_size and imm_size <= 4) {
        const reg = digitToReg(digit);
        try gen.ibytes.def(reg, rmop, opcode);
        gen.ibytes.setOsRexW(rm_size);
        const imm_bytes = if (rm_size == 8) 4 else rm_size;
        switch (rmop) {
            .reg => {
                try gen.addToBuffer();
                try gen.addImmediate(imm, imm_bytes);
            },
            .mem => {
                switch (rmop.mem.mem) {
                    .addr => {
                        try gen.addToBuffer();
                        try gen.addImmediate(imm, imm_bytes);
                    },
                    .label => {
                        try gen.addToBuffer();
                        try gen.addRelocation(rmop.mem.mem.label, .Rel32D, imm_bytes);
                        try gen.addImmediate(imm, imm_bytes);
                    },
                }
            },
            else => unreachable,
        }
    } else {
        return CodegenError.ImmValueIsTooLarge;
    }
}

fn memImmEncodingG2(rmop: parser.Operand, opcode: u8, digit: u8, imm: parser.Immediate) !void {
    var rm_size: u8 = undefined;
    switch (rmop) {
        .reg => {
            rm_size = rmop.reg.size;
        },
        .mem => {
            if (rmop.mem.size) |size| {
                rm_size = size;
            } else {
                return CodegenError.UnspecifiedMemoryPointerSize;
            }
        },
        else => unreachable,
    }
    const reg = digitToReg(digit);
    try gen.ibytes.def(reg, rmop, opcode);
    gen.ibytes.setOsRexW(rm_size);
    switch (rmop) {
        .reg => {
            try gen.addToBuffer();
            try gen.addImmediate(imm, 1);
        },
        .mem => {
            switch (rmop.mem.mem) {
                .addr => {
                    try gen.addToBuffer();
                    try gen.addImmediate(imm, 1);
                },
                .label => {
                    try gen.addToBuffer();
                    try gen.addRelocation(rmop.mem.mem.label, .Rel32D, 1);
                    try gen.addImmediate(imm, 1);
                },
            }
        },
        else => unreachable,
    }
}

fn immEncoding(opcode: u8, imm: parser.Operand, sizes_mask: u4, discard_os: bool) !void {
    var is_label: bool = undefined;
    var imm_size: u8 = undefined;
    switch (imm) {
        .imm => {
            is_label = false;
            imm_size = parser.immMinSize(imm.imm);
        },
        .label => {
            is_label = true;
            imm_size = 4;
        },
        else => unreachable,
    }
    if (imm_size % sizes_mask == imm_size) {
        if (!discard_os and imm_size == 2) {
            try gen.section.buffer.append(gen.allocator, 0x66);
        }
        try gen.section.buffer.append(gen.allocator, opcode);
        if (is_label) {
            try gen.addImmediate(.{ .u = 0 }, imm_size);
            try gen.addRelocation(imm.label, .Abs32D, 0);
        } else {
            try gen.addImmediate(imm.imm, imm_size);
        }
    } else {
        return CodegenError.InvalidOperand;
    }
}

fn accImmEncoding(acc: parser.Register, opcode: u8, imm: parser.Immediate) !void {
    const acc_size = acc.size;
    const imm_size = parser.immMinSize(imm);
    if (acc_size >= imm_size and imm_size <= 4) {
        gen.ibytes.reset();
        gen.ibytes.opcode = opcode;
        gen.ibytes.setOsRexW(acc_size);

        const imm_bytes = if (acc_size == 8) 4 else acc_size;
        try gen.addToBuffer();
        try gen.addImmediate(imm, imm_bytes);
    } else {
        return CodegenError.ImmValueIsTooLarge;
    }
}

fn zeroEncoding(opcode_bytes: []const u8) !void {
    try gen.section.buffer.appendSlice(gen.allocator, opcode_bytes);
}

fn syscall(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 0) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const buffer: [2]u8 = .{ 0x0F, 0x05 };
    try zeroEncoding(buffer[0..]);
}

fn mov(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (first.reg.size == 1) 0x88 else 0x89;
                    try memRegEncoding(first, second.reg, opcode);
                },
                .mem => {
                    const opcode: u8 = if (first.reg.size == 1) 0x8A else 0x8B;
                    try regMemEncoding(first.reg, second, opcode, 0b1111);
                },
                .imm, .label => {
                    const opcode: u8 = if (first.reg.size == 1) 0xB0 else 0xB8;
                    try opImmEncoding(first.reg, opcode, second);
                },
            }
        },
        .mem => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (second.reg.size == 1) 0x88 else 0x89;
                    try memRegEncoding(first, second.reg, opcode);
                },
                .imm => {
                    var ptr_size: u8 = undefined;
                    if (first.mem.size) |size| {
                        ptr_size = size;
                    } else {
                        return CodegenError.UnspecifiedMemoryPointerSize;
                    }
                    const opcode: u8 = if (ptr_size == 1) 0xC6 else 0xC7;
                    try memImmEncodingG1(first, opcode, 0, second.imm);
                },
                .label => {
                    // unsupported for now
                    return CodegenError.InvalidOperand;
                },
                .mem => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
}

fn push(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg => {
            const opcode: u8 = 0x50;
            try opEncoding(first.reg, opcode, 0b1010, true);
        },
        .mem => {
            const opcode: u8 = 0xFF;
            try memEncoding(first, opcode, 6, 0b1010, true);
        },
        .imm, .label => {
            const immsize = parser.immMinSize(first.imm);
            const opcode: u8 = if (immsize == 1) 0x6A else 0x68;
            try immEncoding(opcode, first, 0b0111, false);
        },
    }
}

fn pop(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg => {
            const opcode: u8 = 0x58;
            try opEncoding(first.reg, opcode, 0b1010, true);
        },
        .mem => {
            const opcode: u8 = 0x8F;
            try memEncoding(first, opcode, 0, 0b1010, true);
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
}

fn inc(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    var opcode: u8 = undefined;
    switch (first) {
        .reg => {
            opcode = if (first.reg.size == 1) 0xFE else 0xFF;
        },
        .mem => {
            opcode = if (first.mem.size == 1) 0xFE else 0xFF;
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }

    try memEncoding(first, opcode, 0, 0b1111, false);
}

fn dec(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    var opcode: u8 = undefined;
    switch (first) {
        .reg => {
            opcode = if (first.reg.size == 1) 0xFE else 0xFF;
        },
        .mem => {
            opcode = if (first.mem.size == 1) 0xFE else 0xFF;
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }

    try memEncoding(first, opcode, 1, 0b1111, false);
}

fn lea(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            switch (second) {
                .mem => {
                    const opcode: u8 = 0x8D;
                    try regMemEncoding(first.reg, second, opcode, 0b1110);
                },
                else => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
}

fn div(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];

    var opcode: u8 = undefined;
    switch (first) {
        .reg => {
            opcode = if (first.reg.size == 1) 0xF6 else 0xF7;
        },
        .mem => {
            opcode = if (first.mem.size == 1) 0xF6 else 0xF7;
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }

    try memEncoding(first, opcode, 6, 0b1111, false);
}

fn testi(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (second) {
        .imm => {
            switch (first) {
                .reg => {
                    if (first.reg.name.isAccumulator()) {
                        const opcode: u8 = if (first.reg.name == .Al) 0xA8 else 0xA9;
                        try accImmEncoding(first.reg, opcode, second.imm);
                    } else {
                        const opcode: u8 = if (first.reg.size == 1) 0xF6 else 0xF7;
                        try memImmEncodingG1(first, opcode, 0, second.imm);
                    }
                },
                .mem => {
                    var ptr_size: u8 = undefined;
                    if (first.mem.size) |size| {
                        ptr_size = size;
                    } else {
                        return CodegenError.UnspecifiedMemoryPointerSize;
                    }
                    const opcode: u8 = if (ptr_size == 1) 0xF6 else 0xF7;
                    try memImmEncodingG1(first, opcode, 0, second.imm);
                },
                else => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        .reg => {
            switch (first) {
                .reg, .mem => {
                    const opcode: u8 = if (second.reg.size == 1) 0x84 else 0x85;
                    try memRegEncoding(first, second.reg, opcode);
                },
                else => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
    // switch (first) {
    //     .reg => {
    //         switch (second) {
    //             .imm => {
    //                 if (first.reg.name.isAccumulator()) {
    //                     const opcode: u8 = if (first.reg.size == 1) 0xA8 else 0xA9;
    //                     try accImmEncoding(first.reg, opcode, second.imm);
    //                 }
    //             },
    //             .reg => {},
    //             else => {
    //                 return CodegenError.InvalidOperand;
    //             },
    //         }
    //     },
    //     .mem => {},
    //     else => {
    //         return CodegenError.InvalidOperand;
    //     },
    // }
}

fn add(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (first.reg.size == 1) 0x00 else 0x01;
                    try memRegEncoding(first, second.reg, opcode);
                },
                .mem => {
                    const opcode: u8 = if (first.reg.size == 1) 0x02 else 0x03;
                    try regMemEncoding(first.reg, second, opcode, 0b1111);
                },
                .imm => {
                    if (first.reg.name.isAccumulator()) {
                        const opcode: u8 = if (first.reg.name == .Al) 0x04 else 0x05;
                        try accImmEncoding(first.reg, opcode, second.imm);
                    } else {
                        const reg_size = first.reg.size;
                        const imm_size = parser.immMinSize(second.imm);
                        if (imm_size == 1 and reg_size > 1) {
                            const opcode: u8 = 0x83;
                            try memImmEncodingG2(first, opcode, 0, second.imm);
                        } else {
                            const opcode: u8 = if (reg_size == 1) 0x80 else 0x81;
                            try memImmEncodingG1(first, opcode, 0, second.imm);
                        }
                    }
                },
                .label => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        .mem => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (second.reg.size == 1) 0x00 else 0x01;
                    try memRegEncoding(first, second.reg, opcode);
                },
                .imm => {
                    var ptr_size: u8 = undefined;
                    if (first.mem.size) |size| {
                        ptr_size = size;
                    } else {
                        return CodegenError.UnspecifiedMemoryPointerSize;
                    }
                    const imm_size = parser.immMinSize(second.imm);
                    if (imm_size == 1 and ptr_size > 1) {
                        const opcode: u8 = 0x83;
                        try memImmEncodingG2(first, opcode, 0, second.imm);
                    } else {
                        const opcode: u8 = if (ptr_size == 1) 0x80 else 0x81;
                        try memImmEncodingG1(first, opcode, 0, second.imm);
                    }
                },
                .label => {
                    // not supported for now
                    return CodegenError.InvalidOperand;
                },
                .mem => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
}

fn xor(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (first.reg.size == 1) 0x30 else 0x31;
                    try memRegEncoding(first, second.reg, opcode);
                },
                .mem => {
                    const opcode: u8 = if (first.reg.size == 1) 0x32 else 0x33;
                    try regMemEncoding(first.reg, second, opcode, 0b1111);
                },
                .imm => {
                    if (first.reg.name.isAccumulator()) {
                        const opcode: u8 = if (first.reg.name == .Al) 0x34 else 0x35;
                        try accImmEncoding(first.reg, opcode, second.imm);
                    } else {
                        const reg_size = first.reg.size;
                        const imm_size = parser.immMinSize(second.imm);
                        if (imm_size == 1 and reg_size > 1) {
                            const opcode: u8 = 0x83;
                            try memImmEncodingG2(first, opcode, 6, second.imm);
                        } else {
                            const opcode: u8 = if (reg_size == 1) 0x80 else 0x81;
                            try memImmEncodingG1(first, opcode, 6, second.imm);
                        }
                    }
                },
                .label => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        .mem => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (second.reg.size == 1) 0x30 else 0x31;
                    try memRegEncoding(first, second.reg, opcode);
                },
                .imm => {
                    var ptr_size: u8 = undefined;
                    if (first.mem.size) |size| {
                        ptr_size = size;
                    } else {
                        return CodegenError.UnspecifiedMemoryPointerSize;
                    }
                    const imm_size = parser.immMinSize(second.imm);
                    if (imm_size == 1 and ptr_size > 1) {
                        const opcode: u8 = 0x83;
                        try memImmEncodingG2(first, opcode, 6, second.imm);
                    } else {
                        const opcode: u8 = if (ptr_size == 1) 0x80 else 0x81;
                        try memImmEncodingG1(first, opcode, 6, second.imm);
                    }
                },
                .label => {
                    // not supported for now
                    return CodegenError.InvalidOperand;
                },
                .mem => {
                    return CodegenError.InvalidOperand;
                },
            }
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
}

fn jmp(instr: parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg, .mem => {
            const opcode: u8 = 0xFF;
            try memEncoding(first, opcode, 4, 0b1000, true);
        },
        .label => {
            const opcode: u8 = 0xE9;
            try gen.section.buffer.append(gen.allocator, opcode);
            try gen.addImmediate(.{ .u = 0 }, 4);
            try gen.addRelocation(first.label, .Rel32C, 0);
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
}

fn jcc(instr: parser.CpuInstruction, mnem: lexer.TokenType) !void {
    if (instr.operands.items.len != 1) {
        return CodegenError.InvalidNumberOfOperands;
    }
    const first = instr.operands.items[0];
    switch (first) {
        .label => {
            const opcode_pref: u8 = 0x0F;
            const opcode: u8 = switch (mnem) {
                .Ja => 0x87,
                .Je, .Jz => 0x84,
                .Jne => 0x85,
                else => {
                    return CodegenError.InvalidOperand;
                },
            };
            try gen.section.buffer.append(gen.allocator, opcode_pref);
            try gen.section.buffer.append(gen.allocator, opcode);
            try gen.addImmediate(.{ .u = 0 }, 4);
            try gen.addRelocation(first.label, .Rel32C, 0);
        },
        else => {
            return CodegenError.InvalidOperand;
        },
    }
}

var peek: usize = 0;

fn genInstruction(instruction: parser.CodeInstruction, section: *parser.CodeSection) !void {
    switch (instruction) {
        .label => {
            const cl_ptr = section.symbols.getPtr(instruction.label);
            if (cl_ptr) |cl| {
                cl.offset = section.buffer.items.len;
                // TODO: add global keyword for globally visible symbols
                cl.binding = .Local;
            } else {
                // error - label not found (should be unreachable at this stage)
            }
        },
        .cpu => {
            switch (instruction.cpu.mnem) {
                .Mov => {
                    try mov(instruction.cpu);
                },
                .Xor => {
                    try xor(instruction.cpu);
                },
                .Add => {
                    try add(instruction.cpu);
                },
                .Inc => {
                    try inc(instruction.cpu);
                },
                .Dec => {
                    try dec(instruction.cpu);
                },
                .Ja, .Je, .Jne, .Jz => {
                    try jcc(instruction.cpu, instruction.cpu.mnem);
                },
                .Syscall => {
                    try syscall(instruction.cpu);
                },
                .Div => {
                    try div(instruction.cpu);
                },
                .Test => {
                    try testi(instruction.cpu);
                },
                .Lea => {
                    try lea(instruction.cpu);
                },
                .Push => {
                    try push(instruction.cpu);
                },
                .Pop => {
                    try pop(instruction.cpu);
                },
                .Jmp => {
                    try jmp(instruction.cpu);
                },
                else => {
                    //
                },
            }
            // var count: u8 = 0;
            // std.debug.print("{d: >4}: ", .{peek});
            // for (section.buffer.items[peek..]) |byte| {
            //     std.debug.print("{x:02} ", .{byte});
            //     count += 1;
            // }
            // std.debug.print("\x1b[40G", .{});
            // parser.printCPUInstruction(instruction.cpu);
            // peek += count;
            // std.debug.print("\n", .{});
        },
    }
}

pub fn bufferizeCodeSection(section: *parser.CodeSection, allocator: std.mem.Allocator) !void {
    gen = Codegen.init(section, allocator);
    for (section.instr.items, 0..) |instruction, i| {
        genInstruction(instruction, section) catch |err| {
            std.debug.print("Instruction {d} (", .{i});
            parser.printCPUInstruction(instruction.cpu);
            std.debug.print(") failed code generation\n", .{});
            // std.debug.print("{s}\n", .{@errorName(err)});
            return err;
        };
    }
}
