const std = @import("std");
const utils = @import("utils");

const Lexer = @import("Lexer");
const TokenType = Lexer.TokenType;

const Program = @import("Program");
const Label = Program.Label;
const Register = Program.Register;
const Displacement = Program.Displacement;
const Immediate = Program.Immediate;
const MemOperand = Program.MemOperand;
const CodeOperand = Program.CodeOperand;
const CpuInstruction = Program.CpuInstruction;
const CodeInstruction = Program.CodeInstruction;
const RelType = Program.RelType;
const Relocation = Program.Relocation;

const Codegen = @This();

pub const CodegenError = error{CodeGenFailed} || std.mem.Allocator.Error;

const ModRmByte = packed struct(u8) {
    rm: u3,
    reg: u3,
    mod: u2,

    pub fn byte(self: ModRmByte) u8 {
        return @bitCast(self);
    }
};

const SibByte = packed struct(u8) {
    base: u3,
    index: u3,
    ss: u2,

    pub fn byte(self: SibByte) u8 {
        return @bitCast(self);
    }
};

const RexByte = packed struct(u8) {
    b: bool,
    x: bool,
    r: bool,
    w: bool,
    rex: u4 = 0b0100,

    pub fn default() RexByte {
        return RexByte{ .b = false, .x = false, .r = false, .w = false, .rex = 0 };
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
    /// 0x67
    as: bool = false,
    /// 0x66
    os: bool = false,
    f2: bool = false,
    f3: bool = false,
    rex: RexByte = RexByte.default(),
    /// 0x0F
    twobyteop: bool = false,
    /// 0x38
    threebyte38: bool = false,
    /// 0x3A
    threebyte3a: bool = false,
    opcode: u8 = 0x00,
    modrm: ?ModRmByte = null,
    need_sib: bool = false,
    sib: ?SibByte = null,
    disp: ?Displacement = null,
    disp_bytes: u8 = 0,

    reloc: ?Relocation = null,

    pub fn reset(self: *InstrBytes) void {
        self.* = InstrBytes{};
    }

    fn regCode(reg: TokenType) u3 {
        return @truncate(@intFromEnum(reg) >> 11);
    }

    fn digitToReg(digit: u8) Register {
        switch (digit) {
            0 => return .init(.eax),
            1 => return .init(.ecx),
            2 => return .init(.edx),
            3 => return .init(.ebx),
            4 => return .init(.esp),
            5 => return .init(.ebp),
            6 => return .init(.esi),
            7 => return .init(.edi),
            else => unreachable,
        }
    }

    fn plusR(self: *InstrBytes, reg: TokenType) void {
        self.opcode += regCode(reg);
    }

    fn setOsRexW(self: *InstrBytes, size: u8) void {
        switch (size) {
            2 => self.os = true,
            8 => self.rex.setW(),
            else => {},
        }
    }

    fn swapBaseIndex(mem: MemOperand, codegen: *const Codegen) CodegenError!MemOperand {
        if (mem.index.size() > 0) {
            const with_scale = if (mem.scale > 1) true else false;
            const index_code = regCode(mem.index.name);
            if (index_code == 0b100 and !mem.index.name.isAdditionalReg()) {
                if (!with_scale) {
                    if (mem.base.size() > 0) {
                        const base_code = regCode(mem.base.name);
                        if (base_code != 0b100 or mem.base.name.isAdditionalReg()) {
                            var swapped = mem;
                            swapped.base = mem.index;
                            swapped.index = mem.base;
                            return swapped;
                        } else {
                            utils.printSrcLineErrorFmt("{t} as index is not allowed", .{mem.index.name}, codegen.program, codegen.line);
                            return CodegenError.CodeGenFailed;
                        }
                    }
                } else {
                    utils.printSrcLineErrorFmt("{t} as index is not allowed", .{mem.index.name}, codegen.program, codegen.line);
                    return CodegenError.CodeGenFailed;
                }
            }
        }
        return mem;
    }

    fn calcSib(self: *InstrBytes, mem: MemOperand) void {
        var base: u3 = 0b101;
        var index: u3 = 0b100;
        var scale: u2 = 0b00;

        if (mem.scale > 0) {
            switch (mem.scale) {
                1 => scale = 0b00,
                2 => scale = 0b01,
                4 => scale = 0b10,
                8 => scale = 0b11,
                else => unreachable,
            }
        }

        if (mem.index.size() > 0) {
            index = regCode(mem.index.name);
            if (mem.index.name.isAdditionalReg()) {
                self.rex.setX();
            }
            self.as = (mem.index.size() == 4);
        }

        if (mem.base.size() > 0) {
            base = regCode(mem.base.name);
            if (mem.base.name.isAdditionalReg()) {
                self.rex.setB();
            }
            self.as = (mem.base.size() == 4);
        }

        self.sib = SibByte{ .base = base, .index = index, .ss = scale };
    }

    fn calcModRm(self: *InstrBytes, reg: Register, rm: CodeOperand, codegen: *const Codegen) CodegenError!void {
        var mod: u2 = undefined;
        var rm_code: u3 = undefined;
        const reg_code: u3 = regCode(reg.name);
        self.setOsRexW(reg.size());
        if (reg.name.isAdditionalReg()) {
            self.rex.setR();
        } else if (reg.name.isByteRegAdditional()) {
            self.rex.rex = 0b0100;
        }
        switch (rm.tag) {
            .reg => {
                mod = 0b11;
                rm_code = regCode(rm.op.reg.r.name);
                if (rm.op.reg.r.name.isAdditionalReg()) {
                    self.rex.setB();
                } else if (reg.name.isByteRegAdditional()) {
                    self.rex.rex = 0b0100;
                }
            },
            .mem => {
                const label = rm.op.mem.label;
                const base = rm.op.mem.base;
                const disp = rm.op.mem.disp;
                if (label > 0) {
                    try codegen.checkLabelDefined(label);
                    self.reloc = Relocation{};
                    self.reloc.?.name = label;
                    self.disp = disp;
                    self.disp_bytes = 4;
                    if (rm.op.mem.index.size() == 0) {
                        if (base.size() == 0 or base.name == .rip) {
                            mod = 0b00;
                            rm_code = 0b101;
                            self.reloc.?.type = .Rel32D;
                        } else {
                            if (utils.flags.pic) {
                                utils.printSrcLineError("label with base cannot be used with -pic flag", codegen.program, codegen.line);
                                return CodegenError.CodeGenFailed;
                            } else if (utils.flags.warnings) {
                                utils.printSrcLineWarning("label address will be truncated to 32-bit", codegen.program, codegen.line);
                            }
                            mod = 0b10;
                            rm_code = regCode(base.name);
                            if (rm_code == 0b100) self.need_sib = true;
                            self.reloc.?.type = .Abs32S;
                        }
                    } else {
                        if (utils.flags.pic) {
                            utils.printSrcLineError("label with index cannot be used with -pic flag", codegen.program, codegen.line);
                            return CodegenError.CodeGenFailed;
                        } else if (utils.flags.warnings) {
                            utils.printSrcLineWarning("label address will be truncated to 32-bit", codegen.program, codegen.line);
                        }
                        mod = 0b10;
                        rm_code = 0b100;
                        self.need_sib = true;
                        self.reloc.?.type = .Abs32S;
                        if (base.size() == 0) mod = 0b00;
                    }
                } else {
                    const disp_size = dispMinSize(disp);
                    if (rm.op.mem.index.size() == 0) {
                        if (base.size() > 0) {
                            if (base.name == .rip) {
                                mod = 0b00;
                                rm_code = 0b101;
                                self.disp = disp;
                                self.disp_bytes = 4;
                            } else {
                                rm_code = regCode(base.name);
                                if (base.name.isAdditionalReg()) {
                                    self.rex.setB();
                                }
                                self.as = (base.size() == 4);
                                self.disp_bytes = disp_size;
                                self.disp = disp;
                                if (disp_size == 0) {
                                    mod = 0b00;
                                } else if (disp_size == 1) {
                                    mod = 0b01;
                                } else if (disp_size == 4) {
                                    mod = 0b10;
                                }
                                if (rm_code == 0b100) {
                                    self.need_sib = true;
                                } else if (rm_code == 0b101) {
                                    self.need_sib = false;
                                    if (disp_size < 4) {
                                        mod = 0b01;
                                        self.disp = self.disp orelse 0;
                                        self.disp_bytes = 1;
                                    }
                                } else {
                                    self.need_sib = false;
                                }
                            }
                        } else {
                            self.need_sib = true;
                            mod = 0b00;
                            rm_code = 0b100;
                            self.disp = disp;
                            self.disp_bytes = 4;
                        }
                    } else {
                        self.need_sib = true;
                        if (base.size() > 0) {
                            rm_code = regCode(base.name);
                            if (disp_size == 0) {
                                mod = 0b00;
                            } else if (disp_size == 1) {
                                mod = 0b01;
                            } else if (disp_size == 4) {
                                mod = 0b10;
                            }
                            self.disp_bytes = disp_size;
                            self.disp = disp;
                            if (rm_code == 0b101) {
                                if (disp_size < 4) {
                                    mod = 0b01;
                                    self.disp = self.disp orelse 0;
                                    self.disp_bytes = 1;
                                }
                            }
                            rm_code = 0b100;
                        } else {
                            mod = 0b00;
                            rm_code = 0b100;
                            self.disp_bytes = 4;
                            self.disp = disp;
                        }
                    }
                }
            },
            else => unreachable,
        }
        self.modrm = ModRmByte{ .mod = mod, .reg = reg_code, .rm = rm_code };
    }

    fn init(self: *InstrBytes, reg: Register, rm: CodeOperand, opcode: u8, codegen: *const Codegen) CodegenError!void {
        self.opcode = opcode;
        const checked: CodeOperand = if (rm.tag == .mem) CodeOperand{ .op = .{ .mem = try swapBaseIndex(rm.op.mem, codegen) }, .tag = .mem } else rm;
        try self.calcModRm(reg, checked, codegen);
        if (self.modrm != null) {
            if (self.need_sib) {
                self.calcSib(checked.op.mem);
            }
        }
        if (self.rex.byte() > 0x00) {
            if (reg.name.isByteRegHigh()) {
                utils.printSrcLineErrorFmt("{t} register is not encodable with REX prefix", .{reg.name}, codegen.program, codegen.line);
                return CodegenError.CodeGenFailed;
            } else if (rm.tag == .reg and rm.op.reg.r.name.isByteRegHigh()) {
                utils.printSrcLineErrorFmt("{t} register is not encodable with REX prefix", .{rm.op.reg.r.name}, codegen.program, codegen.line);
                return CodegenError.CodeGenFailed;
            }
        }
    }
};

program: *Program,
ibytes: InstrBytes,
line: u16,
cur_func: Label,
temp_relocs: std.ArrayList(Relocation),

pub fn init(program: *Program) Codegen {
    return Codegen{
        .program = program,
        .ibytes = InstrBytes{},
        .line = 0,
        .cur_func = 0,
        .temp_relocs = .empty,
    };
}

pub fn deinit(self: *Codegen) void {
    self.temp_relocs.deinit(utils.alloc);
}

fn checkLabelDefined(self: *const Codegen, label: Label) CodegenError!void {
    const in_funcs = self.program.funcs.get(label);
    if (in_funcs == null) {
        const in_datavars = self.program.data_vars.get(label);
        if (in_datavars == null) {
            const in_imports = self.program.imports.get(label);
            if (in_imports == null) {
                utils.printSrcLineErrorFmt("reference to undefined label '{s}'", .{utils.stringValue(label)}, self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
        }
    }
}

fn dispMinSize(disp: Displacement) u8 {
    if (disp == 0) return 0;
    if (disp >= std.math.minInt(i8) and disp <= std.math.maxInt(i8)) return 1;
    return 4;
}

fn nonNullSize(size: u8, alt_size: u8) u8 {
    if (size > 0) return size;
    return alt_size;
}

fn memSizeOrError(self: *const Codegen, size: u8) CodegenError!u8 {
    if (size > 0) return size;
    utils.printSrcLineError("unspecified memory pointer size", self.program, self.line);
    return CodegenError.CodeGenFailed;
}

fn rmSize(self: *const Codegen, rm: CodeOperand) CodegenError!u8 {
    switch (rm.tag) {
        .reg => return rm.op.reg.r.size(),
        .mem => return try self.memSizeOrError(rm.op.mem.size),
        else => unreachable,
    }
}

fn invalOpSizesError(self: *const Codegen) CodegenError!void {
    utils.printSrcLineError("invalid operand size", self.program, self.line);
    return CodegenError.CodeGenFailed;
}

fn appendDisplacement(self: *Codegen, disp: Displacement, bytes: u8) std.mem.Allocator.Error!void {
    const value: u32 = @bitCast(disp);
    const array = std.mem.toBytes(value);
    try self.program.code_block.buffer.appendSlice(utils.alloc, array[0..bytes]);
}

fn appendInstrBytes(self: *Codegen) std.mem.Allocator.Error!void {
    if (self.ibytes.as) {
        try self.program.code_block.buffer.append(utils.alloc, 0x67);
    }
    if (self.ibytes.os) {
        try self.program.code_block.buffer.append(utils.alloc, 0x66);
    }
    if (self.ibytes.f2) {
        try self.program.code_block.buffer.append(utils.alloc, 0xF2);
    }
    if (self.ibytes.f3) {
        try self.program.code_block.buffer.append(utils.alloc, 0xF3);
    }
    if (self.ibytes.rex.byte() > 0x00) {
        self.ibytes.rex.rex = 0b0100;
        try self.program.code_block.buffer.append(utils.alloc, self.ibytes.rex.byte());
    }
    if (self.ibytes.twobyteop) {
        try self.program.code_block.buffer.append(utils.alloc, 0x0F);
    }
    if (self.ibytes.threebyte38) {
        try self.program.code_block.buffer.append(utils.alloc, 0x38);
    } else if (self.ibytes.threebyte3a) {
        try self.program.code_block.buffer.append(utils.alloc, 0x3A);
    }
    try self.program.code_block.buffer.append(utils.alloc, self.ibytes.opcode);
    if (self.ibytes.modrm) |modrm| {
        try self.program.code_block.buffer.append(utils.alloc, modrm.byte());
    }
    if (self.ibytes.sib) |sib| {
        try self.program.code_block.buffer.append(utils.alloc, sib.byte());
    }
    if (self.ibytes.disp) |disp| {
        if (self.ibytes.reloc) |*reloc| {
            reloc.addend = disp - 4;
            reloc.offset = @truncate(self.program.code_block.buffer.items.len);
            try self.appendDisplacement(0, 4);
        } else {
            try self.appendDisplacement(disp, self.ibytes.disp_bytes);
        }
    }
}

fn appendImmRelocation(self: *Codegen, imm: CodeOperand, rel_type: RelType) CodegenError!void {
    try self.checkLabelDefined(imm.op.label.l);
    var reloc = Relocation{
        .offset = @truncate(self.program.code_block.buffer.items.len),
        .name = imm.op.label.l,
        .type = rel_type,
        .addend = @bitCast(imm.op.label.d.bits),
    };
    if (rel_type == .Rel32C or rel_type == .Rel32D) {
        reloc.addend -= 4;
    }
    try self.program.relocations.append(utils.alloc, reloc);
    const reloc_size: u8 = switch (rel_type) {
        .Abs32, .Abs32S, .Rel32C, .Rel32D => 4,
        .Abs64 => 8,
    };
    try self.appendImmediateBytes(.{ .bits = 0, .sign = .u }, reloc_size);
}

fn appendImmediateBytes(self: *Codegen, imm: Immediate, bytes: u8) std.mem.Allocator.Error!void {
    const value: u64 = switch (imm.sign) {
        .i => @bitCast(imm.bits),
        .u => imm.bits,
    };
    const array = std.mem.toBytes(value);
    try self.program.code_block.buffer.appendSlice(utils.alloc, array[0..bytes]);
}

fn nearJump(self: *Codegen, imm: CodeOperand, mnem: TokenType, opcode: u8) CodegenError!void {
    if (mnem == .jmp) {
        try self.program.code_block.buffer.append(utils.alloc, 0xE9);
    } else {
        try self.program.code_block.buffer.appendSlice(utils.alloc, &.{ 0x0F, opcode });
    }
    try self.temp_relocs.append(utils.alloc, .{
        .name = imm.op.label.l,
        .offset = @truncate(self.program.code_block.buffer.items.len),
        .type = .Rel32C,
        .addend = @as(i64, @bitCast(imm.op.label.d.bits)) - 4,
    });
    try self.appendImmediateBytes(.{ .bits = 0, .sign = .u }, 4);
}

fn jumpReloc(self: *Codegen, imm: CodeOperand, mnem: TokenType, opcode: u8) CodegenError!void {
    if (self.program.funcs.getPtr(self.cur_func)) |func_ptr| {
        const local_lbl = func_ptr.local_labels.get(imm.op.label.l);
        if (local_lbl) |local| {
            if (local == std.math.maxInt(u32)) {
                try self.nearJump(imm, mnem, opcode);
            } else {
                const disp = imm.op.label.d;
                const diff = @as(isize, @intCast(self.program.code_block.buffer.items.len)) - @as(isize, @intCast(local)) - switch (disp.sign) {
                    .u => @as(isize, @intCast(disp.bits)),
                    .i => @as(isize, @bitCast(disp.bits)),
                };
                if (diff < 0x7F) {
                    const disp_byte: i8 = @truncate(-(diff + 2));
                    if (mnem == .jmp) {
                        try self.program.code_block.buffer.appendSlice(utils.alloc, &.{ 0xEB, @bitCast(disp_byte) });
                    } else {
                        try self.program.code_block.buffer.appendSlice(utils.alloc, &.{ opcode - 0x10, @bitCast(disp_byte) });
                    }
                } else {
                    try self.nearJump(imm, mnem, opcode);
                }
            }
            return;
        }
    }
    if (mnem == .jmp) {
        try self.program.code_block.buffer.append(utils.alloc, 0xE9);
    } else {
        try self.program.code_block.buffer.appendSlice(utils.alloc, &.{ 0x0F, opcode });
    }
    try self.appendImmRelocation(imm, .Rel32C);
}

// Encodings

fn regMemEncoding(self: *Codegen, reg: Register, rm: CodeOperand, opcode: u8, sizes: u4) CodegenError!void {
    const reg_size = reg.size();
    const rm_size: u8 = switch (rm.tag) {
        .reg => rm.op.reg.r.size(),
        .mem => nonNullSize(rm.op.mem.size, reg_size),
        else => unreachable,
    };
    if (rm_size == reg_size) {
        if (rm_size & sizes == rm_size) {
            self.ibytes.reset();
            try self.ibytes.init(reg, rm, opcode, self);
            try self.appendInstrBytes();
            if (self.ibytes.reloc) |*reloc| {
                try self.program.relocations.append(utils.alloc, reloc.*);
            }
        } else {
            try self.invalOpSizesError();
        }
    } else {
        switch (rm.tag) {
            .reg => utils.printSrcLineError("registers sizes don't match", self.program, self.line),
            .mem => utils.printSrcLineError("pointer size doesn't match register size", self.program, self.line),
            else => unreachable,
        }
        return CodegenError.CodeGenFailed;
    }
}

fn memRegEncoding(self: *Codegen, rm: CodeOperand, reg: Register, opcode: u8, sizes: u4) CodegenError!void {
    try self.regMemEncoding(reg, rm, opcode, sizes);
}

fn memImmEncoding1(self: *Codegen, rm: CodeOperand, opcode: u8, digit: u8, imm: Immediate) CodegenError!void {
    const imm_size = imm.fitsInBytes();
    const rm_size = try self.rmSize(rm);
    if (rm_size >= imm_size and imm_size <= 4) {
        const reg = InstrBytes.digitToReg(digit);
        self.ibytes.reset();
        try self.ibytes.init(reg, rm, opcode, self);
        self.ibytes.setOsRexW(rm_size);
        const imm_bytes = if (rm_size == 8) 4 else rm_size;
        try self.appendInstrBytes();
        try self.appendImmediateBytes(imm, imm_bytes);
        if (self.ibytes.reloc) |*reloc| {
            reloc.addend -= imm_bytes;
            try self.program.relocations.append(utils.alloc, reloc.*);
        }
    } else {
        utils.printSrcLineError("immediate value doesn't fit in memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn memImmEncoding2(self: *Codegen, rm: CodeOperand, opcode: u8, digit: u8, imm: Immediate) CodegenError!void {
    const rm_size = try self.rmSize(rm);
    const reg = InstrBytes.digitToReg(digit);
    self.ibytes.reset();
    try self.ibytes.init(reg, rm, opcode, self);
    self.ibytes.setOsRexW(rm_size);
    try self.appendInstrBytes();
    try self.appendImmediateBytes(imm, 1);
    if (self.ibytes.reloc) |*reloc| {
        reloc.addend -= 1;
    }
}

fn opImmEncoding(self: *Codegen, reg: Register, opcode: u8, imm: CodeOperand) CodegenError!void {
    const reg_size = reg.size();
    var imm_size: u8 = undefined;
    var is_label = false;
    switch (imm.tag) {
        .imm => imm_size = imm.op.imm.i.fitsInBytes(),
        .lbl => {
            is_label = true;
            const disp_size = imm.op.label.d.fitsInBytes();
            imm_size = @max(reg_size, disp_size);
        },
        else => unreachable,
    }
    if (reg_size >= imm_size) {
        if (reg_size == 8 and imm_size <= 4) {
            try self.memImmEncoding1(.{ .op = .{ .reg = .{ .r = reg } }, .tag = .reg }, 0xC7, 0, imm.op.imm.i);
        } else {
            imm_size = reg_size;
            self.ibytes.reset();
            try self.ibytes.init(reg, .{ .op = .{ .reg = .{ .r = .init(.eax) } }, .tag = .reg }, opcode, self);
            self.ibytes.plusR(reg.name);
            self.ibytes.modrm = null;
            try self.appendInstrBytes();
            if (is_label) {
                const rel_type: RelType = switch (imm_size) {
                    4 => .Abs32,
                    8 => .Abs64,
                    else => {
                        utils.printSrcLineError("register is too small for label address", self.program, self.line);
                        return CodegenError.CodeGenFailed;
                    },
                };
                if (rel_type == .Abs32) {
                    if (utils.flags.pic) {
                        utils.printSrcLineError("absolute 32-bit address cannot be used with -pic flag", self.program, self.line);
                        return CodegenError.CodeGenFailed;
                    } else if (utils.flags.warnings) {
                        utils.printSrcLineWarning("address will be truncated to 32-bit", self.program, self.line);
                    }
                }
                try self.appendImmRelocation(imm, rel_type);
            } else {
                try self.appendImmediateBytes(imm.op.imm.i, imm_size);
            }
        }
    } else {
        utils.printSrcLineError("immediate value doesn't fit in register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn accImmEncoding(self: *Codegen, acc: Register, opcode: u8, imm: Immediate) CodegenError!void {
    const acc_size = acc.size();
    const imm_size = imm.fitsInBytes();
    if (acc_size >= imm_size and imm_size <= 4) {
        self.ibytes.reset();
        self.ibytes.opcode = opcode;
        self.ibytes.setOsRexW(acc_size);
        try self.appendInstrBytes();
        const imm_bytes = @min(4, acc_size);
        try self.appendImmediateBytes(imm, imm_bytes);
    } else {
        utils.printSrcLineError("immediate value doesn't fit in register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn opEncoding(self: *Codegen, reg: Register, opcode: u8, sizes: u4) CodegenError!void {
    const reg_size = reg.size();
    if (reg_size & sizes == reg_size) {
        self.ibytes.reset();
        try self.ibytes.init(reg, .{ .op = .{ .reg = .{ .r = reg } }, .tag = .reg }, opcode, self);
        self.ibytes.modrm = null;
        self.ibytes.plusR(reg.name);
        self.ibytes.setOsRexW(reg_size);
        self.ibytes.rex.r = false;
        self.ibytes.rex.w = false;
        try self.appendInstrBytes();
    } else {
        try self.invalOpSizesError();
    }
}

fn memEncoding(self: *Codegen, rm: CodeOperand, digit: u8, opcode: u8, sizes: u4, discard_rexw: bool) CodegenError!void {
    const rm_size = try self.rmSize(rm);
    if (rm_size & sizes == rm_size) {
        const reg = InstrBytes.digitToReg(digit);
        self.ibytes.reset();
        try self.ibytes.init(reg, rm, opcode, self);
        self.ibytes.setOsRexW(rm_size);
        if (discard_rexw) {
            self.ibytes.rex.w = false;
        }
        try self.appendInstrBytes();
        if (self.ibytes.reloc) |*reloc| {
            try self.program.relocations.append(utils.alloc, reloc.*);
        }
    } else {
        try self.invalOpSizesError();
    }
}

fn immEncoding(self: *Codegen, imm: CodeOperand, opcode: u8, sizes: u4) CodegenError!void {
    var imm_size: u8 = undefined;
    var is_label = false;
    switch (imm.tag) {
        .imm => imm_size = imm.op.imm.i.fitsInBytes(),
        .lbl => {
            imm_size = 4;
            is_label = true;
        },
        else => unreachable,
    }
    if (imm_size & sizes == imm_size) {
        if (imm_size == 2) {
            try self.program.code_block.buffer.append(utils.alloc, 0x66);
        }
        try self.program.code_block.buffer.append(utils.alloc, opcode);
        if (is_label) {
            if (utils.flags.pic) {
                utils.printSrcLineError("absolute 32-bit address cannot be used with -pic flag", self.program, self.line);
                return CodegenError.CodeGenFailed;
            } else if (utils.flags.warnings) {
                utils.printSrcLineWarning("address will be truncated to 32-bit", self.program, self.line);
            }
            try self.appendImmRelocation(imm, .Abs32);
        } else {
            try self.appendImmediateBytes(imm.op.imm.i, imm_size);
        }
    } else {
        try self.invalOpSizesError();
    }
}

fn regMem128Encoding(self: *Codegen, mnem: TokenType, opcode: u8, reg: Register, rm: CodeOperand, mem_size: u8, set_rexw: bool) CodegenError!void {
    // Cnange alt_size to 16 to strict pointer size match instruction
    const rm_size = if (rm.tag == .mem) nonNullSize(rm.op.mem.size, mem_size) else mem_size;
    if (rm_size == mem_size) {
        self.ibytes.reset();
        const pref_bits = @intFromEnum(mnem) & 0x1800;
        switch (pref_bits) {
            0x0 => {},
            0x800 => self.ibytes.os = true,
            0x1000 => self.ibytes.f3 = true,
            0x1800 => self.ibytes.f2 = true,
            else => unreachable,
        }
        const opcode_len_bits = @intFromEnum(mnem) & 0x6000;
        if (opcode_len_bits > 0) self.ibytes.twobyteop = true;
        if (opcode_len_bits == 0x4000) self.ibytes.threebyte38 = true else if (opcode_len_bits == 0x6000) self.ibytes.threebyte3a = true;

        try self.ibytes.init(reg, rm, opcode, self);
        if (set_rexw) self.ibytes.rex.setW();
        try self.appendInstrBytes();
        if (self.ibytes.reloc) |*reloc| {
            try self.program.relocations.append(utils.alloc, reloc.*);
        }
    } else if (rm.tag == .mem) {
        utils.printSrcLineError("wrong pointer size", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

// Instructions

fn syscall(self: *Codegen) CodegenError!void {
    try self.program.code_block.buffer.appendSlice(utils.alloc, &.{ 0x0F, 0x05 });
}

fn mov(self: *Codegen, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    if (first.tag == .reg) {
        if (second.tag == .reg or second.tag == .mem) {
            const opcode: u8 = if (first.op.reg.r.size() == 1) 0x8A else 0x8B;
            try self.regMemEncoding(first.op.reg.r, second, opcode, 0b1111);
        } else if (second.tag == .imm or second.tag == .lbl) {
            const opcode: u8 = if (first.op.reg.r.size() == 1) 0xB0 else 0xB8;
            try self.opImmEncoding(first.op.reg.r, opcode, second);
        }
    } else if (first.tag == .mem) {
        if (second.tag == .reg) {
            const opcode: u8 = if (second.op.reg.r.size() == 1) 0x88 else 0x89;
            try self.memRegEncoding(first, second.op.reg.r, opcode, 0b1111);
        } else if (second.tag == .imm) {
            const ptr_size = try self.memSizeOrError(first.op.mem.size);
            const opcode: u8 = if (ptr_size == 1) 0xC6 else 0xC7;
            try self.memImmEncoding1(first, opcode, 0, second.op.imm.i);
        } else if (second.tag == .mem) {
            utils.printSrcLineError("second operand must be register or immediate value", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be register or memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn movzx(self: *Codegen, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    if (first.tag == .reg) {
        if (second.tag == .reg or second.tag == .mem) {
            const reg_size = first.op.reg.r.size();
            const rm_size = try self.rmSize(second);
            if (rm_size > 2) {
                utils.printSrcLineError("only 8- and 16-bit sizes allowed for second operand", self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
            if (reg_size <= rm_size) {
                utils.printSrcLineError("register size must be greater than second operand size", self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
            const opcode: u8 = if (rm_size == 1) 0xB6 else 0xB7;
            self.ibytes.reset();
            try self.ibytes.init(first.op.reg.r, second, opcode, self);
            self.ibytes.twobyteop = true;
            try self.appendInstrBytes();
            if (self.ibytes.reloc) |*reloc| {
                try self.program.relocations.append(utils.alloc, reloc.*);
            }
        } else {
            utils.printSrcLineError("second operand must be register or memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn lea(self: *Codegen, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    if (first.tag == .reg) {
        if (second.tag == .mem) {
            const opcode: u8 = 0x8D;
            try self.regMemEncoding(first.op.reg.r, second, opcode, 0b1110);
        } else {
            utils.printSrcLineError("second operand must be memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn push(self: *Codegen, operand: CodeOperand) CodegenError!void {
    if (operand.tag == .reg) {
        const opcode: u8 = 0x50;
        try self.opEncoding(operand.op.reg.r, opcode, 0b1010);
    } else if (operand.tag == .mem) {
        const opcode: u8 = 0xFF;
        try self.memEncoding(operand, 6, opcode, 0b1010, true);
    } else {
        const imm_size: u8 = switch (operand.tag) {
            .imm => operand.op.imm.i.fitsInBytes(),
            .lbl => 4,
            else => unreachable,
        };
        const opcode: u8 = if (imm_size == 1) 0x6A else 0x68;
        try self.immEncoding(operand, opcode, 0b0111);
    }
}

fn pop(self: *Codegen, operand: CodeOperand) CodegenError!void {
    if (operand.tag == .reg) {
        const opcode: u8 = 0x58;
        try self.opEncoding(operand.op.reg.r, opcode, 0b1010);
    } else if (operand.tag == .mem) {
        const opcode: u8 = 0x8F;
        try self.memEncoding(operand, 0, opcode, 0b1010, true);
    } else {
        utils.printSrcLineError("operand must be register or memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn jcc(self: *Codegen, mnem: TokenType, operand: CodeOperand) CodegenError!void {
    if (operand.tag == .lbl) {
        const opcode: u8 = switch (mnem) {
            .jo => 0x80,
            .jno => 0x81,
            .jb, .jc, .jnae => 0x82,
            .jae, .jnb, .jnc => 0x83,
            .je, .jz => 0x84,
            .jne, .jnz => 0x85,
            .jbe, .jna => 0x86,
            .ja, .jnbe => 0x87,
            .js => 0x88,
            .jns => 0x89,
            .jp, .jpe => 0x8A,
            .jnp, .jpo => 0x8B,
            .jl, .jnge => 0x8C,
            .jge, .jnl => 0x8D,
            .jle, .jng => 0x8E,
            .jg, .jnle => 0x8F,
            else => unreachable,
        };
        try self.jumpReloc(operand, mnem, opcode);
    } else {
        utils.printSrcLineErrorFmt("{t} instruction can jump only to label", .{mnem}, self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn jmp(self: *Codegen, operand: CodeOperand) CodegenError!void {
    if (operand.tag == .reg or operand.tag == .mem) {
        const opcode: u8 = 0xFF;
        try self.memEncoding(operand, 4, opcode, 0b1000, true);
    } else if (operand.tag == .lbl) {
        const opcode: u8 = 0xE9;
        try self.jumpReloc(operand, .jmp, opcode);
    } else {
        utils.printSrcLineError("cannot jump to immediate value", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn call(self: *Codegen, operand: CodeOperand) CodegenError!void {
    if (operand.tag == .reg or operand.tag == .mem) {
        const opcode: u8 = 0xFF;
        try self.memEncoding(operand, 2, opcode, 0b1000, true);
    } else if (operand.tag == .lbl) {
        if (utils.stringValue(operand.op.label.l)[0] == '.') {
            utils.printSrcLineError("call to function's local label is forbidden", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
        const opcode: u8 = 0xE8;
        try self.program.code_block.buffer.append(utils.alloc, opcode);
        try self.appendImmRelocation(operand, .Rel32C);
    } else {
        utils.printSrcLineError("cannot call to immediate value", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn ret(self: *Codegen, operands: []CodeOperand) CodegenError!void {
    if (operands.len == 0) {
        try self.program.code_block.buffer.append(utils.alloc, 0xC3);
    } else if (operands.len == 1) {
        const oper = operands[0];
        if (oper.tag == .imm) {
            const imm_size = oper.op.imm.i.fitsInBytes();
            if (imm_size <= 2) {
                try self.program.code_block.buffer.append(utils.alloc, 0xC2);
                try self.appendImmediateBytes(oper.op.imm.i, 2);
            } else {
                utils.printSrcLineError("immediate value doesn't fit in 2 bytes", self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
        } else {
            utils.printSrcLineError("operand must be immediate value", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    }
}

fn @"test"(self: *Codegen, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    if (second.tag == .imm) {
        if (first.tag == .reg) {
            if (first.op.reg.r.name.isAccumulator()) {
                const opcode: u8 = if (first.op.reg.r.name == .al) 0xA8 else 0xA9;
                try self.accImmEncoding(first.op.reg.r, opcode, second.op.imm.i);
            } else {
                const opcode: u8 = if (first.op.reg.r.size() == 1) 0xF6 else 0xF7;
                try self.memImmEncoding1(first, opcode, 0, second.op.imm.i);
            }
        } else if (first.tag == .mem) {
            const ptr_size = try self.memSizeOrError(first.op.mem.size);
            const opcode: u8 = if (ptr_size == 1) 0xF6 else 0xF7;
            try self.memImmEncoding1(first, opcode, 0, second.op.imm.i);
        } else {
            utils.printSrcLineError("first operand must be register or memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else if (second.tag == .reg) {
        if (first.tag == .reg or first.tag == .mem) {
            const opcode: u8 = if (second.op.reg.r.size() == 1) 0x84 else 0x85;
            try self.memRegEncoding(first, second.op.reg.r, opcode, 0b1111);
        } else {
            utils.printSrcLineError("first operand must be register or memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("second operand must be register or immediate value", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn group1(self: *Codegen, mnem: TokenType, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    if (first.tag == .reg) {
        if (second.tag == .reg) {
            var opcode: u8 = switch (mnem) {
                .adc => 0x11,
                .add => 0x01,
                .@"and" => 0x21,
                .cmp => 0x39,
                .@"or" => 0x09,
                .sbb => 0x19,
                .sub => 0x29,
                .xor => 0x31,
                else => unreachable,
            };
            if (first.op.reg.r.size() == 1) {
                opcode -= 1;
            }
            try self.memRegEncoding(first, second.op.reg.r, opcode, 0b1111);
        } else if (second.tag == .mem) {
            var opcode: u8 = switch (mnem) {
                .adc => 0x13,
                .add => 0x03,
                .@"and" => 0x23,
                .cmp => 0x3B,
                .@"or" => 0x0B,
                .sbb => 0x1B,
                .sub => 0x2B,
                .xor => 0x33,
                else => unreachable,
            };
            if (first.op.reg.r.size() == 1) {
                opcode -= 1;
            }
            try self.regMemEncoding(first.op.reg.r, second, opcode, 0b1111);
        } else if (second.tag == .imm) {
            if (first.op.reg.r.name.isAccumulator()) {
                var opcode: u8 = switch (mnem) {
                    .adc => 0x15,
                    .add => 0x05,
                    .@"and" => 0x25,
                    .cmp => 0x3D,
                    .@"or" => 0x0D,
                    .sbb => 0x1D,
                    .sub => 0x2D,
                    .xor => 0x35,
                    else => unreachable,
                };
                if (first.op.reg.r.size() == 1) {
                    opcode -= 1;
                }
                try self.accImmEncoding(first.op.reg.r, opcode, second.op.imm.i);
            } else {
                const reg_size = first.op.reg.r.size();
                const imm_size = second.op.imm.i.fitsInBytes();
                const digit: u8 = switch (mnem) {
                    .adc => 2,
                    .add => 0,
                    .@"and" => 4,
                    .cmp => 7,
                    .@"or" => 1,
                    .sbb => 3,
                    .sub => 5,
                    .xor => 6,
                    else => unreachable,
                };
                if (imm_size == 1 and reg_size > 1) {
                    const opcode: u8 = 0x83;
                    try self.memImmEncoding2(first, opcode, digit, second.op.imm.i);
                } else {
                    const opcode: u8 = if (reg_size == 1) 0x80 else 0x81;
                    try self.memImmEncoding1(first, opcode, digit, second.op.imm.i);
                }
            }
        } else {
            utils.printSrcLineError("second operand must be register, memory or immediate value", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else if (first.tag == .mem) {
        if (second.tag == .reg) {
            var opcode: u8 = switch (mnem) {
                .adc => 0x11,
                .add => 0x01,
                .@"and" => 0x21,
                .cmp => 0x39,
                .@"or" => 0x09,
                .sbb => 0x19,
                .sub => 0x29,
                .xor => 0x31,
                else => unreachable,
            };
            if (second.op.reg.r.size() == 1) {
                opcode -= 1;
            }
            try self.memRegEncoding(first, second.op.reg.r, opcode, 0b1111);
        } else if (second.tag == .imm) {
            const ptr_size = try self.memSizeOrError(first.op.mem.size);
            const imm_size = second.op.imm.i.fitsInBytes();
            const digit: u8 = switch (mnem) {
                .adc => 2,
                .add => 0,
                .@"and" => 4,
                .cmp => 7,
                .@"or" => 1,
                .sbb => 3,
                .sub => 5,
                .xor => 6,
                else => unreachable,
            };
            if (imm_size == 1 and ptr_size > 1) {
                const opcode: u8 = 0x83;
                try self.memImmEncoding2(first, opcode, digit, second.op.imm.i);
            } else {
                const opcode: u8 = if (ptr_size == 1) 0x80 else 0x81;
                try self.memImmEncoding1(first, opcode, digit, second.op.imm.i);
            }
        } else {
            utils.printSrcLineError("second operand must be register or immediate value", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be register or memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn group2(self: *Codegen, mnem: TokenType, operand: CodeOperand) CodegenError!void {
    const digit: u8 = switch (mnem) {
        .dec => 1,
        .inc => 0,
        .div => 6,
        .idiv => 7,
        .mul => 4,
        .neg => 3,
        .not => 2,
        else => unreachable,
    };
    var opcode: u8 = switch (mnem) {
        .dec, .inc => 0xFF,
        .div, .idiv, .mul, .neg, .not => 0xF7,
        else => unreachable,
    };
    if (operand.tag == .reg) {
        if (operand.op.reg.r.size() == 1) opcode -= 1;
    } else if (operand.tag == .mem) {
        if (operand.op.mem.size == 1) opcode -= 1;
    } else {
        utils.printSrcLineError("operand must be register or memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
    try self.memEncoding(operand, digit, opcode, 0b1111, false);
}

fn group3(self: *Codegen, mnem: TokenType, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    const opsize = switch (first.tag) {
        .reg => first.op.reg.r.size(),
        .mem => try self.memSizeOrError(first.op.mem.size),
        else => {
            utils.printSrcLineError("first operand must be register or memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        },
    };
    var opt_imm: ?Immediate = null;

    var opcode: u8 = undefined;
    if (second.tag == .imm) {
        const imm_size = second.op.imm.i.fitsInBytes();
        if (imm_size == 1) {
            const is_one = (second.op.imm.i.bits == 1);
            if (!is_one) opt_imm = second.op.imm.i;
            opcode = switch (opsize) {
                1 => if (is_one) 0xD0 else 0xC0,
                2, 4, 8 => if (is_one) 0xD1 else 0xC1,
                else => unreachable,
            };
        } else {
            utils.printSrcLineError("immediate value doesn't fit in 8 bits", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else if (second.tag == .reg and second.op.reg.r.name == .cl) {
        opcode = switch (opsize) {
            1 => 0xD2,
            2, 4, 8 => 0xD3,
            else => unreachable,
        };
    } else {
        utils.printSrcLineError("second operand must be imm8 value or cl register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
    const digit: u8 = switch (mnem) {
        .rcl => 2,
        .rcr => 3,
        .rol => 0,
        .ror => 1,
        .sal, .shl => 4,
        .sar => 7,
        .shr => 5,
        else => unreachable,
    };
    const reg = InstrBytes.digitToReg(digit);
    self.ibytes.reset();
    try self.ibytes.init(reg, first, opcode, self);
    self.ibytes.setOsRexW(opsize);
    try self.appendInstrBytes();
    if (opt_imm) |imm| {
        try self.appendImmediateBytes(imm, 1);
    }
    if (self.ibytes.reloc) |*reloc| {
        if (opt_imm != null) reloc.addend -= 1;
        try self.program.relocations.append(utils.alloc, reloc.*);
    }
}

const SseGroup = enum {
    r128rm128,
    r128r128m64,
    r128r128m32,
    r128r128m16,

    r128rm128i8,
    r128r128m64i8,
    r128r128m32i8,

    r128r128,
    r3264r128,

    r128m128,
    r128m64,

    mr,
    shift,
    extrinsr,
    converts,
    movdq,

    skip,
};

fn sseR128Rm(self: *Codegen, mnem: TokenType, operands: []CodeOperand, group: SseGroup) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    const mr: bool = switch (group) {
        .r128rm128 => switch (mnem) {
            .movapd, .movaps, .movdqa, .movdqu, .movupd, .movups => true,
            else => false,
        },
        .r128r128m64 => mnem == .movsd,
        .r128r128m32 => mnem == .movss,
        else => false,
    };
    const mem_sz: u8 = switch (group) {
        .r128rm128, .r128rm128i8 => 16,
        .r128r128m64, .r128r128m64i8 => 8,
        .r128r128m32, .r128r128m32i8 => 4,
        .r128r128m16 => 2,
        else => unreachable,
    };

    if (first.tag == .reg and first.op.reg.r.size() == 16) {
        if (second.tag == .reg and second.op.reg.r.size() == 16 or second.tag == .mem) {
            const opcode: u8 = @truncate(@intFromEnum(mnem));
            try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, mem_sz, false);
            if (operands.len == 3) {
                if (operands[2].tag == .imm and operands[2].op.imm.i.fitsInBytes() == 1) {
                    try self.program.code_block.buffer.append(utils.alloc, @truncate(operands[2].op.imm.i.bits));
                } else {
                    utils.printSrcLineError("third operand must be imm8 value", self.program, self.line);
                    return CodegenError.CodeGenFailed;
                }
            }
        } else {
            utils.printSrcLineError("second operand must be xmm register or memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else if (first.tag == .mem and mr) {
        if (second.tag == .reg and second.op.reg.r.size() == 16) {
            const opcode: u8 = switch (mnem) {
                .movapd, .movaps => 0x29,
                .movdqa, .movdqu => 0x7F,
                .movupd, .movups, .movsd, .movss => 0x11,
                else => unreachable,
            };
            try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, mem_sz, false);
            if (operands.len == 3) {
                if (operands[2].tag == .imm and operands[2].op.imm.i.fitsInBytes() == 1) {
                    try self.program.code_block.buffer.append(utils.alloc, @truncate(operands[2].op.imm.i.bits));
                } else {
                    utils.printSrcLineError("third operand must be imm8 value", self.program, self.line);
                    return CodegenError.CodeGenFailed;
                }
            }
        } else {
            utils.printSrcLineError("second operand must be xmm register", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else if (mr) {
        utils.printSrcLineError("first operand must be xmm register or memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    } else {
        utils.printSrcLineError("first operand must be xmm register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn sseRegR128(self: *Codegen, mnem: TokenType, operands: []CodeOperand, group: SseGroup) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    if (first.tag == .reg) {
        const reg_size = first.op.reg.r.size();
        if (reg_size == 16 and group != .r128r128 or (reg_size == 4 or reg_size == 8) and group != .r3264r128 or reg_size < 4) {
            utils.printSrcLineError("invalid register size", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
        if (second.tag == .reg and second.op.reg.r.size() == 16) {
            self.ibytes.reset();
            const pref_bits = @intFromEnum(mnem) & 0x1800;
            switch (pref_bits) {
                0x0 => {},
                0x800 => self.ibytes.os = true,
                0x1000 => self.ibytes.f3 = true,
                0x1800 => self.ibytes.f2 = true,
                else => unreachable,
            }
            const opcode_len_bits = @intFromEnum(mnem) & 0x6000;
            if (opcode_len_bits > 0) self.ibytes.twobyteop = true;
            if (opcode_len_bits == 0x4000) self.ibytes.threebyte38 = true else if (opcode_len_bits == 0x6000) self.ibytes.threebyte3a = true;
            const opcode: u8 = @truncate(@intFromEnum(mnem));
            try self.ibytes.init(first.op.reg.r, second, opcode, self);
            try self.appendInstrBytes();
            if (self.ibytes.reloc) |*reloc| {
                try self.program.relocations.append(utils.alloc, reloc.*);
            }
        } else {
            utils.printSrcLineError("second operand must be xmm register", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn sseR128M(self: *Codegen, mnem: TokenType, operands: []CodeOperand, group: SseGroup) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    const mr: bool = switch (mnem) {
        .movhpd, .movhps, .movlpd, .movlps => true,
        else => false,
    };
    const mem_sz: u8 = switch (group) {
        .r128m128 => 16,
        .r128m64 => 8,
        else => unreachable,
    };

    if (first.tag == .reg and first.op.reg.r.size() == 16) {
        if (second.tag == .mem) {
            const opcode: u8 = switch (mnem) {
                .movlps => 0x12,
                .movhps => 0x16,
                else => @truncate(@intFromEnum(mnem)),
            };
            try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, mem_sz, false);
        } else {
            utils.printSrcLineError("second operand must be memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else if (first.tag == .mem and mr) {
        if (second.tag == .reg and second.op.reg.r.size() == 16) {
            const opcode: u8 = switch (mnem) {
                .movhpd, .movhps => 0x17,
                .movlpd, .movlps => 0x13,
                else => unreachable,
            };
            try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, mem_sz, false);
        } else {
            utils.printSrcLineError("second operand must be xmm register", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else if (mr) {
        utils.printSrcLineError("first operand must be xmm register or memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    } else {
        utils.printSrcLineError("first operand must be xmm register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn sseMR(self: *Codegen, mnem: TokenType, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    const mem_sz: u8 = switch (mnem) {
        .movntdq, .movntpd, .movntps => 16,
        .movnti => 8,
        else => unreachable,
    };

    if (first.tag == .mem) {
        if (second.tag == .reg) {
            const opcode: u8 = @truncate(@intFromEnum(mnem));
            if (mem_sz == 16 or mnem == .movnti and second.op.reg.r.size() == 8) {
                try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, mem_sz, false);
            } else if (mnem == .movnti and second.op.reg.r.size() == 4) {
                try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, 4, false);
            } else {
                try self.invalOpSizesError();
            }
        } else {
            utils.printSrcLineError("second operand must be register", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn sseShift(self: *Codegen, mnem: TokenType, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    const reg_imm_only = mnem == .psrldq or mnem == .pslldq;
    if (first.tag == .reg and first.op.reg.r.size() == 16) {
        if (second.tag == .imm and second.op.imm.i.fitsInBytes() == 1) {
            const opcode: u8 = switch (mnem) {
                .psrlw, .psraw, .psllw => 0x71,
                .psrld, .psrad, .pslld => 0x72,
                .psrlq, .psrldq, .psllq, .pslldq => 0x73,
                else => unreachable,
            };
            const reg: Register = switch (mnem) {
                .psrlw, .psrld, .psrlq => InstrBytes.digitToReg(2),
                .psraw, .psrad => InstrBytes.digitToReg(4),
                .psllw, .pslld, .psllq => InstrBytes.digitToReg(6),
                .psrldq => InstrBytes.digitToReg(3),
                .pslldq => InstrBytes.digitToReg(7),
                else => unreachable,
            };
            try self.regMem128Encoding(mnem, opcode, reg, first, 16, false);
            try self.program.code_block.buffer.append(utils.alloc, @truncate(second.op.imm.i.bits));
        } else if (!reg_imm_only and (second.tag == .reg and second.op.reg.r.size() == 16 or second.tag == .mem)) {
            const opcode: u8 = switch (mnem) {
                .psrlw => 0xD1,
                .psraw => 0xE1,
                .psllw => 0xF1,
                .psrld => 0xD2,
                .psrad => 0xE2,
                .pslld => 0xF2,
                .psrlq => 0xD3,
                .psllq => 0xF3,
                else => unreachable,
            };
            try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, 16, false);
        } else if (!reg_imm_only) {
            utils.printSrcLineError("second operand must be xmm register, memory or imm8 value", self.program, self.line);
            return CodegenError.CodeGenFailed;
        } else {
            utils.printSrcLineError("second operand must be xmm register or imm8 value", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be xmm register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn sseExtrInsr(self: *Codegen, mnem: TokenType, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    const third = operands[2];
    const rm = switch (mnem) {
        .pinsrb, .pinsrw, .pinsrd, .pinsrq => true,
        else => false,
    };
    if (third.tag == .imm and third.op.imm.i.fitsInBytes() == 1) {
        if (rm and first.tag == .reg and first.op.reg.r.size() == 16) {
            if (second.tag == .reg or second.tag == .mem) {
                const mem_sz: u8 = switch (mnem) {
                    .pinsrb => 1,
                    .pinsrw => 2,
                    .pinsrd => 4,
                    .pinsrq => 8,
                    else => unreachable,
                };
                if (second.tag == .mem and second.op.mem.size > 0 and second.op.mem.size != mem_sz or
                    second.tag == .reg and (second.op.reg.r.size() != 4 and second.op.reg.r.size() != 8 or (mem_sz == 8 and second.op.reg.r.size() != 8 or mem_sz == 4 and second.op.reg.r.size() != 4)))
                {
                    try self.invalOpSizesError();
                }
                const opcode: u8 = switch (mnem) {
                    .pinsrq => 0x22,
                    else => @truncate(@intFromEnum(mnem)),
                };
                try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, mem_sz, mem_sz == 8);
                try self.program.code_block.buffer.append(utils.alloc, @truncate(third.op.imm.i.bits));
            } else {
                utils.printSrcLineError("second operand must be register or memory", self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
        } else if (!rm and first.tag == .reg and first.op.reg.r.size() < 16 or first.tag == .mem) {
            if (second.tag == .reg and second.op.reg.r.size() == 16) {
                const mem_sz: u8 = switch (mnem) {
                    .pextrb => 1,
                    .pextrw => 2,
                    .pextrd, .extractps => 4,
                    .pextrq => 8,
                    else => unreachable,
                };
                if (first.tag == .mem and first.op.mem.size > 0 and first.op.mem.size != mem_sz or
                    first.tag == .reg and (first.op.reg.r.size() != 4 and first.op.reg.r.size() != 8 or (mem_sz == 8 and first.op.reg.r.size() != 8 or mnem == .pextrd and first.op.reg.r.size() != 4)))
                {
                    try self.invalOpSizesError();
                }
                const opcode: u8 = switch (mnem) {
                    .pextrq => 0x16,
                    else => @truncate(@intFromEnum(mnem)),
                };
                try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, mem_sz, mem_sz == 8);
                try self.program.code_block.buffer.append(utils.alloc, @truncate(third.op.imm.i.bits));
            } else {
                utils.printSrcLineError("second operand must be xmm register", self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
        } else if (rm) {
            utils.printSrcLineError("first operand must be xmm register", self.program, self.line);
            return CodegenError.CodeGenFailed;
        } else {
            utils.printSrcLineError("first operand must be register or memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("third operand must be imm8 value", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn sseConverts(self: *Codegen, mnem: TokenType, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    if (first.tag == .reg) {
        if (second.tag == .reg or second.tag == .mem) {
            const reg_size = first.op.reg.r.size();
            switch (mnem) {
                .cvtsi2sd, .cvtsi2ss => {
                    if (reg_size != 16) {
                        try self.invalOpSizesError();
                    }
                    const opcode: u8 = 0x2A;
                    const rm_size = try self.rmSize(second);
                    if (rm_size == 4 or rm_size == 8) {
                        try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, rm_size, rm_size == 8);
                    } else {
                        try self.invalOpSizesError();
                    }
                },
                .cvtsd2si, .cvtss2si, .cvttsd2si, .cvttss2si => {
                    if (reg_size != 4 and reg_size != 8 or (second.tag == .reg and second.op.reg.r.size() != 16)) {
                        try self.invalOpSizesError();
                    }
                    const opcode: u8 = @truncate(@intFromEnum(mnem));
                    const mem_size: u8 = switch (mnem) {
                        .cvtsd2si, .cvttsd2si => 8,
                        else => 4,
                    };
                    try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, mem_size, reg_size == 8);
                },
                else => unreachable,
            }
        } else {
            utils.printSrcLineError("second operand must be register or memory", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be register", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn sseMovdQ(self: *Codegen, mnem: TokenType, operands: []CodeOperand) CodegenError!void {
    const first = operands[0];
    const second = operands[1];
    const mem_size: u8 = if (mnem == .movd) 4 else 8;
    if (first.tag == .reg) {
        const reg_size = first.op.reg.r.size();
        if (reg_size == 16) {
            if (second.tag == .reg) {
                const reg2_size = second.op.reg.r.size();
                if (reg2_size == 16 and mnem == .movq) {
                    const opcode: u8 = @truncate(@intFromEnum(mnem));
                    try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, 16, false);
                } else if (reg2_size == 8 and mnem == .movq or reg2_size == 4 and mnem == .movd) {
                    const opcode: u8 = 0x6E;
                    try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, 16, mnem == .movq);
                } else {
                    try self.invalOpSizesError();
                }
            } else if (second.tag == .mem) {
                const opcode: u8 = 0x6E;
                try self.regMem128Encoding(mnem, opcode, first.op.reg.r, second, mem_size, mnem == .movq);
            } else {
                utils.printSrcLineError("second operand must be register or memory", self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
        } else if (reg_size == 4 and mnem == .movd or reg_size == 8 and mnem == .movq) {
            if (second.tag == .reg and second.op.reg.r.size() == 16) {
                const opcode: u8 = 0x7E;
                try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, mem_size, mnem == .movq);
            } else {
                utils.printSrcLineError("second operand must be xmm register", self.program, self.line);
                return CodegenError.CodeGenFailed;
            }
        } else {
            try self.invalOpSizesError();
        }
    } else if (first.tag == .mem) {
        if (second.tag == .reg and second.op.reg.r.size() == 16) {
            const opcode: u8 = 0x7E;
            try self.regMem128Encoding(mnem, opcode, second.op.reg.r, first, mem_size, mnem == .movq);
        } else {
            utils.printSrcLineError("second operand must be xmm register", self.program, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        utils.printSrcLineError("first operand must be register or memory", self.program, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn genInstruction(self: *Codegen, instr: Program.CodeInstruction) CodegenError!void {
    switch (instr) {
        .label => {
            const label = instr.label.name;
            const is_func = self.program.funcs.getPtr(label);
            if (is_func) |func| {
                try self.patchTempRelocs();
                const prev_func = self.program.funcs.getPtr(self.cur_func);
                if (prev_func) |prev| {
                    prev.size = @truncate(self.program.code_block.buffer.items.len - prev.offset);
                }
                func.offset = @truncate(self.program.code_block.buffer.items.len);
                if (self.program.flags.has_entry and self.program.entry == label) {
                    func.visib = .Export;
                }
                self.cur_func = label;
            } else {
                const function = self.program.funcs.getPtr(self.cur_func);
                if (function) |func| {
                    const lbl_ptr = func.local_labels.getPtr(label);
                    if (lbl_ptr) |ptr| {
                        ptr.* = @truncate(self.program.code_block.buffer.items.len);
                    }
                }
            }
        },
        .cpu => |cpuinstr| {
            if (utils.flags.debug) {
                try self.program.line_program.append(utils.alloc, .{ .offset = @truncate(self.program.code_block.buffer.items.len), .line = self.line });
            }
            const operands = self.program.code_block.operands.items[cpuinstr.operands.index .. cpuinstr.operands.index + cpuinstr.operands.len];
            const start = self.program.code_block.buffer.items.len;
            switch (cpuinstr.mnem) {
                .mov => try self.mov(operands),
                .movzx => try self.movzx(operands),
                .lea => try self.lea(operands),
                .push => try self.push(operands[0]),
                .pop => try self.pop(operands[0]),
                .call => try self.call(operands[0]),
                .ret => try self.ret(operands),
                .syscall => try self.syscall(),
                .jmp => try self.jmp(operands[0]),
                .ja, .jae, .jb, .jbe, .jc, .je, .jg, .jge, .jl, .jle, .jna, .jnae, .jnb, .jnbe, .jnc, .jne, .jng, .jnge, .jnl, .jnle, .jno, .jnp, .jns, .jnz, .jo, .jp, .jpe, .jpo, .js, .jz => try self.jcc(cpuinstr.mnem, operands[0]),
                .adc, .add, .@"and", .cmp, .@"or", .sbb, .sub, .xor => try self.group1(cpuinstr.mnem, operands),
                .dec, .div, .idiv, .inc, .mul, .neg, .not => try self.group2(cpuinstr.mnem, operands[0]),
                .sal, .sar, .shl, .shr, .rcl, .rcr, .rol, .ror => try self.group3(cpuinstr.mnem, operands),
                .@"test" => try self.@"test"(operands),
                else => {
                    const sse = sseMnemGroup(cpuinstr.mnem);
                    switch (sse) {
                        .r128rm128,
                        .r128r128m64,
                        .r128r128m32,
                        .r128r128m16,
                        .r128rm128i8,
                        .r128r128m64i8,
                        .r128r128m32i8,
                        => try self.sseR128Rm(cpuinstr.mnem, operands, sse),
                        .r128r128, .r3264r128 => try self.sseRegR128(cpuinstr.mnem, operands, sse),
                        .r128m128, .r128m64 => try self.sseR128M(cpuinstr.mnem, operands, sse),
                        .mr => try self.sseMR(cpuinstr.mnem, operands),
                        .shift => try self.sseShift(cpuinstr.mnem, operands),
                        .extrinsr => try self.sseExtrInsr(cpuinstr.mnem, operands),
                        .converts => try self.sseConverts(cpuinstr.mnem, operands),
                        .movdq => try self.sseMovdQ(cpuinstr.mnem, operands),
                        .skip => {
                            utils.printSrcLineErrorFmt("unsupported instruction: {t}", .{cpuinstr.mnem}, self.program, self.line);
                            return CodegenError.CodeGenFailed;
                        },
                    }
                },
            }
            const end = self.program.code_block.buffer.items.len;
            if (!utils.flags.quiet) {
                for (self.program.code_block.buffer.items[start..end]) |byte| {
                    std.debug.print("{x:02} ", .{byte});
                }
                std.debug.print("\x1b[30G", .{});
                self.program.printCPUInstruction(cpuinstr);
                std.debug.print("\n", .{});
            }
        },
    }
}

pub fn generateCode(self: *Codegen) CodegenError!void {
    for (self.program.code_block.instr.items) |instr| {
        const line = switch (instr) {
            .cpu => instr.cpu.line,
            .label => instr.label.line,
        };
        self.line = line;
        try self.genInstruction(instr);
    }
    const cur_func = self.program.funcs.getPtr(self.cur_func);
    if (cur_func) |cur| {
        cur.size = @truncate(self.program.code_block.buffer.items.len - cur.offset);
        try self.patchTempRelocs();
    }
    if (utils.flags.debug) {
        try self.program.line_program.append(utils.alloc, .{
            .offset = @truncate(self.program.code_block.buffer.items.len),
            .line = self.program.line_program.items[self.program.line_program.items.len - 1].line + 1,
        });
    }
}

fn patchTempRelocs(self: *Codegen) CodegenError!void {
    for (self.temp_relocs.items) |reloc| {
        const func_ptr = self.program.funcs.getPtr(self.cur_func).?;
        const target_offset = func_ptr.local_labels.getPtr(reloc.name).?.*;
        const disp: i32 = @truncate(@as(i64, target_offset -% reloc.offset) + reloc.addend);
        std.mem.writeInt(u32, @ptrCast(self.program.code_block.buffer.items[reloc.offset .. reloc.offset + 4]), @bitCast(disp), .little);
    }
    self.temp_relocs.clearRetainingCapacity();
}

fn sseMnemGroup(mnem: TokenType) SseGroup {
    return switch (mnem) {
        // zig fmt: off
        .addpd, .addps, .addsubpd, .addsubps, .andnpd, .andnps, .andpd,
        .andps, .blendvpd, .blendvps, .cvtdq2ps, .cvtpd2dq, .cvtpd2ps, 
        .cvtps2dq, .cvttpd2dq, .cvttps2dq, .divpd, .divps, .haddpd, 
        .haddps, .hsubpd, .hsubps, .maxpd, .maxps, .minpd, .minps, .movapd, 
        .movaps, .movdqa, .movdqu, .movshdup, .movsldup, .movupd, .movups, 
        .mulpd, .mulps, .orpd, .orps, .pabsb, .pabsw, .pabsd, .packsswb, 
        .packssdw, .packusdw, .packuswb, .paddb, .paddw, .paddd, .paddq, 
        .paddsb, .paddsw, .paddusb, .paddusw, .pand, .pandn, .pavgb, .pavgw, 
        .pblendvb, .pcmpeqb, .pcmpeqw, .pcmpeqd, .pcmpeqq, .pcmpgtb, .pcmpgtw, 
        .pcmpgtd, .pcmpgtq, .phaddsw, .phaddw, .phaddd, .phminposuw, .phsubsw, 
        .phsubw, .phsubd, .pmaddubsw, .pmaddwd, .pmaxsb, .pmaxsw, .pmaxsd, 
        .pmaxub, .pmaxuw, .pmaxud, .pminsb, .pminsw, .pminsd, .pminub, .pminuw, 
        .pminud, .pmuldq, .pmulhrsw, .pmulhuw, .pmulhw, .pmulld, .pmullw, 
        .pmuludq, .por, .psadbw, .pshufb, .psignb, .psignw, .psignd, .psubb, 
        .psubw, .psubd, .psubq, .psubsb, .psubsw, .psubusb, .psubusw, .ptest, 
        .punpckhbw, .punpckhwd, .punpckhdq, .punpckhqdq, .punpcklbw, .punpcklwd, 
        .punpckldq, .punpcklqdq, .pxor, .rcpps, .rsqrtps, .sqrtpd, .sqrtps, 
        .subpd, .subps, .unpckhpd, .unpckhps, .unpcklpd, .unpcklps, .xorpd, 
        .xorps 
        => .r128rm128,
        .addsd, .comisd, .cvtdq2pd, .cvtps2pd, .cvtsd2ss, .divsd, .maxsd,
        .minsd, .movddup, .movsd, .mulsd, .pmovsxbw, .pmovsxwd, .pmovsxdq,
        .pmovzxbw, .pmovzxwd, .pmovzxdq, .sqrtsd, .subsd, .ucomisd 
        => .r128r128m64,
        .addss, .comiss, .cvtss2sd, .divss, .maxss, .minss, .movss, .mulss,
        .pmovsxbd, .pmovsxwq, .pmovzxbd, .pmovzxwq, .rcpss, .rsqrtss, .sqrtss,
        .subss, .ucomiss 
        => .r128r128m32,
        .pmovsxbq, .pmovzxbq 
        => .r128r128m16,
        .blendpd, .blendps, .cmppd, .cmpps, .dppd, .dpps, .mpsadbw, .palignr,
        .pblendw, .pclmulqdq, .pcmpestri, .pcmpestrm, .pcmpistri, .pcmpistrm, 
        .pshufd, .pshufhw, .pshuflw, .roundpd, .roundps, .shufpd, .shufps
        => .r128rm128i8,
        .cmpsd, .roundsd
        => .r128r128m64i8,
        .cmpss, .insertps, .roundss
        => .r128r128m32i8,
        .maskmovdqu, .movhlps, .movlhps
        => .r128r128,
        .movmskpd, .movmskps, .pmovmskb
        => .r3264r128,
        .movntdqa, .lddqu
        => .r128m128,
        .movhpd, .movhps, .movlpd, .movlps, .cvtpi2pd, .cvtpi2ps
        => .r128m64,
        .movntdq, .movntpd, .movntps, .movnti
        => .mr,
        .psrlw, .psraw, .psllw, .psrld, .psrad, .pslld, .psrlq, .psrldq, .psllq, 
        .pslldq
        => .shift,
        .pextrb, .pextrw, .pextrd, .pextrq, .extractps, .pinsrb, .pinsrw, .pinsrd, 
        .pinsrq
        => .extrinsr,
        .cvtsd2si, .cvttsd2si, .cvtss2si, .cvttss2si, .cvtsi2sd, .cvtsi2ss
        => .converts,
        .movd, .movq
        => .movdq,
        else => .skip,
        // zig fmt: on
    };
}
