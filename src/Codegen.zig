const std = @import("std");
const errprint = @import("errprint");

const lexer = @import("lexer");
const TokenType = lexer.TokenType;

const Program = @import("Program");
const Register = Program.Register;
const Displacement = Program.Displacement;
const Immediate = Program.Immediate;
const Scale = Program.Scale;
const Address = Program.Address;
const MemOperand = Program.MemOperand;
const CodeOperand = Program.CodeOperand;
const CpuInstruction = Program.CpuInstruction;
const LabelInstruction = Program.LabelInstruction;
const DataOperand = Program.DataOperand;
const DataInstruction = Program.DataInstruction;
const CodeInstruction = Program.CodeInstruction;
const DataBlock = Program.DataBlock;
const CodeBlock = Program.CodeBlock;
const Symbol = Program.Symbol;
const RelType = Program.RelType;
const Relocation = Program.Relocation;

const Operands = std.ArrayList(CodeOperand);

const Codegen = @This();

pub const CodegenError = error{CodeGenFailed} || std.mem.Allocator.Error;

const ModRmByte = packed struct {
    rm: u3,
    reg: u3,
    mod: u2,

    pub fn byte(self: ModRmByte) u8 {
        return (@as(u8, self.mod) << 6) | (@as(u8, self.reg) << 3) | (self.rm);
    }
};

const SibByte = packed struct {
    base: u3,
    index: u3,
    ss: u2,

    pub fn byte(self: SibByte) u8 {
        return (@as(u8, self.ss) << 6) | (@as(u8, self.index) << 3) | (self.base);
    }
};

const RexByte = packed struct {
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
    as: bool,
    os: bool,
    rex: RexByte,
    opcode: u8,
    modrm: ?ModRmByte,
    need_sib: bool,
    sib: ?SibByte,
    disp: ?Displacement,
    disp_bytes: u8,

    reloc: ?Relocation,

    const empty = @This(){
        .as = false,
        .os = false,
        .rex = RexByte.default(),
        .opcode = 0x00,
        .modrm = null,
        .sib = null,
        .disp = null,
        .disp_bytes = 0,
        .need_sib = false,
        .reloc = null,
    };

    pub fn reset(self: *InstrBytes) void {
        self.* = empty;
    }

    fn regCode(reg: TokenType) u3 {
        switch (reg) {
            .rax, .eax, .ax, .al, .r8, .r8d, .r8w, .r8b => return 0b000,
            .rcx, .ecx, .cx, .cl, .r9, .r9d, .r9w, .r9b => return 0b001,
            .rdx, .edx, .dx, .dl, .r10, .r10d, .r10w, .r10b => return 0b010,
            .rbx, .ebx, .bx, .bl, .r11, .r11d, .r11w, .r11b => return 0b011,
            .rsp, .esp, .sp, .ah, .spl, .r12, .r12d, .r12w, .r12b => return 0b100,
            .rbp, .ebp, .bp, .ch, .bpl, .r13, .r13d, .r13w, .r13b => return 0b101,
            .rsi, .esi, .si, .dh, .sil, .r14, .r14d, .r14w, .r14b => return 0b110,
            .rdi, .edi, .di, .bh, .dil, .r15, .r15d, .r15w, .r15b => return 0b111,
            else => return 0,
        }
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

    fn sibByte(self: *InstrBytes, addr: Address) void {
        var bs: u3 = undefined;
        var ind: u3 = undefined;
        var ss: u2 = undefined;

        if (addr.scale) |sc| {
            switch (sc) {
                1 => ss = 0b00,
                2 => ss = 0b01,
                4 => ss = 0b10,
                8 => ss = 0b11,
                else => unreachable,
            }
        } else {
            ss = 0b00;
        }

        if (addr.index) |i| {
            ind = regCode(i.name);
            if (i.name.isAdditionalReg()) {
                self.rex.setX();
            }
            self.as = (i.size == 4);
        } else {
            ind = 0b100;
        }

        if (addr.base) |b| {
            bs = regCode(b.name);
            if (b.name.isAdditionalReg()) {
                self.rex.setB();
            }
            self.as = (b.size == 4);
        } else {
            bs = 0b101;
        }

        self.sib = SibByte{ .base = bs, .index = ind, .ss = ss };
    }

    fn modRM(self: *InstrBytes, reg: Register, rm: CodeOperand, codegen: *const Codegen) CodegenError!void {
        var mod: u2 = undefined;
        var rm_code: u3 = undefined;
        const reg_code: u3 = regCode(reg.name);
        self.setOsRexW(reg.size);
        if (reg.name.isAdditionalReg()) {
            self.rex.setR();
        } else if (reg.name.isByteRegAdditional()) {
            self.rex.rex = 0b0100;
        }
        switch (rm) {
            .reg => {
                mod = 0b11;
                rm_code = regCode(rm.reg.name);
                if (rm.reg.name.isAdditionalReg()) {
                    self.rex.setB();
                } else if (reg.name.isByteRegAdditional()) {
                    self.rex.rex = 0b0100;
                }
            },
            .mem => {
                if (rm.mem.addr.label) |label| {
                    try codegen.checkLabelDefined(label);
                    self.reloc = .empty;
                    self.reloc.?.name = label;
                    self.disp = rm.mem.addr.disp orelse 0;
                    self.disp_bytes = 4;
                    if (rm.mem.addr.index == null) {
                        if (rm.mem.addr.base == null or rm.mem.addr.base.?.name == .rip) {
                            mod = 0b00;
                            rm_code = 0b101;
                            self.reloc.?.type = .Rel32D;
                        } else {
                            if (codegen.program.flags.pic) {
                                errprint.printSrcLineError("label with base syntax cannot be used with -pic flag", codegen.program.file_name, codegen.program.content, codegen.line);
                                return CodegenError.CodeGenFailed;
                            } else if (codegen.program.flags.warnings) {
                                errprint.printSrcLineWarning("address will be truncated to 32-bit", codegen.program.file_name, codegen.program.content, codegen.line);
                            }
                            mod = 0b10;
                            rm_code = regCode(rm.mem.addr.base.?.name);
                            if (rm_code == 0b100) {
                                self.need_sib = true;
                            }
                            self.reloc.?.type = .Abs32S;
                        }
                    } else {
                        if (codegen.program.flags.pic) {
                            errprint.printSrcLineError("label with index syntax cannot be used with -pic flag", codegen.program.file_name, codegen.program.content, codegen.line);
                            return CodegenError.CodeGenFailed;
                        } else if (codegen.program.flags.warnings) {
                            errprint.printSrcLineWarning("address will be truncated to 32-bit", codegen.program.file_name, codegen.program.content, codegen.line);
                        }
                        mod = 0b10;
                        rm_code = 0b100;
                        self.need_sib = true;
                        self.reloc.?.type = .Abs32S;
                        if (rm.mem.addr.base == null) {
                            mod = 0b00;
                        } else {}
                    }
                } else {
                    const disp_size = dispMinSize(rm.mem.addr.disp);
                    if (rm.mem.addr.index == null) {
                        if (rm.mem.addr.base) |base| {
                            if (base.name == .rip) {
                                mod = 0b00;
                                rm_code = 0b101;
                                self.disp = rm.mem.addr.disp orelse 0;
                                self.disp_bytes = 4;
                            } else {
                                rm_code = regCode(base.name);
                                if (base.name.isAdditionalReg()) {
                                    self.rex.setB();
                                }
                                self.as = (base.size == 4);
                                self.disp_bytes = disp_size;
                                self.disp = rm.mem.addr.disp;
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
                            if (rm.mem.addr.disp) |disp| {
                                self.need_sib = true;
                                mod = 0b00;
                                rm_code = 0b100;
                                self.disp = disp;
                                self.disp_bytes = 4;
                            } else {
                                unreachable;
                            }
                        }
                    } else {
                        self.need_sib = true;
                        if (rm.mem.addr.base) |base| {
                            rm_code = regCode(base.name);
                            if (disp_size == 0) {
                                mod = 0b00;
                            } else if (disp_size == 1) {
                                mod = 0b01;
                            } else if (disp_size == 4) {
                                mod = 0b10;
                            }
                            self.disp_bytes = disp_size;
                            self.disp = rm.mem.addr.disp;
                            if (rm_code == 0b101) {
                                if (disp_size < 4) {
                                    mod = 0b01;
                                    self.disp = self.disp orelse 0;
                                    self.disp_bytes = 1;
                                }
                            } else {}
                            rm_code = 0b100;
                        } else {
                            mod = 0b00;
                            rm_code = 0b100;
                            self.disp_bytes = 4;
                            self.disp = rm.mem.addr.disp orelse 0;
                        }
                    }
                }
            },
            else => unreachable,
        }
        self.modrm = ModRmByte{ .mod = mod, .reg = reg_code, .rm = rm_code };
    }

    fn swapBaseIndex(mem: *Address, codegen: *const Codegen) CodegenError!void {
        if (mem.index) |index| {
            var with_scale = false;
            if (mem.scale) |scale| {
                if (scale > 1) {
                    with_scale = true;
                }
            }
            const index_code = regCode(index.name);
            if (index_code == 0b100 and !index.name.isAdditionalReg()) {
                if (!with_scale) {
                    if (mem.base) |base| {
                        const base_code = regCode(base.name);
                        if (base_code != 0b100 or base.name.isAdditionalReg()) {
                            const temp = mem.base;
                            mem.base = mem.index;
                            mem.index = temp;
                        } else {
                            errprint.printSrcLineErrorFmt("{t} as index is not allowed", .{index.name}, codegen.program.file_name, codegen.program.content, codegen.line);
                            return CodegenError.CodeGenFailed;
                        }
                    }
                } else {
                    errprint.printSrcLineErrorFmt("{t} as index is not allowed", .{index.name}, codegen.program.file_name, codegen.program.content, codegen.line);
                    return CodegenError.CodeGenFailed;
                }
            }
        }
    }

    pub fn define(self: *InstrBytes, reg: Register, rm: CodeOperand, opcode: u8, codegen: *const Codegen) CodegenError!void {
        self.reset();
        self.opcode = opcode;
        var checked: CodeOperand = rm;
        switch (checked) {
            .mem => try swapBaseIndex(&checked.mem.addr, codegen),
            else => {},
        }
        try self.modRM(reg, checked, codegen);
        if (self.modrm) |_| {
            if (self.need_sib) {
                self.sibByte(checked.mem.addr);
            }
        }
        if (self.rex.byte() > 0x00) {
            if (reg.name.isByteRegHigh()) {
                errprint.printSrcLineErrorFmt("{t} register not encodable with REX prefix", .{reg.name}, codegen.program.file_name, codegen.program.content, codegen.line);
                return CodegenError.CodeGenFailed;
            }
            switch (rm) {
                .reg => {
                    if (rm.reg.name.isByteRegHigh()) {
                        errprint.printSrcLineErrorFmt("{t} register not encodable with REX prefix", .{rm.reg.name}, codegen.program.file_name, codegen.program.content, codegen.line);
                        return CodegenError.CodeGenFailed;
                    }
                },
                else => {},
            }
        }
    }
};

program: *Program,
ibytes: InstrBytes,
line: u16,
cur_func: []const u8,
temp_relocs: std.ArrayList(Relocation),

pub fn init(program: *Program) Codegen {
    return Codegen{
        .program = program,
        .ibytes = .empty,
        .line = 1,
        .cur_func = &.{},
        .temp_relocs = .empty,
    };
}

pub fn deinit(self: *Codegen) void {
    self.temp_relocs.deinit(self.program.alloc);
}

fn dispMinSize(disp: ?Displacement) u8 {
    if (disp) |d| {
        if (d == 0) {
            return 0;
        } else if (d <= std.math.maxInt(i8) and d >= std.math.minInt(i8)) {
            return 1;
        } else {
            return 4;
        }
    } else {
        return 0;
    }
}

fn appendInstrBytes(self: *Codegen) std.mem.Allocator.Error!void {
    if (self.ibytes.as) {
        try self.program.code_block.buffer.append(self.program.alloc, 0x67);
    }
    if (self.ibytes.os) {
        try self.program.code_block.buffer.append(self.program.alloc, 0x66);
    }
    if (self.ibytes.rex.byte() > 0x00) {
        self.ibytes.rex.rex = 0b0100;
        try self.program.code_block.buffer.append(self.program.alloc, self.ibytes.rex.byte());
    }
    try self.program.code_block.buffer.append(self.program.alloc, self.ibytes.opcode);
    if (self.ibytes.modrm) |modrm| {
        try self.program.code_block.buffer.append(self.program.alloc, modrm.byte());
    }
    if (self.ibytes.sib) |sib| {
        try self.program.code_block.buffer.append(self.program.alloc, sib.byte());
    }
    if (self.ibytes.disp) |disp| {
        if (self.ibytes.reloc) |*reloc| {
            reloc.addend = disp - 4;
            reloc.offset = self.program.code_block.buffer.items.len;
            try self.appendDisplacement(0, 4);
        } else {
            try self.appendDisplacement(disp, self.ibytes.disp_bytes);
        }
    }
}

fn checkLabelDefined(self: *const Codegen, label: []const u8) CodegenError!void {
    const in_funcs = self.program.funcs.get(label);
    if (in_funcs == null) {
        const in_datavars = self.program.data_vars.get(label);
        if (in_datavars == null) {
            const in_imports = self.program.imports.get(label);
            if (in_imports == null) {
                errprint.printSrcLineErrorFmt("reference to undefined label '{s}'", .{label}, self.program.file_name, self.program.content, self.line);
                return CodegenError.CodeGenFailed;
            }
        }
    }
}

fn appendImmRelocation(self: *Codegen, imm: CodeOperand, rel_type: RelType) CodegenError!void {
    try self.checkLabelDefined(imm.label.l);
    var reloc = Relocation{
        .offset = self.program.code_block.buffer.items.len,
        .name = imm.label.l,
        .type = rel_type,
        .addend = switch (imm.label.d) {
            .i => imm.label.d.i,
            .u => @bitCast(imm.label.d.u),
        },
    };
    if (rel_type == .Rel32C or rel_type == .Rel32D) {
        reloc.addend -= 4;
    }
    try self.program.relocations.append(self.program.alloc, reloc);
    const reloc_size: u8 = switch (rel_type) {
        .Abs32, .Abs32S, .Rel32C, .Rel32D => 4,
        .Abs64 => 8,
    };
    try self.appendImmediateBytes(.{ .u = 0 }, reloc_size);
}

fn appendImmediateBytes(self: *Codegen, imm: Immediate, bytes: u8) std.mem.Allocator.Error!void {
    const value: u64 = switch (imm) {
        .i => @bitCast(imm.i),
        .u => imm.u,
    };
    const array = std.mem.toBytes(value);
    try self.program.code_block.buffer.appendSlice(self.program.alloc, array[0..bytes]);
}

fn appendDisplacement(self: *Codegen, disp: Displacement, bytes: u8) std.mem.Allocator.Error!void {
    const value: u32 = @bitCast(disp);
    const array = std.mem.toBytes(value);
    try self.program.code_block.buffer.appendSlice(self.program.alloc, array[0..bytes]);
}

fn nearJump(self: *Codegen, imm: CodeOperand, mnem: TokenType, opcode: u8) CodegenError!void {
    if (mnem == .jmp) {
        try self.program.code_block.buffer.append(self.program.alloc, 0xE9);
    } else {
        try self.program.code_block.buffer.appendSlice(self.program.alloc, &.{ 0x0F, opcode });
    }
    try self.temp_relocs.append(self.program.alloc, .{
        .name = imm.label.l,
        .offset = self.program.code_block.buffer.items.len,
        .type = .Rel32C,
        .addend = switch (imm.label.d) {
            .i => imm.label.d.i,
            .u => @as(i64, @bitCast(imm.label.d.u)),
        } - 4,
    });
    try self.appendImmediateBytes(.{ .u = 0 }, 4);
}

fn jumpReloc(self: *Codegen, imm: CodeOperand, mnem: TokenType, opcode: u8) CodegenError!void {
    if (self.program.funcs.getPtr(self.cur_func)) |func_ptr| {
        const local_lbl = func_ptr.local_labels.get(imm.label.l);
        if (local_lbl) |local| {
            if (local == std.math.maxInt(usize)) {
                try self.nearJump(imm, mnem, opcode);
            } else {
                const disp = imm.label.d;
                const diff = @as(isize, @intCast(self.program.code_block.buffer.items.len)) - @as(isize, @intCast(local)) + switch (disp) {
                    .u => @as(isize, @bitCast(disp.u)),
                    .i => @as(isize, @intCast(disp.i)),
                };
                if (diff < 0x7F) {
                    const disp_byte: i8 = @truncate(-(diff + 2));
                    if (mnem == .jmp) {
                        try self.program.code_block.buffer.appendSlice(self.program.alloc, &.{ 0xEB, @bitCast(disp_byte) });
                    } else {
                        try self.program.code_block.buffer.appendSlice(self.program.alloc, &.{ opcode - 0x10, @bitCast(disp_byte) });
                    }
                } else {
                    try self.nearJump(imm, mnem, opcode);
                }
            }
            return;
        }
    }
    if (mnem == .jmp) {
        try self.program.code_block.buffer.append(self.program.alloc, 0xE9);
    } else {
        try self.program.code_block.buffer.appendSlice(self.program.alloc, &.{ 0x0F, opcode });
    }
    try self.appendImmRelocation(imm, .Rel32C);
}

// Encodings

fn regMemEnconding(self: *Codegen, reg: Register, rm: CodeOperand, opcode: u8, sizes: u4) CodegenError!void {
    const reg_size = reg.size;
    var rm_size: u8 = undefined;
    switch (rm) {
        .reg => rm_size = rm.reg.size,
        .mem => rm_size = rm.mem.size orelse reg_size,
        else => unreachable,
    }
    if (rm_size == reg_size) {
        if (rm_size & sizes == rm_size) {
            try self.ibytes.define(reg, rm, opcode, self);
            try self.appendInstrBytes();
            if (self.ibytes.reloc) |*reloc| {
                try self.program.relocations.append(self.program.alloc, reloc.*);
            }
        } else {
            errprint.printSrcLineError("invalid operand size", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        }
    } else {
        switch (rm) {
            .reg => errprint.printSrcLineError("registers sizes don't match", self.program.file_name, self.program.content, self.line),
            .mem => errprint.printSrcLineError("pointer size doesn't match register size", self.program.file_name, self.program.content, self.line),
            else => unreachable,
        }
        return CodegenError.CodeGenFailed;
    }
}

fn memRegEncoding(self: *Codegen, rm: CodeOperand, reg: Register, opcode: u8, sizes: u4) CodegenError!void {
    try self.regMemEnconding(reg, rm, opcode, sizes);
}

fn memImmEncoding1(self: *Codegen, rm: CodeOperand, opcode: u8, digit: u8, imm: Immediate) CodegenError!void {
    const imm_size = imm.fitsInBytes();
    var rm_size: u8 = undefined;
    switch (rm) {
        .reg => rm_size = rm.reg.size,
        .mem => {
            if (rm.mem.size) |size| {
                rm_size = size;
            } else {
                errprint.printSrcLineError("unspecified memory pointer size", self.program.file_name, self.program.content, self.line);
                return CodegenError.CodeGenFailed;
            }
        },
        else => unreachable,
    }
    if (rm_size >= imm_size and imm_size <= 4) {
        const reg = InstrBytes.digitToReg(digit);
        try self.ibytes.define(reg, rm, opcode, self);
        self.ibytes.setOsRexW(rm_size);
        const imm_bytes = if (rm_size == 8) 4 else rm_size;
        try self.appendInstrBytes();
        try self.appendImmediateBytes(imm, imm_bytes);
        if (self.ibytes.reloc) |*reloc| {
            reloc.addend -= imm_bytes;
        }
    } else {
        errprint.printSrcLineError("immediate value doesn't fit in memory", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn memImmEncoding2(self: *Codegen, rm: CodeOperand, opcode: u8, digit: u8, imm: Immediate) CodegenError!void {
    var rm_size: u8 = undefined;
    switch (rm) {
        .reg => rm_size = rm.reg.size,
        .mem => {
            if (rm.mem.size) |size| {
                rm_size = size;
            } else {
                errprint.printSrcLineError("unspecified memory pointer size", self.program.file_name, self.program.content, self.line);
                return CodegenError.CodeGenFailed;
            }
        },
        else => unreachable,
    }
    const reg = InstrBytes.digitToReg(digit);
    try self.ibytes.define(reg, rm, opcode, self);
    self.ibytes.setOsRexW(rm_size);
    try self.appendInstrBytes();
    try self.appendImmediateBytes(imm, 1);
    if (self.ibytes.reloc) |*reloc| {
        reloc.addend -= 1;
    }
}

fn opImmEncoding(self: *Codegen, reg: Register, opcode: u8, imm: CodeOperand) CodegenError!void {
    const reg_size = reg.size;
    var imm_size: u8 = undefined;
    var is_label = false;
    switch (imm) {
        .imm => imm_size = imm.imm.fitsInBytes(),
        .label => {
            is_label = true;
            const disp_size = imm.label.d.fitsInBytes();
            imm_size = @max(reg_size, disp_size);
        },
        else => unreachable,
    }
    if (reg_size >= imm_size) {
        if (reg_size == 8 and imm_size <= 4) {
            try self.memImmEncoding1(.{ .reg = reg }, 0xC7, 0, imm.imm);
        } else {
            imm_size = reg_size;
            try self.ibytes.define(reg, .{ .reg = .init(.eax) }, opcode, self);
            self.ibytes.plusR(reg.name);
            self.ibytes.modrm = null;
            try self.appendInstrBytes();
            if (is_label) {
                const rel_type: RelType = switch (imm_size) {
                    4 => .Abs32,
                    8 => .Abs64,
                    else => {
                        errprint.printSrcLineError("register is too small for label address", self.program.file_name, self.program.content, self.line);
                        return CodegenError.CodeGenFailed;
                    },
                };
                if (rel_type == .Abs32) {
                    if (self.program.flags.pic) {
                        errprint.printSrcLineError("absolute 32-bit address cannot be used with -pic flag", self.program.file_name, self.program.content, self.line);
                        return CodegenError.CodeGenFailed;
                    } else if (self.program.flags.warnings) {
                        errprint.printSrcLineWarning("address will be truncated to 32-bit", self.program.file_name, self.program.content, self.line);
                    }
                }
                try self.appendImmRelocation(imm, rel_type);
            } else {
                try self.appendImmediateBytes(imm.imm, imm_size);
            }
        }
    } else {
        errprint.printSrcLineError("immediate value doesn't fit in register", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn accImmEncoding(self: *Codegen, acc: Register, opcode: u8, imm: Immediate) CodegenError!void {
    const acc_size = acc.size;
    const imm_size = imm.fitsInBytes();
    if (acc_size >= imm_size and imm_size <= 4) {
        self.ibytes.reset();
        self.ibytes.opcode = opcode;
        self.ibytes.setOsRexW(acc_size);
        try self.appendInstrBytes();
        const imm_bytes = @min(4, acc_size);
        try self.appendImmediateBytes(imm, imm_bytes);
    } else {
        errprint.printSrcLineError("immediate value doesn't fit in register", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn opEncoding(self: *Codegen, reg: Register, opcode: u8, sizes: u4, discard_rexw: bool) CodegenError!void {
    const reg_size = reg.size;
    if (reg_size & sizes == reg_size) {
        try self.ibytes.define(reg, .{ .reg = reg }, opcode, self);
        self.ibytes.modrm = null;
        self.ibytes.plusR(reg.name);
        self.ibytes.setOsRexW(reg_size);
        self.ibytes.rex.r = false;
        if (discard_rexw) {
            self.ibytes.rex.w = false;
        }
        try self.appendInstrBytes();
    } else {
        errprint.printSrcLineError("invalid operand size", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn memEncoding(self: *Codegen, rm: CodeOperand, digit: u8, opcode: u8, sizes: u4, discard_rexw: bool) CodegenError!void {
    var rm_size: u8 = undefined;
    switch (rm) {
        .mem => if (rm.mem.size) |sz| {
            rm_size = sz;
        } else {
            errprint.printSrcLineError("unspecified memory pointer size", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
        .reg => {
            rm_size = rm.reg.size;
        },
        else => unreachable,
    }
    if (rm_size & sizes == rm_size) {
        const reg = InstrBytes.digitToReg(digit);
        try self.ibytes.define(reg, rm, opcode, self);
        self.ibytes.setOsRexW(rm_size);
        if (discard_rexw) {
            self.ibytes.rex.w = false;
        }
        try self.appendInstrBytes();
        if (self.ibytes.reloc) |*reloc| {
            try self.program.relocations.append(self.program.alloc, reloc.*);
        }
    } else {
        errprint.printSrcLineError("invalid operand size", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn immEncoding(self: *Codegen, imm: CodeOperand, opcode: u8, sizes: u4) CodegenError!void {
    var imm_size: u8 = undefined;
    var is_label = false;
    switch (imm) {
        .imm => imm_size = imm.imm.fitsInBytes(),
        .label => {
            is_label = true;
            imm_size = 4;
        },
        else => unreachable,
    }
    if (imm_size & sizes == imm_size) {
        if (imm_size == 2) {
            try self.program.code_block.buffer.append(self.program.alloc, 0x66);
        }
        try self.program.code_block.buffer.append(self.program.alloc, opcode);
        if (is_label) {
            if (self.program.flags.pic) {
                errprint.printSrcLineError("absolute 32-bit address cannot be used with -pic flag", self.program.file_name, self.program.content, self.line);
                return CodegenError.CodeGenFailed;
            } else if (self.program.flags.warnings) {
                errprint.printSrcLineWarning("address will be truncated to 32-bit", self.program.file_name, self.program.content, self.line);
            }
            try self.appendImmRelocation(imm, .Abs32);
        } else {
            try self.appendImmediateBytes(imm.imm, imm_size);
        }
    } else {
        errprint.printSrcLineError("invalid operand size", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn zeroEncoding(self: *Codegen, opcode_bytes: []const u8) std.mem.Allocator.Error!void {
    try self.program.code_block.buffer.appendSlice(self.program.alloc, opcode_bytes);
}

// Instructions

fn syscall(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 0) {
        errprint.printSrcLineError("syscall instruction should have 0 operands", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    try self.zeroEncoding(&.{ 0x0F, 0x05 });
}

fn mov(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 2) {
        errprint.printSrcLineError("mov instruction should have 2 operands", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = operands.items[0];
    const second = operands.items[1];
    switch (first) {
        .reg => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (first.reg.size == 1) 0x88 else 0x89;
                    try self.memRegEncoding(first, second.reg, opcode, 0b1111);
                },
                .mem => {
                    const opcode: u8 = if (first.reg.size == 1) 0x8A else 0x8B;
                    try self.regMemEnconding(first.reg, second, opcode, 0b1111);
                },
                .imm, .label => {
                    const opcode: u8 = if (first.reg.size == 1) 0xB0 else 0xB8;
                    try self.opImmEncoding(first.reg, opcode, second);
                },
            }
        },
        .mem => {
            switch (second) {
                .reg => {
                    const opcode: u8 = if (second.reg.size == 1) 0x88 else 0x89;
                    try self.memRegEncoding(first, second.reg, opcode, 0b1111);
                },
                .imm => {
                    const ptr_size = first.mem.size orelse 0;
                    const opcode: u8 = if (ptr_size == 1) 0xC6 else 0xC7;
                    try self.memImmEncoding1(first, opcode, 0, second.imm);
                },
                .label => {},
                .mem => {
                    errprint.printSrcLineError("cannot mov memory to memory", self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                },
            }
        },
        else => {
            errprint.printSrcLineError("first operand must be register or memory", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn lea(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 2) {
        errprint.printSrcLineError("lea instruction should have 2 operands", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = operands.items[0];
    const second = operands.items[1];
    switch (first) {
        .reg => {
            switch (second) {
                .mem => {
                    const opcode: u8 = 0x8D;
                    try self.regMemEnconding(first.reg, second, opcode, 0b1110);
                },
                else => {
                    errprint.printSrcLineError("second operand must be memory", self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                },
            }
        },
        else => {
            errprint.printSrcLineError("first operand must be register", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn push(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 1) {
        errprint.printSrcLineError("push instruction should have 1 operand", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = operands.items[0];
    switch (first) {
        .reg => {
            const opcode: u8 = 0x50;
            try self.opEncoding(first.reg, opcode, 0b1010, true);
        },
        .mem => {
            const opcode: u8 = 0xFF;
            try self.memEncoding(first, 6, opcode, 0b1010, true);
        },
        .imm, .label => {
            const imm_size: u8 = switch (first) {
                .imm => first.imm.fitsInBytes(),
                .label => 4,
                else => unreachable,
            };
            const opcode: u8 = if (imm_size == 1) 0x6A else 0x68;
            try self.immEncoding(first, opcode, 0b0111);
        },
    }
}

fn pop(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 1) {
        errprint.printSrcLineError("pop instruction should have 1 operand", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = operands.items[0];
    switch (first) {
        .reg => {
            const opcode: u8 = 0x58;
            try self.opEncoding(first.reg, opcode, 0b1010, true);
        },
        .mem => {
            const opcode: u8 = 0x8F;
            try self.memEncoding(first, 0, opcode, 0b1010, true);
        },
        else => {
            errprint.printSrcLineError("pop instruction can only have register or memory as operand", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn jcc(self: *Codegen, instr: CpuInstruction) CodegenError!void {
    if (instr.operands.items.len != 1) {
        errprint.printSrcLineErrorFmt("{t} instruction should have 1 operand", .{instr.mnem}, self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = instr.operands.items[0];
    switch (first) {
        .label => {
            const opcode: u8 = switch (instr.mnem) {
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
            try self.jumpReloc(first, instr.mnem, opcode);
        },
        else => {
            errprint.printSrcLineErrorFmt("{t} instruction can jump only to label", .{instr.mnem}, self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn jmp(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 1) {
        errprint.printSrcLineError("jmp instruction should have 1 operand", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = operands.items[0];
    switch (first) {
        .reg, .mem => {
            const opcode: u8 = 0xFF;
            try self.memEncoding(first, 4, opcode, 0b1000, true);
        },
        .label => {
            const opcode: u8 = 0xE9;
            try self.jumpReloc(first, .jmp, opcode);
        },
        else => {
            errprint.printSrcLineError("jmp instruction cannot have immediate operand", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn call(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 1) {
        errprint.printSrcLineError("call instruction should have 1 operand", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = operands.items[0];
    switch (first) {
        .reg, .mem => {
            const opcode: u8 = 0xFf;
            try self.memEncoding(first, 2, opcode, 0b1000, true);
        },
        .label => {
            if (first.label.l[0] == '.') {
                errprint.printSrcLineError("call to function's local label is forbidden", self.program.file_name, self.program.content, self.line);
                return CodegenError.CodeGenFailed;
            }
            const opcode: u8 = 0xE8;
            try self.program.code_block.buffer.append(self.program.alloc, opcode);
            try self.appendImmRelocation(first, .Rel32C);
        },
        else => {
            errprint.printSrcLineError("call instruction cannot have immediate operand", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn ret(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len == 0) {
        try self.zeroEncoding(&.{0xC3});
    } else if (operands.items.len == 1) {
        const oper = operands.items[0];
        switch (oper) {
            .imm => {
                const imm_size = oper.imm.fitsInBytes();
                if (imm_size <= 2) {
                    try self.zeroEncoding(&.{0xC2});
                    try self.appendImmediateBytes(oper.imm, 2);
                } else {
                    errprint.printSrcLineError("immediate value doesn't fit in 2 bytes", self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                }
            },
            else => {
                errprint.printSrcLineError("ret instruction can have only immediate value as operand", self.program.file_name, self.program.content, self.line);
                return CodegenError.CodeGenFailed;
            },
        }
    } else {
        errprint.printSrcLineError("ret instruction should have 0 or 1 operand", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
}

fn group1(self: *Codegen, instr: CpuInstruction) CodegenError!void {
    if (instr.operands.items.len != 2) {
        errprint.printSrcLineErrorFmt("{t} instruction should have 2 operands", .{instr.mnem}, self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const mnem = instr.mnem;
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            switch (second) {
                .reg => {
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
                    if (first.reg.size == 1) {
                        opcode -= 1;
                    }
                    try self.memRegEncoding(first, second.reg, opcode, 0b1111);
                },
                .mem => {
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
                    if (first.reg.size == 1) {
                        opcode -= 1;
                    }
                    try self.regMemEnconding(first.reg, second, opcode, 0b1111);
                },
                .imm => {
                    if (first.reg.name.isAccumulator()) {
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
                        if (first.reg.size == 1) {
                            opcode -= 1;
                        }
                        try self.accImmEncoding(first.reg, opcode, second.imm);
                    } else {
                        const reg_size = first.reg.size;
                        const imm_size = second.imm.fitsInBytes();
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
                            try self.memImmEncoding2(first, opcode, digit, second.imm);
                        } else {
                            const opcode: u8 = if (reg_size == 1) 0x80 else 0x81;
                            try self.memImmEncoding1(first, opcode, digit, second.imm);
                        }
                    }
                },
                .label => {
                    errprint.printSrcLineError("second operand must be register, memory or immediate", self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                },
            }
        },
        .mem => {
            switch (second) {
                .reg => {
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
                    if (second.reg.size == 1) {
                        opcode -= 1;
                    }
                    try self.memRegEncoding(first, second.reg, opcode, 0b1111);
                },
                .imm => {
                    var ptr_size: u8 = undefined;
                    if (first.mem.size) |sz| {
                        ptr_size = sz;
                    } else {
                        errprint.printSrcLineError("unspecified memory pointer size", self.program.file_name, self.program.content, self.line);
                        return CodegenError.CodeGenFailed;
                    }
                    const imm_size = second.imm.fitsInBytes();
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
                        try self.memImmEncoding2(first, opcode, digit, second.imm);
                    } else {
                        const opcode: u8 = if (ptr_size == 1) 0x80 else 0x81;
                        try self.memImmEncoding1(first, opcode, digit, second.imm);
                    }
                },
                else => {
                    errprint.printSrcLineError("second operand must be register or immediate", self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                },
            }
        },
        else => {
            errprint.printSrcLineError("first operand must be register or memory", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn @"test"(self: *Codegen, operands: Operands) CodegenError!void {
    if (operands.items.len != 2) {
        errprint.printSrcLineError("test instruction should have 2 operands", self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = operands.items[0];
    const second = operands.items[1];
    switch (second) {
        .imm => {
            switch (first) {
                .reg => {
                    if (first.reg.name.isAccumulator()) {
                        const opcode: u8 = if (first.reg.name == .al) 0xA8 else 0xA9;
                        try self.accImmEncoding(first.reg, opcode, second.imm);
                    } else {
                        const opcode: u8 = if (first.reg.size == 1) 0xF6 else 0xF7;
                        try self.memImmEncoding1(first, opcode, 0, second.imm);
                    }
                },
                .mem => {
                    var ptr_size: u8 = undefined;
                    if (first.mem.size) |sz| {
                        ptr_size = sz;
                    } else {
                        errprint.printSrcLineError("unspecified memory pointer size", self.program.file_name, self.program.content, self.line);
                        return CodegenError.CodeGenFailed;
                    }
                    const opcode: u8 = if (ptr_size == 1) 0xF6 else 0xF7;
                    try self.memImmEncoding1(first, opcode, 0, second.imm);
                },
                else => {
                    errprint.printSrcLineError("first operand must be register or memory", self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                },
            }
        },
        .reg => {
            switch (first) {
                .reg, .mem => {
                    const opcode: u8 = if (second.reg.size == 1) 0x84 else 0x85;
                    try self.memRegEncoding(first, second.reg, opcode, 0b1111);
                },
                else => {
                    errprint.printSrcLineError("first operand must be register or memory", self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                },
            }
        },
        else => {
            errprint.printSrcLineError("second operand must be register or immediate", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
}

fn group2(self: *Codegen, instr: CpuInstruction) CodegenError!void {
    if (instr.operands.items.len != 1) {
        errprint.printSrcLineErrorFmt("{t} instruction should have 1 operand", .{instr.mnem}, self.program.file_name, self.program.content, self.line);
        return CodegenError.CodeGenFailed;
    }
    const first = instr.operands.items[0];
    const digit: u8 = switch (instr.mnem) {
        .dec => 1,
        .inc => 0,
        .div => 6,
        .idiv => 7,
        .mul => 4,
        .neg => 3,
        .not => 2,
        else => unreachable,
    };
    var opcode: u8 = switch (instr.mnem) {
        .dec, .inc => 0xFF,
        .div, .idiv, .mul, .neg, .not => 0xF7,
        else => unreachable,
    };
    switch (first) {
        .reg => {
            if (first.reg.size == 1) opcode -= 1;
        },
        .mem => {
            if (first.mem.size == 1) opcode -= 1;
        },
        else => {
            errprint.printSrcLineError("operand must be register or memory", self.program.file_name, self.program.content, self.line);
            return CodegenError.CodeGenFailed;
        },
    }
    try self.memEncoding(first, digit, opcode, 0b1111, false);
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
                    prev.size = self.program.code_block.buffer.items.len - prev.offset;
                }
                func.offset = self.program.code_block.buffer.items.len;
                if (self.program.flags.has_entry and std.mem.eql(u8, self.program.entry, label)) {
                    func.visib = .Export;
                }
                self.cur_func = label;
            } else {
                const function = self.program.funcs.getPtr(self.cur_func);
                if (function) |func| {
                    const lbl_ptr = func.local_labels.getPtr(label);
                    if (lbl_ptr) |ptr| {
                        ptr.* = self.program.code_block.buffer.items.len;
                    }
                }
            }
        },
        .cpu => {
            if (self.program.flags.debug) {
                try self.program.line_program.append(self.program.alloc, .{ .offset = self.program.code_block.buffer.items.len, .line = self.line });
            }
            const start = self.program.code_block.buffer.items.len;
            switch (instr.cpu.mnem) {
                .mov => try self.mov(instr.cpu.operands),
                .lea => try self.lea(instr.cpu.operands),
                .push => try self.push(instr.cpu.operands),
                .pop => try self.pop(instr.cpu.operands),
                .ret => try self.ret(instr.cpu.operands),
                .call => try self.call(instr.cpu.operands),
                .syscall => try self.syscall(instr.cpu.operands),
                .jmp => try self.jmp(instr.cpu.operands),
                .ja, .jae, .jb, .jbe, .jc, .je, .jg, .jge, .jl, .jle, .jna, .jnae, .jnb, .jnbe, .jnc, .jne, .jng, .jnge, .jnl, .jnle, .jno, .jnp, .jns, .jnz, .jo, .jp, .jpe, .jpo, .js, .jz => try self.jcc(instr.cpu),
                .adc, .add, .@"and", .cmp, .@"or", .sbb, .sub, .xor => try self.group1(instr.cpu),
                .dec, .div, .idiv, .inc, .mul, .neg, .not => try self.group2(instr.cpu),
                .@"test" => try self.@"test"(instr.cpu.operands),
                else => {
                    errprint.printSrcLineErrorFmt("unsupported instruction: {t}", .{instr.cpu.mnem}, self.program.file_name, self.program.content, self.line);
                    return CodegenError.CodeGenFailed;
                },
            }

            const end = self.program.code_block.buffer.items.len;
            if (!self.program.flags.quiet) {
                for (self.program.code_block.buffer.items[start..end]) |byte| {
                    std.debug.print("{x:02} ", .{byte});
                }
                std.debug.print("\x1b[30G", .{});
                Program.printCPUInstruction(instr.cpu);
                std.debug.print("\n", .{});
            }
        },
    }
}

pub fn genCodeBlockBuffer(self: *Codegen) CodegenError!void {
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
        cur.size = self.program.code_block.buffer.items.len - cur.offset;
        try self.patchTempRelocs();
    }
    if (self.program.flags.debug) {
        try self.program.line_program.append(self.program.alloc, .{
            .offset = self.program.code_block.buffer.items.len,
            .line = self.program.line_program.items[self.program.line_program.items.len - 1].line + 1,
        });
    }
}

fn patchTempRelocs(self: *Codegen) CodegenError!void {
    for (self.temp_relocs.items) |reloc| {
        const func_ptr = self.program.funcs.getPtr(self.cur_func).?;
        const target_offset = func_ptr.local_labels.getPtr(reloc.name).?.*;
        const disp: i32 = @truncate(@as(i64, @bitCast(target_offset -% reloc.offset)) + reloc.addend);
        std.mem.writeInt(u32, @ptrCast(self.program.code_block.buffer.items[reloc.offset .. reloc.offset + 4]), @bitCast(disp), .little);
    }
    self.temp_relocs.clearRetainingCapacity();
}

test "codegen mov reg, rm" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try errprint.init(alloc, io);
    defer errprint.deinit(alloc);

    var prog = try alloc.create(Program);
    defer alloc.destroy(prog);

    const content: []const u8 = "@data\nlabel: d8 repeat(100, 0)\n@code\nmov rdx, [rip]\nmov rdx, [rip + 100]\nmov rdx, [rip + label]\nmov rdx, [rip + label + 100]\nmov rdx, [label]\nmov rdx, [label + 100]\nmov rdx, [label - 100]\nmov rdx, [label + 290529520]\nmov rdx, [label + rcx]\nmov rdx, [label + rcx - 4902]\nmov rdx, [label + rsp]\nmov rdx, [label + rcx * 2]\nmov rdx, [label + rcx * 2 - 4902]\nmov rdx, [label + rcx + rcx*2 - 4902]\nmov rdx, [rcx]\nmov rdx, [ecx]\nmov rdx, [rbp]\nmov rdx, [ebp]\nmov rdx, [rsp]\nmov rdx, [esp]\nmov rdx, [r12]\nmov rdx, [r13]\nmov rdx, [r12d]\nmov rdx, [r13d]\nmov rdx, [rcx-128]\nmov rdx, [ecx+128]\nmov rdx, [rbp+10]\nmov rdx, [rbp+129]\nmov rdx, [ebp+10]\nmov rdx, [ebp+129]\nmov rdx, [rsp+10]\nmov rdx, [esp+12975]\nmov rdx, [r12+10]\nmov rdx, [r12+1355]\nmov rdx, [r13+10]\nmov rdx, [r13+3654]\nmov rdx, [r12d+34]\nmov rdx, [r13d-56]\nmov rdx, [rbp+rsp]\nmov rdx, [ebp+esp]\nmov rdx, [rbp+rcx]\nmov rdx, [ebp+ecx]\nmov rdx, [rsp+rbp]\nmov rdx, [esp+ebp]\nmov rdx, [rsp+rcx]\nmov rdx, [esp+ecx]\nmov rdx, [r12+r13]\nmov rdx, [r12+r12]\nmov rdx, [r12+rcx]\nmov rdx, [r12d+r13d]\nmov rdx, [r12d+ecx]\nmov rdx, [rbp+rbp]\nmov rdx, [rcx+rbp]\nmov rdx, [rcx+rsp]\nmov rdx, [rcx+r12]\nmov rdx, [rcx+r13]\nmov rdx, [rbp*2]\nmov rdx, [rbp*4]\nmov rdx, [rbp*8]\nmov rdx, [r13*2]\nmov rdx, [r13*4]\nmov rdx, [r13*8]\nmov rdx, [r12*2]\nmov rdx, [r12*4]\nmov rdx, [r12*8]\nmov rdx, [rcx*2]\nmov rdx, [rcx*4]\nmov rdx, [rcx*8]\nmov rdx, [rbp*2+10]\nmov rdx, [ebp*2+1356]\nmov rdx, [rbp*4-54]\nmov rdx, [ebp*8+98625775]\nmov rdx, [rcx*2-90]\nmov rdx, [ecx*4+87643]\nmov rdx, [r13*2-98753]\nmov rdx, [r13*4+1]\nmov rdx, [r13*8-128]\nmov rdx, [r12d*4+128]\nmov rdx, [r12*8-67]\nmov rdx, [rbp+rbp*2]\nmov rdx, [rbp+rcx*2]\nmov rdx, [rsp+rbp*2]\nmov rdx, [rsp+rcx*2]\nmov rdx, [rsp+r12*2]\nmov rdx, [rsp+r13*2]\nmov rdx, [rcx+rbp*2]\nmov rdx, [rbp+rbp*2-10]\nmov rdx, [rbp+rcx*2+156]\nmov rdx, [rsp+rbp*2-87]\nmov rdx, [rsp+rcx*4+346]\nmov rdx, [rsp+r12*2+98765433]\nmov rdx, [rsp+r13*2-1]\nmov rdx, [rcx+rbp*8+35]\nmov rdx, [rcx+r12*4-67]\nmov rdx, [rcx+r13*8+127]\nmov rdx, [r12+r13*8+30]\nmov rdx, [r13+r12*2-40]\nmov rdx, [0]\nmov rdx, [10]\nmov rdx, [128]\nmov rdx, [3677543]\nmov rdx, [-12]\nmov rdx, [-129]\nmov rdx, [-866433]\nmov rdx, [2049494944]\n mov rdx, [rsp + label]\nmov rdx, [ebp * 2 + label]\nmov rdx, [r12 * 2 + label - 324]\nmov rdx, [r13 * 8 + label + 39034]\n";

    const expected: []const u8 = &.{ 0x48, 0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x15, 0x64, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x91, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x91, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x94, 0x24, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x14, 0x4D, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x14, 0x4D, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x94, 0x49, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x11, 0x67, 0x48, 0x8B, 0x11, 0x48, 0x8B, 0x55, 0x00, 0x67, 0x48, 0x8B, 0x55, 0x00, 0x48, 0x8B, 0x14, 0x24, 0x67, 0x48, 0x8B, 0x14, 0x24, 0x49, 0x8B, 0x14, 0x24, 0x49, 0x8B, 0x55, 0x00, 0x67, 0x49, 0x8B, 0x14, 0x24, 0x67, 0x49, 0x8B, 0x55, 0x00, 0x48, 0x8B, 0x51, 0x80, 0x67, 0x48, 0x8B, 0x91, 0x80, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x55, 0x0A, 0x48, 0x8B, 0x95, 0x81, 0x00, 0x00, 0x00, 0x67, 0x48, 0x8B, 0x55, 0x0A, 0x67, 0x48, 0x8B, 0x95, 0x81, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x54, 0x24, 0x0A, 0x67, 0x48, 0x8B, 0x94, 0x24, 0xAF, 0x32, 0x00, 0x00, 0x49, 0x8B, 0x54, 0x24, 0x0A, 0x49, 0x8B, 0x94, 0x24, 0x4B, 0x05, 0x00, 0x00, 0x49, 0x8B, 0x55, 0x0A, 0x49, 0x8B, 0x95, 0x46, 0x0E, 0x00, 0x00, 0x67, 0x49, 0x8B, 0x54, 0x24, 0x22, 0x67, 0x49, 0x8B, 0x55, 0xC8, 0x48, 0x8B, 0x14, 0x2C, 0x67, 0x48, 0x8B, 0x14, 0x2C, 0x48, 0x8B, 0x54, 0x0D, 0x00, 0x67, 0x48, 0x8B, 0x54, 0x0D, 0x00, 0x48, 0x8B, 0x14, 0x2C, 0x67, 0x48, 0x8B, 0x14, 0x2C, 0x48, 0x8B, 0x14, 0x0C, 0x67, 0x48, 0x8B, 0x14, 0x0C, 0x4B, 0x8B, 0x14, 0x2C, 0x4B, 0x8B, 0x14, 0x24, 0x49, 0x8B, 0x14, 0x0C, 0x67, 0x4B, 0x8B, 0x14, 0x2C, 0x67, 0x49, 0x8B, 0x14, 0x0C, 0x48, 0x8B, 0x54, 0x2D, 0x00, 0x48, 0x8B, 0x14, 0x29, 0x48, 0x8B, 0x14, 0x0C, 0x4A, 0x8B, 0x14, 0x21, 0x4A, 0x8B, 0x14, 0x29, 0x48, 0x8B, 0x14, 0x6D, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0xAD, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0xED, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0x6D, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0xAD, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0xED, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0x65, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0xA5, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0xE5, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0x4D, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0x8D, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0xCD, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0x6D, 0x0A, 0x00, 0x00, 0x00, 0x67, 0x48, 0x8B, 0x14, 0x6D, 0x4C, 0x05, 0x00, 0x00, 0x48, 0x8B, 0x14, 0xAD, 0xCA, 0xFF, 0xFF, 0xFF, 0x67, 0x48, 0x8B, 0x14, 0xED, 0xEF, 0xE8, 0xE0, 0x05, 0x48, 0x8B, 0x14, 0x4D, 0xA6, 0xFF, 0xFF, 0xFF, 0x67, 0x48, 0x8B, 0x14, 0x8D, 0x5B, 0x56, 0x01, 0x00, 0x4A, 0x8B, 0x14, 0x6D, 0x3F, 0x7E, 0xFE, 0xFF, 0x4A, 0x8B, 0x14, 0xAD, 0x01, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0xED, 0x80, 0xFF, 0xFF, 0xFF, 0x67, 0x4A, 0x8B, 0x14, 0xA5, 0x80, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0xE5, 0xBD, 0xFF, 0xFF, 0xFF, 0x48, 0x8B, 0x54, 0x6D, 0x00, 0x48, 0x8B, 0x54, 0x4D, 0x00, 0x48, 0x8B, 0x14, 0x6C, 0x48, 0x8B, 0x14, 0x4C, 0x4A, 0x8B, 0x14, 0x64, 0x4A, 0x8B, 0x14, 0x6C, 0x48, 0x8B, 0x14, 0x69, 0x48, 0x8B, 0x54, 0x6D, 0xF6, 0x48, 0x8B, 0x94, 0x4D, 0x9C, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x54, 0x6C, 0xA9, 0x48, 0x8B, 0x94, 0x8C, 0x5A, 0x01, 0x00, 0x00, 0x4A, 0x8B, 0x94, 0x64, 0x79, 0x0A, 0xE3, 0x05, 0x4A, 0x8B, 0x54, 0x6C, 0xFF, 0x48, 0x8B, 0x54, 0xE9, 0x23, 0x4A, 0x8B, 0x54, 0xA1, 0xBD, 0x4A, 0x8B, 0x54, 0xE9, 0x7F, 0x4B, 0x8B, 0x54, 0xEC, 0x1E, 0x4B, 0x8B, 0x54, 0x65, 0xD8, 0x48, 0x8B, 0x14, 0x25, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0x25, 0x0A, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0x25, 0x80, 0x00, 0x00, 0x00, 0x48, 0x8B, 0x14, 0x25, 0x67, 0x1D, 0x38, 0x00, 0x48, 0x8B, 0x14, 0x25, 0xF4, 0xFF, 0xFF, 0xFF, 0x48, 0x8B, 0x14, 0x25, 0x7F, 0xFF, 0xFF, 0xFF, 0x48, 0x8B, 0x14, 0x25, 0x7F, 0xC7, 0xF2, 0xFF, 0x48, 0x8B, 0x14, 0x25, 0xA0, 0xCF, 0x28, 0x7A, 0x48, 0x8B, 0x94, 0x24, 0x00, 0x00, 0x00, 0x00, 0x67, 0x48, 0x8B, 0x14, 0x6D, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0x65, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x8B, 0x14, 0xED, 0x00, 0x00, 0x00, 0x00 };

    prog.init(content, "test.asm", alloc, false, false, false);
    defer {
        prog.tokens.deinit(prog.alloc);
        for (prog.data_block.instr.items) |*instr| {
            instr.data.deinit(prog.alloc);
        }
        prog.data_block.instr.deinit(prog.alloc);
        for (prog.code_block.instr.items) |*instr| {
            switch (instr.*) {
                .cpu => instr.cpu.operands.deinit(prog.alloc),
                else => {},
            }
        }
        prog.data_block.buffer.deinit(prog.alloc);
        prog.code_block.instr.deinit(prog.alloc);
        prog.code_block.buffer.deinit(prog.alloc);
        prog.data_vars.deinit();
        prog.funcs.deinit();
        prog.imports.deinit();
        prog.relocations.deinit(prog.alloc);
    }

    try prog.lexicalAnalyzis();
    // lexer.printTokens(prog.tokens);
    try prog.syntaxAnalyzis();
    // prog.printProgram();

    try prog.codeGen();
    // prog.printSymbolTable();

    try std.testing.expectEqualSlices(u8, expected, prog.code_block.buffer.items);
}

test "codegen mov reg, imm" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try errprint.init(alloc, io);
    defer errprint.deinit(alloc);

    var prog = try alloc.create(Program);
    defer alloc.destroy(prog);

    const content: []const u8 = "@data\nlabel: d8 repeat(100, 0)\n@code\nmov al, 148\nmov ah, 34\nmov bx, 1\nmov cx, 255\nmov sp, 4039\nmov edi, 0\nmov esi, 255\nmov edx, 4059\nmov edx, 30995509\nmov rax, 4\nmov rbx, 3094\nmov rbx, 3094000\nmov rcx, 3838383838445\n";

    const expected: []const u8 = &.{ 0xB0, 0x94, 0xB4, 0x22, 0x66, 0xBB, 0x01, 0x00, 0x66, 0xB9, 0xFF, 0x00, 0x66, 0xBC, 0xC7, 0x0F, 0xBF, 0x00, 0x00, 0x00, 0x00, 0xBE, 0xFF, 0x00, 0x00, 0x00, 0xBA, 0xDB, 0x0F, 0x00, 0x00, 0xBA, 0x35, 0xF4, 0xD8, 0x01, 0x48, 0xC7, 0xC0, 0x04, 0x00, 0x00, 0x00, 0x48, 0xC7, 0xC3, 0x16, 0x0C, 0x00, 0x00, 0x48, 0xC7, 0xC3, 0xF0, 0x35, 0x2F, 0x00, 0x48, 0xB9, 0xED, 0x54, 0x81, 0xB1, 0x7D, 0x03, 0x00, 0x00 };

    prog.init(content, "test.asm", alloc, false, false, true);
    defer {
        prog.tokens.deinit(prog.alloc);
        for (prog.data_block.instr.items) |*instr| {
            instr.data.deinit(prog.alloc);
        }
        prog.data_block.instr.deinit(prog.alloc);
        for (prog.code_block.instr.items) |*instr| {
            switch (instr.*) {
                .cpu => instr.cpu.operands.deinit(prog.alloc),
                else => {},
            }
        }
        prog.data_block.buffer.deinit(prog.alloc);
        prog.code_block.instr.deinit(prog.alloc);
        prog.code_block.buffer.deinit(prog.alloc);
        prog.data_vars.deinit();
        prog.funcs.deinit();
        prog.imports.deinit();
        prog.relocations.deinit(prog.alloc);
    }

    try prog.lexicalAnalyzis();
    // lexer.printTokens(prog.tokens);
    try prog.syntaxAnalyzis();
    // prog.printProgram();

    try prog.codeGen();

    try std.testing.expectEqualSlices(u8, expected, prog.code_block.buffer.items);
}

test "codegen push pop ret call jmp" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try errprint.init(alloc, io);
    defer errprint.deinit(alloc);

    var prog = try alloc.create(Program);
    defer alloc.destroy(prog);

    // const content: []const u8 = "@data\nlabel: d8 repeat(100, 0)\n@code\nstart:\npush ax\npush r12w\npush rdx\npush r14\npush p16 [rax]\npush p64 [label]\npush p64 [90 + r13]\npush 0\npush -128\npush 34444\npush 2048493893\npush label\npush label + 45\npop rdx\npop r12w\npop p16 [label]\npop p64 [r13d + 55]\nret\nret 0\nret 8394\ncall start\ncall start + 3253\ncall rdx\ncall p64 [label + 34]\njmp start\njmp start + 3253\njmp rdx\njmp p64 [label + 34]\n";
    const content: []const u8 =
        \\@data
        \\label: d8 repeat(100, 0)
        \\@code
        \\start:
        \\push ax
        \\push r12w
        \\push rdx
        \\push r14
        \\push p16 [rax]
        \\push p64 [label]
        \\push p64 [90 + r13]
        \\push 0
        \\push -128
        \\push 34444
        \\push 2048493893
        \\push label
        \\push label + 45
        \\pop rdx
        \\pop r12w
        \\pop p16 [label]
        \\pop p64 [r13d + 55]
        \\ret
        \\ret 0
        \\ret 8394
        \\call start
        \\call start + 3253
        \\call rdx
        \\call p64 [label + 34]
        \\jmp start
        \\jmp start + 3253
        \\jmp rdx
        \\jmp p64 [label + 34]
        \\
        \\
    ;

    const expected: []const u8 = &.{ 0x66, 0x50, 0x66, 0x41, 0x54, 0x52, 0x41, 0x56, 0x66, 0xFF, 0x30, 0xFF, 0x35, 0x00, 0x00, 0x00, 0x00, 0x41, 0xFF, 0x75, 0x5A, 0x6A, 0x00, 0x6A, 0x80, 0x66, 0x68, 0x8C, 0x86, 0x68, 0x45, 0x89, 0x19, 0x7A, 0x68, 0x00, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00, 0x5A, 0x66, 0x41, 0x5C, 0x66, 0x8F, 0x05, 0x00, 0x00, 0x00, 0x00, 0x67, 0x41, 0x8F, 0x45, 0x37, 0xC3, 0xC2, 0x00, 0x00, 0xC2, 0xCA, 0x20, 0xE8, 0x00, 0x00, 0x00, 0x00, 0xE8, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xD2, 0xFF, 0x15, 0x00, 0x00, 0x00, 0x00, 0xE9, 0x00, 0x00, 0x00, 0x00, 0xE9, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xE2, 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 };

    prog.init(content, "test.asm", alloc, false, false, true);
    defer {
        prog.tokens.deinit(prog.alloc);
        for (prog.data_block.instr.items) |*instr| {
            instr.data.deinit(prog.alloc);
        }
        prog.data_block.instr.deinit(prog.alloc);
        for (prog.code_block.instr.items) |*instr| {
            switch (instr.*) {
                .cpu => instr.cpu.operands.deinit(prog.alloc),
                .label => {},
            }
        }
        prog.data_block.buffer.deinit(prog.alloc);
        prog.code_block.instr.deinit(prog.alloc);
        prog.code_block.buffer.deinit(prog.alloc);
        // prog.shared_libs.deinit(prog.alloc);
        prog.data_vars.deinit();
        prog.funcs.deinit();
        // prog.imports.deinit();
        prog.relocations.deinit(prog.alloc);
        prog.line_program.deinit(prog.alloc);
    }

    try prog.lexicalAnalyzis();
    // lexer.printTokens(prog.tokens);
    try prog.syntaxAnalyzis();
    // prog.printProgram();

    try prog.codeGen();

    // if (!std.mem.eql(u8, expected, prog.code_block.buffer.items)) {
    //     return error.TestExpectedEqual;
    // } else {
    //     std.debug.print("test passed\n", .{});
    //     std.process.exit(0);
    // }
    try std.testing.expectEqualSlices(u8, expected, prog.code_block.buffer.items);
    std.process.exit(0);
}

test "codegen using ah, dh, ch, bh with REX" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try errprint.init(alloc, io);
    defer errprint.deinit(alloc);

    var prog = try alloc.create(Program);
    defer alloc.destroy(prog);

    const content: []const u8 = "@data\nlabel: d8 repeat(100, 0)\n@code\nmov ah, 0\nmov spl, 0\nmov dil, 120\n;mov ah, r12b\nmov sil, [rax]\n;mov ah, [r12]\nmov bpl, [r13]\n\n";

    const expected: []const u8 = &.{ 0xB4, 0x00, 0x40, 0xB4, 0x00, 0x40, 0xB7, 0x78, 0x40, 0x8A, 0x30, 0x41, 0x8A, 0x6D, 0x00 };

    prog.init(content, "test.asm", alloc, false, false, true);
    defer {
        prog.tokens.deinit(prog.alloc);
        for (prog.data_block.instr.items) |*instr| {
            instr.data.deinit(prog.alloc);
        }
        prog.data_block.instr.deinit(prog.alloc);
        for (prog.code_block.instr.items) |*instr| {
            switch (instr.*) {
                .cpu => instr.cpu.operands.deinit(prog.alloc),
                else => {},
            }
        }
        prog.data_block.buffer.deinit(prog.alloc);
        prog.code_block.instr.deinit(prog.alloc);
        prog.code_block.buffer.deinit(prog.alloc);
        prog.data_vars.deinit();
        prog.funcs.deinit();
        prog.imports.deinit();
        prog.relocations.deinit(prog.alloc);
    }

    try prog.lexicalAnalyzis();
    // lexer.printTokens(prog.tokens);
    try prog.syntaxAnalyzis();
    // prog.printProgram();

    try prog.codeGen();

    try std.testing.expectEqualSlices(u8, expected, prog.code_block.buffer.items);
}
