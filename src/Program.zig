const std = @import("std");
const utils = @import("utils");
const Lexer = @import("Lexer");
const TokenType = Lexer.TokenType;
const Token = Lexer.Token;

const Buffer = std.ArrayList(u8);

/// System-agnostic source file internal representation
const Program = @This();

pub const MemSize = u8;
pub const Label = u16;

pub const Register = packed struct(u16) {
    name: TokenType,

    pub fn init(reg: TokenType) Register {
        return Register{ .name = reg };
    }

    pub fn size(self: Register) MemSize {
        return @truncate(@backingInt(self.name) & 0xFF);
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

/// Represents power of 2
pub const Alignment = u8;

pub fn alignmentFromBytes(bytes: usize) Alignment {
    // Try ctz?
    return @trunc(@log2(@as(f32, @floatFromInt(bytes))));
}

pub fn bytesFromAlignment(alignment: Alignment) u32 {
    return @as(u32, 1) << @as(u5, @truncate(alignment));
}

pub fn alignOffset(offset: u32, alignment: Alignment) u32 {
    return std.mem.alignForward(u32, offset, bytesFromAlignment(alignment));
}

pub const TypeName = Label;

pub const Type = union(enum) {
    d8: void,
    d16: void,
    d32: void,
    d64: void,
    d128: void,
    array: Array,
    @"enum": struct {
        fields_start: u16,
        fields_end: u16,
        data_size: u8, // In bytes
    }, // 6
    @"struct": struct {
        size: u32,
        fields: u16, // Index in types.struct_fields
        alignment: Alignment,
    }, // 8

    pub const Array = struct {
        len: u32,
        type: TypeName,
    }; // 8

    pub const EnumField = struct {
        name: Label,
        value: u64,
    }; // 16

    pub const StructField = struct {
        offset: u32, // Relative to the beginning of parent struct
        name: Label,
        type: TypeName,
        alignment: Alignment,
    }; // 12

    pub fn size(self: Type, program: *Program) u32 {
        return switch (self) {
            .d8 => 1,
            .d16 => 2,
            .d32 => 4,
            .d64 => 8,
            .d128 => 16,
            .@"enum" => |e| e.data_size,
            .@"struct" => |s| s.size,
            .array => |a| program.types.get(a.type).?.size(program) * a.len,
        };
    }

    pub fn alignment(self: Type, program: *Program) Alignment {
        return switch (self) {
            .d8, .d16, .d32, .d64, .d128, .@"enum" => alignmentFromBytes(self.size(program)),
            .array => |a| program.types.get(a.type).?.alignment(program),
            .@"struct" => |s| s.alignment,
        };
    }
}; // 12

pub const Types = struct {
    types: std.AutoHashMapUnmanaged(TypeName, Type), // 65534 - d8, 65533 - d16, 65532 - d32, ...
    enums_fields: std.ArrayList(Type.EnumField),
    structs_fields: std.ArrayList(std.ArrayList(Type.StructField)),
    arrays: std.AutoHashMapUnmanaged(Type.Array, TypeName),
    next_complex: TypeName, // Moves from 65529 downwards

    const GetOrPutResult = std.AutoHashMapUnmanaged(TypeName, Type).GetOrPutResult;

    const empty = @This(){
        .types = .empty,
        .enums_fields = .empty,
        .structs_fields = .empty,
        .arrays = .empty,
        .next_complex = undefined,
    };

    pub fn get(self: Types, key: Label) ?Type {
        return self.types.get(key);
    }

    pub fn getOrPut(self: *Types, key: Label) std.mem.Allocator.Error!GetOrPutResult {
        return try self.types.getOrPut(utils.alloc, key);
    }

    pub fn contains(self: Types, key: Label) bool {
        return self.types.contains(key);
    }

    pub fn putNoClobber(self: *Types, key: Label, value: Type) std.mem.Allocator.Error!void {
        return self.types.putNoClobber(utils.alloc, key, value);
    }

    /// Puts array type in types if not existed yet and return its index
    pub fn putArrayType(self: *Types, value: Type.Array) std.mem.Allocator.Error!TypeName {
        const res = try self.arrays.getOrPut(utils.alloc, value);
        if (!res.found_existing) {
            const ind = self.next_complex;
            try self.types.putNoClobber(utils.alloc, ind, .{ .array = value });
            res.value_ptr.* = ind;
            self.next_complex -= 1;
        }
        return res.value_ptr.*;
    }

    /// Puts anonymous struct type in types and returns its index
    pub fn putAnonStruct(self: *Types, value: Type) std.mem.Allocator.Error!TypeName {
        std.debug.assert(value == .@"struct");
        const ind = self.next_complex;
        try self.types.putNoClobber(utils.alloc, ind, value);
        self.next_complex -= 1;
        return ind;
    }

    pub fn isUniqueEnumField(self: Types, field_name: Label, start_from: u32) bool {
        for (self.enums_fields.items[start_from..]) |field| {
            if (field.name == field_name) return false;
        }
        return true;
    }

    pub fn isUniqueStructField(self: Types, fields: []Type.StructField, field_name: Label) bool {
        _ = self;
        for (fields) |field| {
            if (field.name == field_name) return false;
        }
        return true;
    }

    pub fn getStructField(self: *Types, fields: []Type.StructField, field: Label) ?Type.StructField {
        _ = self;
        for (fields) |f| {
            if (f.name == field) return f;
        } else {
            return null;
        }
    }

    pub fn getEnumField(self: *Types, fields: []Type.EnumField, field: Label) ?Type.EnumField {
        _ = self;
        for (fields) |f| {
            if (f.name == field) return f;
        } else {
            return null;
        }
    }

    pub fn putStructFields(self: *Types, fiedls: std.ArrayList(Type.StructField)) std.mem.Allocator.Error!u16 {
        const ind: u16 = @truncate(self.structs_fields.items.len);
        try self.structs_fields.append(utils.alloc, fiedls);
        return ind;
    }

    pub fn deinit(self: *Types) void {
        self.enums_fields.deinit(utils.alloc);
        for (self.structs_fields.items) |*flds| {
            flds.deinit(utils.alloc);
        }
        self.structs_fields.deinit(utils.alloc);
        self.types.deinit(utils.alloc);
        self.arrays.deinit(utils.alloc);
    }
};

pub const DataBlock = struct {
    buffer: Buffer = .empty,
    alignment: Alignment = 0,

    /// Returns aligned len.
    pub fn alignBuffer(self: *DataBlock, alignment: Alignment) std.mem.Allocator.Error!u32 {
        const next_aligned = alignOffset(@truncate(self.buffer.items.len), alignment);
        const padding = next_aligned - @as(u32, @truncate(self.buffer.items.len));
        try self.buffer.appendNTimes(utils.alloc, 0, padding);

        self.alignment = @max(self.alignment, alignment); // ???
        return next_aligned;
    }
};

pub const BssBlock = struct {
    len: u32 = 0,
    alignment: Alignment = 0,

    pub fn alignBuffer(self: *BssBlock, alignment: Alignment) void {
        self.len = alignOffset(self.len, alignment);

        self.alignment = @max(self.alignment, alignment); // ???
    }
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
    offset: u32,
    size: u32,
    type: TypeName,
    visib: LabelType,
    block: BlockType,
};

const Function = struct {
    local_labels: std.AutoHashMapUnmanaged(Label, void),
    offset: u32,
    size: u32,
    visib: LabelType,
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
constants: std.AutoHashMapUnmanaged(Label, Immediate),
types: Types,
data_block: DataBlock,
bss_block: BssBlock,
code_block: CodeBlock,
shared_libs: std.ArrayList(Label),
data_vars: std.AutoHashMapUnmanaged(Label, DataVariable),
funcs: std.AutoHashMapUnmanaged(Label, Function),
imports: std.AutoHashMapUnmanaged(Label, u16),
relocations: std.ArrayList(Relocation),

line_program: std.ArrayList(LineProgramEntry),

pub fn init(self: *Program, content: []const u8, file_name: []const u8) std.mem.Allocator.Error!void {
    self.file_name = file_name;
    self.content = content;
    self.flags = ProgramFlags{};
    self.tokens = .empty;
    self.entry = 0;
    self.constants = .empty;
    self.types = .empty;
    try self.initBasicTypes();
    self.data_block = DataBlock{};
    self.bss_block = BssBlock{};
    self.code_block = CodeBlock{};
    self.shared_libs = .empty;
    self.data_vars = .empty;
    self.funcs = .empty;
    self.imports = .empty;
    self.relocations = .empty;
    self.line_program = .empty;
}

fn initBasicTypes(self: *Program) std.mem.Allocator.Error!void {
    try self.types.putNoClobber(std.math.maxInt(Label) - 1, .{ .d8 = {} });
    try self.types.putNoClobber(std.math.maxInt(Label) - 2, .{ .d16 = {} });
    try self.types.putNoClobber(std.math.maxInt(Label) - 3, .{ .d32 = {} });
    try self.types.putNoClobber(std.math.maxInt(Label) - 4, .{ .d64 = {} });
    try self.types.putNoClobber(std.math.maxInt(Label) - 5, .{ .d128 = {} });
    self.types.next_complex = std.math.maxInt(TypeName) - 6;
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

    if (self.constants.count() > 0) {
        std.debug.print("constants\n", .{});
        var const_iter = self.constants.iterator();
        while (const_iter.next()) |constant| {
            std.debug.print("{s}: ", .{utils.stringValue(constant.key_ptr.*)});
            switch (constant.value_ptr.*.sign) {
                .i => std.debug.print("{d}\n", .{constant.value_ptr.*.negative()}),
                .u => std.debug.print("{d}\n", .{constant.value_ptr.*.bits}),
            }
        }
    }

    if (self.types.types.count() > 0) {
        std.debug.print("types\n", .{});
        var types_iter = self.types.types.iterator();
        while (types_iter.next()) |entry| {
            const t = entry.value_ptr.*;
            switch (t) {
                .@"enum" => |e| {
                    const enum_name = utils.stringValue(entry.key_ptr.*);
                    const fields = self.types.enums_fields.items[e.fields_start..e.fields_end];
                    std.debug.print("enum {s}, size: {d} b:\n", .{ enum_name, e.data_size });
                    for (fields) |f| {
                        const f_name = utils.stringValue(f.name);
                        std.debug.print(" {d} - {s}\n", .{ f.value, f_name });
                    }
                },
                .@"struct" => |s| {
                    if (entry.key_ptr.* > std.math.maxInt(u16) / 2) continue;
                    const struct_name = utils.stringValue(entry.key_ptr.*);
                    const fields = self.types.structs_fields.items[s.fields].items;
                    std.debug.print("struct {s}, align: {d} b, size: {d} b:\n", .{ struct_name, bytesFromAlignment(s.alignment), s.size });
                    for (fields) |f| {
                        const f_name = utils.stringValue(f.name);
                        std.debug.print(" {d:4} - {s}: align: {d} b, size: {d} b\n", .{ f.offset, f_name, bytesFromAlignment(f.alignment), self.types.get(f.type).?.size(self) });
                    }
                },
                else => {},
            }
        }
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
        var locals_iter = func.value_ptr.local_labels.keyIterator();
        while (locals_iter.next()) |local| {
            std.debug.print("          {s:<20}\n", .{utils.stringValue(local.*)});
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
    printBuffer(self.data_block.buffer.items);
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

pub fn printCodeOperand(self: *Program, oper: CodeOperand) void {
    _ = self;
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
            const base = if (oper.op.mem.base.size() > 0) oper.op.mem.base.name else null;
            const index = if (oper.op.mem.index.size() > 0) oper.op.mem.index.name else null;
            const scale = oper.op.mem.scale;
            const disp = oper.op.mem.disp;
            const label = oper.op.mem.label;

            if (oper.op.mem.size > 0) {
                std.debug.print("p{d} ", .{oper.op.mem.size * 8});
            }
            std.debug.print("[", .{});
            if (oper.op.mem.base.size() > 0) {
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
}

pub fn printCPUInstruction(self: *Program, instr: CpuInstruction) void {
    std.debug.print("\x1b[35m {t} \x1b[0m", .{instr.mnem});
    for (0..instr.operands.len) |i| {
        const oper = self.code_block.operands.items[instr.operands.index + i];
        self.printCodeOperand(oper);

        if (i < instr.operands.len - 1) {
            std.debug.print(", ", .{});
        }
    }
}

pub fn deinit(self: *Program) void {
    utils.alloc.free(self.content);
    self.tokens.deinit(utils.alloc);
    self.constants.deinit(utils.alloc);
    self.types.deinit();
    self.data_block.buffer.deinit(utils.alloc);
    self.code_block.operands.deinit(utils.alloc);
    self.code_block.instr.deinit(utils.alloc);
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
