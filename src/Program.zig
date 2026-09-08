const std = @import("std");
const utils = @import("utils");
const Lexer = @import("Lexer");
const TokenType = Lexer.TokenType;
const Token = Lexer.Token;
const Parser = @import("Parser");
const Codegen = @import("Codegen");

const Buffer = std.ArrayList(u8);

/// System-agnostic source file internal representation
const Program = @This();

pub const MemSize = u8;
pub const Label = u16;

pub const Register = packed struct(u16) {
    name: TokenType,
    size: MemSize,

    pub fn init(reg: TokenType) Register {
        const r = @intFromEnum(reg);
        const r128_start = @intFromEnum(TokenType.xmm0);
        const r128_end = @intFromEnum(TokenType.xmm15);
        const r64_end = @intFromEnum(TokenType.r15);
        const r32_end = @intFromEnum(TokenType.r15d);
        const r16_end = @intFromEnum(TokenType.r15w);
        const r8_end = @intFromEnum(TokenType.r15b);
        if (r >= r128_start) {
            if (r <= r128_end) {
                return Register{ .name = reg, .size = 16 };
            } else if (r <= r64_end) {
                return Register{ .name = reg, .size = 8 };
            } else if (r <= r32_end) {
                return Register{ .name = reg, .size = 4 };
            } else if (r <= r16_end) {
                return Register{ .name = reg, .size = 2 };
            } else if (r <= r8_end) {
                return Register{ .name = reg, .size = 1 };
            }
        }
        return Register{ .name = .rip, .size = 0 };
    }
};

pub const Immediate = packed struct(u72) {
    bits: u64,
    sign: enum(u8) { u, i },

    pub fn negative(self: Immediate) i64 {
        return @bitCast(self.bits);
    }

    pub fn negate(self: *Immediate) std.fmt.ParseIntError!void {
        switch (self.sign) {
            .u => {
                const unsigned = self.bits;
                if (unsigned <= std.math.maxInt(u63) + 1) {
                    const a: u64 = std.math.maxInt(u64) - unsigned +% 1;
                    self.* = .{ .bits = @bitCast(a), .sign = .i };
                } else {
                    return std.fmt.ParseIntError.Overflow;
                }
            },
            else => {},
        }
    }

    pub fn fitsInBytes(self: Immediate) MemSize {
        switch (self.sign) {
            .i => {
                const i: i64 = @bitCast(self.bits);
                if (i >= std.math.minInt(i8) and i <= std.math.maxInt(i8)) {
                    return 1;
                } else if (i >= std.math.minInt(i16) and i <= std.math.maxInt(i16)) {
                    return 2;
                } else if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) {
                    return 4;
                } else {
                    return 8;
                }
            },
            .u => {
                if (self.bits <= std.math.maxInt(u8)) {
                    return 1;
                } else if (self.bits <= std.math.maxInt(u16)) {
                    return 2;
                } else if (self.bits <= std.math.maxInt(u32)) {
                    return 4;
                } else {
                    return 8;
                }
            },
        }
    }
};

pub const Displacement = i32;

pub const MemOperand = packed struct(u96) {
    disp: Displacement,
    base: Register,
    index: Register,
    label: Label,
    scale: MemSize,
    size: MemSize,
};

pub const CodeOperand = packed struct(u104) {
    op: packed union(u96) {
        reg: packed struct { r: Register, _p: u80 = 0 },
        mem: MemOperand,
        label: packed struct { d: Immediate, l: Label, _p: u8 = 0 },
        imm: packed struct { i: Immediate, _p: u24 = 0 },
    },
    tag: enum(u8) { reg, mem, imm, lbl },

    pub fn initReg(reg: Register) CodeOperand {
        return .{ .op = .{ .reg = .{ .r = reg } }, .tag = .reg };
    }
    pub fn initMem(mem: MemOperand) CodeOperand {
        return .{ .op = .{ .mem = mem }, .tag = .mem };
    }
    pub fn initImm(imm: Immediate) CodeOperand {
        return .{ .op = .{ .imm = .{ .i = imm } }, .tag = .imm };
    }
    pub fn initLbl(lbl: Label, imm: ?Immediate) CodeOperand {
        return .{ .op = .{ .label = .{ .l = lbl, .d = if (imm) |i| i else .{ .bits = 0, .sign = .u } } }, .tag = .lbl };
    }
};

pub const CpuInstruction = struct {
    operands: struct {
        index: u16,
        len: u16,
    },
    mnem: TokenType,
    line: u16,
};

pub const LabelInstruction = struct {
    name: Label,
    line: u16,
};

pub const CodeInstruction = union(enum) {
    label: LabelInstruction,
    cpu: CpuInstruction,
};

pub const CodeBlock = struct {
    instr: std.ArrayList(CodeInstruction) = .empty,
    operands: std.ArrayList(CodeOperand) = .empty,
    buffer: Buffer = .empty,
};

pub const RelType = enum {
    Abs64,
    Abs32,
    Abs32S,
    Rel32C,
    Rel32D,
};

pub const Relocation = struct {
    addend: i64 = 0,
    offset: u32 = 0,
    name: Label = 0,
    type: RelType = .Rel32D,
};

pub const LineProgramEntry = struct {
    offset: u32,
    line: u32,
};

const LabelType = enum { Local, Export };
const BlockType = enum { Data, Bss };

const DataVariable = struct {
    visib: LabelType,
    block: BlockType,
    offset: u32,
    size: u32,
};

const Function = struct {
    visib: LabelType,
    offset: u32,
    size: u32,
    local_labels: std.AutoHashMapUnmanaged(Label, u32),
};

const ProgramFlags = struct {
    has_entry: bool = false,
    has_data: bool = false,
    has_bss: bool = false,
    has_code: bool = false,
    has_shared: bool = false,
};

file_name: []const u8,
content: []const u8,
flags: ProgramFlags,
tokens: std.ArrayList(Token),
entry: Label,
data_buffer: std.ArrayList(u8),
bss_len: u32,
code_block: CodeBlock,
shared_libs: std.ArrayList(Label),
data_vars: std.AutoHashMapUnmanaged(Label, DataVariable),
funcs: std.AutoHashMapUnmanaged(Label, Function),
imports: std.AutoHashMapUnmanaged(Label, u16),
relocations: std.ArrayList(Relocation),

line_program: std.ArrayList(LineProgramEntry),

pub fn init(self: *Program, content: []const u8, file_name: []const u8) void {
    self.file_name = file_name;
    self.content = content;
    self.flags = ProgramFlags{};
    self.tokens = .empty;
    self.entry = 0;
    self.data_buffer = .empty;
    self.bss_len = 0;
    self.code_block = CodeBlock{};
    self.shared_libs = .empty;
    self.data_vars = .empty;
    self.funcs = .empty;
    self.imports = .empty;
    self.relocations = .empty;
    self.line_program = .empty;
}

pub fn printBuffer(buf: []const u8) void {
    for (buf) |byte| {
        std.debug.print("{x:02}", .{byte});
    }
    std.debug.print("\n", .{});
}

pub fn printProgram(self: *Program) void {
    if (self.flags.has_entry) {
        std.debug.print("entry: {s}\n", .{utils.stringValue(self.entry)});
    }

    if (self.flags.has_code) {
        std.debug.print("code block\n", .{});
        for (self.code_block.instr.items) |instr| {
            switch (instr) {
                .cpu => {
                    self.printCPUInstruction(instr.cpu);
                },
                .label => {
                    std.debug.print("{s}:", .{utils.stringValue(instr.label.name)});
                },
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
}

pub fn printSymbolTable(self: *Program) void {
    std.debug.print("Symbols: \n", .{});
    var data_iter = self.data_vars.iterator();
    while (data_iter.next()) |data_var| {
        std.debug.print("{s}  {s} 0 {s:<20} {d:4} {d:4}\n", .{
            switch (data_var.value_ptr.block) {
                .Data => "d ",
                .Bss => " b",
            },
            switch (data_var.value_ptr.visib) {
                .Export => "EXP",
                .Local => "LOC",
            },
            utils.stringValue(data_var.key_ptr.*),
            data_var.value_ptr.offset,
            data_var.value_ptr.size,
        });
    }
    var code_iter = self.funcs.iterator();
    while (code_iter.next()) |func| {
        std.debug.print("  c {s} 0 {s:<20} {d:4} {d:4}\n", .{
            switch (func.value_ptr.visib) {
                .Export => "EXP",
                .Local => "LOC",
            },
            utils.stringValue(func.key_ptr.*),
            func.value_ptr.offset,
            func.value_ptr.size,
        });
        var locals_iter = func.value_ptr.local_labels.iterator();
        while (locals_iter.next()) |local| {
            std.debug.print("          {s:<20} {d:4}\n", .{
                utils.stringValue(local.key_ptr.*),
                local.value_ptr.*,
            });
        }
    }
    var import_iter = self.imports.iterator();
    while (import_iter.next()) |imp| {
        std.debug.print("-- IMP {d:1} {s:<20} 0\n", .{
            imp.value_ptr.*,
            utils.stringValue(imp.key_ptr.*),
        });
    }
    std.debug.print("imports\n", .{});
    for (self.shared_libs.items, 0..) |lib, i| {
        std.debug.print("{d}: {s}\n", .{ i, utils.stringValue(lib) });
    }
    std.debug.print("\n", .{});

    std.debug.print("data buffer\n", .{});
    printBuffer(self.data_buffer.items);
    std.debug.print("\n", .{});

    std.debug.print("code buffer\n", .{});
    printBuffer(self.code_block.buffer.items);
    std.debug.print("\n", .{});

    std.debug.print("Relocations: \n", .{});
    for (self.relocations.items) |reloc| {
        std.debug.print("{s:<20} {d:016}  {t:6} {d:12}\n", .{
            utils.stringValue(reloc.name),
            reloc.offset,
            reloc.type,
            reloc.addend,
        });
    }
    std.debug.print("\n", .{});

    std.debug.print("line program\n", .{});
    for (self.line_program.items) |entry| {
        std.debug.print("{d:016} - {d}\n", .{ entry.offset, entry.line });
    }
    std.debug.print("\n", .{});
}

pub fn printCPUInstruction(self: *Program, instr: CpuInstruction) void {
    std.debug.print("\x1b[35m {t} \x1b[0m", .{instr.mnem});
    for (0..instr.operands.len) |i| {
        const oper = self.code_block.operands.items[instr.operands.index + i];
        switch (oper.tag) {
            .imm => {
                switch (oper.op.imm.i.sign) {
                    .i => {
                        std.debug.print("\x1b[33m{d}\x1b[0m", .{oper.op.imm.i.negative()});
                    },
                    .u => {
                        std.debug.print("\x1b[33m{d}\x1b[0m", .{oper.op.imm.i.bits});
                    },
                }
            },
            .lbl => {
                std.debug.print("\x1b[34m{s}\x1b[0m", .{utils.stringValue(oper.op.label.l)});
                switch (oper.op.label.d.sign) {
                    .u => {
                        if (oper.op.label.d.bits != 0) {
                            std.debug.print("\x1b[33m +{d}\x1b[0m", .{oper.op.label.d.bits});
                        }
                    },
                    .i => {
                        if (oper.op.label.d.bits != 0) {
                            std.debug.print("\x1b[33m {s}{d}\x1b[0m", .{ if (oper.op.label.d.negative() > 0) "+" else "", oper.op.label.d.negative() });
                        }
                    },
                }
            },
            .reg => {
                std.debug.print("\x1b[36m{t}\x1b[0m", .{oper.op.reg.r.name});
            },
            .mem => {
                const base = if (oper.op.mem.base.size > 0) oper.op.mem.base.name else null;
                const index = if (oper.op.mem.index.size > 0) oper.op.mem.index.name else null;
                const scale = oper.op.mem.scale;
                const disp = oper.op.mem.disp;
                const label = oper.op.mem.label;

                if (oper.op.mem.size > 0) {
                    std.debug.print("p{d} ", .{oper.op.mem.size * 8});
                }
                std.debug.print("[", .{});
                if (oper.op.mem.base.size > 0) {
                    std.debug.print("\x1b[36m{t}\x1b[0m", .{oper.op.mem.base.name});
                }
                if (index != null) {
                    std.debug.print("{s}\x1b[31m{t}\x1b[0m", .{ if (base != null) " + " else "", index.? });
                }
                if (scale > 0) {
                    std.debug.print("*\x1b[32m{d}\x1b[0m", .{scale});
                }
                if (disp != 0) {
                    std.debug.print("\x1b[33m{s}{s}{d}\x1b[0m", .{ if (base != null or index != null) " " else "", if (disp >= 0) "+" else "", disp });
                }
                if (label > 0) {
                    std.debug.print("\x1b[34m{s}{s}\x1b[0m", .{ if (base != null or index != null or disp != 0) " + " else "", utils.stringValue(label) });
                }
                std.debug.print("]", .{});
            },
        }
        if (i < instr.operands.len - 1) {
            std.debug.print(", ", .{});
        }
    }
}

pub fn deinit(self: *Program) void {
    utils.alloc.free(self.content);
    self.tokens.deinit(utils.alloc);
    self.code_block.operands.deinit(utils.alloc);
    self.code_block.instr.deinit(utils.alloc);
    self.data_buffer.deinit(utils.alloc);
    self.code_block.buffer.deinit(utils.alloc);
    self.shared_libs.deinit(utils.alloc);
    self.data_vars.deinit(utils.alloc);
    var func_iter = self.funcs.iterator();
    while (func_iter.next()) |func| {
        func.value_ptr.local_labels.deinit(utils.alloc);
    }
    self.funcs.deinit(utils.alloc);
    self.imports.deinit(utils.alloc);
    self.relocations.deinit(utils.alloc);
    self.line_program.deinit(utils.alloc);
}
