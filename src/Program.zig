const std = @import("std");
const utils = @import("utils");
const lexer = @import("lexer");
const TokenType = lexer.TokenType;
const Token = lexer.Token;
const Parser = @import("Parser");
const datagen = @import("datagen");
const Codegen = @import("Codegen");

const Buffer = std.ArrayList(u8);

/// System-agnostic source file internal representation
const Program = @This();

pub const Register = struct {
    name: TokenType,
    size: u8,

    /// Caller must be sure that reg param is actually register name
    pub fn init(reg: TokenType) Register {
        const r = @intFromEnum(reg);
        const r64_end = @intFromEnum(TokenType.r15);
        const r32_end = @intFromEnum(TokenType.r15d);
        const r16_end = @intFromEnum(TokenType.r15w);
        if (r <= r64_end) {
            return Register{ .name = reg, .size = 8 };
        } else if (r <= r32_end) {
            return Register{ .name = reg, .size = 4 };
        } else if (r <= r16_end) {
            return Register{ .name = reg, .size = 2 };
        } else {
            return Register{ .name = reg, .size = 1 };
        }
    }
};

pub const Displacement = i32;
pub const Scale = u8;

pub const Address = struct {
    base: ?Register,
    scale: ?Scale,
    index: ?Register,
    disp: ?Displacement,
    label: ?[]const u8,
};

pub const Immediate = union(enum) {
    u: u64,
    i: i64,

    pub fn toNegative(self: *Immediate) std.fmt.ParseIntError!void {
        switch (self.*) {
            .u => {
                const unsigned = self.u;
                if (unsigned < std.math.maxInt(i64)) {
                    const signed: i64 = @intCast(unsigned);
                    self.* = .{ .i = -signed };
                } else {
                    return std.fmt.ParseIntError.Overflow;
                }
            },
            else => {},
        }
    }

    pub fn fitsInBytes(self: Immediate) u8 {
        switch (self) {
            .i => {
                if (self.i >= std.math.minInt(i8) and self.i <= std.math.maxInt(i8)) {
                    return 1;
                } else if (self.i >= std.math.minInt(i16) and self.i <= std.math.maxInt(i16)) {
                    return 2;
                } else if (self.i >= std.math.minInt(i32) and self.i <= std.math.maxInt(i32)) {
                    return 4;
                } else {
                    return 8;
                }
            },
            .u => {
                if (self.u <= std.math.maxInt(u8)) {
                    return 1;
                } else if (self.u <= std.math.maxInt(u16)) {
                    return 2;
                } else if (self.u <= std.math.maxInt(u32)) {
                    return 4;
                } else {
                    return 8;
                }
            },
        }
    }
};

pub const MemOperand = struct {
    addr: Address,
    size: ?u8,
};

pub const CodeOperand = union(enum) {
    reg: Register,
    mem: MemOperand,
    imm: Immediate,
    label: struct {
        l: []const u8,
        d: Immediate,
    },
};

pub const CpuInstruction = struct {
    mnem: TokenType,
    operands: std.ArrayList(CodeOperand),
    line: u16,
};

pub const LabelInstruction = struct {
    name: []const u8,
    line: u16,
};

pub const DataOperand = union(enum) {
    str: []const u8,
    num: Immediate,
    repeat: struct {
        count: u32,
        item: union(enum) {
            str: []u8,
            num: Immediate,
        },
    },
};

pub const DataInstruction = struct {
    label: []const u8,
    size: u8,
    data: std.ArrayList(DataOperand),
    line: u16,
};

pub const CodeInstruction = union(enum) {
    label: LabelInstruction,
    cpu: CpuInstruction,
};

pub const DataBlock = struct {
    instr: std.ArrayList(DataInstruction),
    buffer: Buffer,

    const empty = @This(){
        .instr = .empty,
        .buffer = .empty,
    };
};

pub const CodeBlock = struct {
    instr: std.ArrayList(CodeInstruction) = .empty,
    buffer: Buffer = .empty,

    const empty = @This(){
        .instr = .empty,
        .buffer = .empty,
    };
};

pub const Symbol = struct {
    offset: u64,
    type: enum {
        Local,
        Export,
        Import,
        Hidden,
    },
    section: enum {
        Data,
        Code,
        Undef,
    },
    shared_ind: u16,
};

pub const RelType = enum {
    Abs64,
    Abs32,
    Abs32S,
    Rel32C,
    Rel32D,
};

pub const Relocation = struct {
    type: RelType,
    name: []const u8,
    offset: u64,
    addend: i64,

    pub const empty = @This(){
        .type = .Rel32D,
        .name = &.{},
        .offset = 0,
        .addend = 0,
    };
};

pub const LineProgramEntry = struct {
    offset: usize,
    line: usize,
};

const LabelType = enum { Local, Export };

const DataVariable = struct {
    visib: LabelType,
    offset: usize,
    size: usize,
};

const Function = struct {
    visib: LabelType,
    offset: usize,
    size: usize,
    local_labels: std.StringHashMapUnmanaged(usize),
};

const ProgramFlags = struct {
    has_entry: bool = false,
    has_data: bool = false,
    has_code: bool = false,
    has_shared: bool = false,
    debug: bool = false,
    pic: bool = false,
    warnings: bool = true,
    quiet: bool = false,
};

file_name: []const u8,
content: []const u8,
flags: ProgramFlags,
tokens: std.ArrayList(Token),
entry: []const u8,
data_block: DataBlock,
code_block: CodeBlock,
shared_libs: std.ArrayList([]const u8),
data_vars: std.StringHashMapUnmanaged(DataVariable),
funcs: std.StringHashMapUnmanaged(Function),
imports: std.StringHashMapUnmanaged(u16),
relocations: std.ArrayList(Relocation),

line_program: std.ArrayList(LineProgramEntry),

pub fn init(self: *Program, content: []const u8, file_name: []const u8, debug: bool, pic: bool, warnings: bool, quiet: bool) void {
    if (!quiet) {
        std.debug.print("program.file_name: {s}\n", .{file_name});
    }
    self.file_name = file_name;
    self.content = content;
    self.flags = .{ .debug = debug, .pic = pic, .warnings = warnings, .quiet = quiet };
    self.tokens = .empty;
    self.entry = &.{};
    self.data_block = .empty;
    self.code_block = .empty;
    self.shared_libs = .empty;
    self.data_vars = .empty;
    self.funcs = .empty;
    self.imports = .empty;
    self.relocations = .empty;
    self.line_program = .empty;
}

pub fn lexicalAnalyzis(self: *Program) lexer.LexerError!void {
    self.tokens = try lexer.tokenizeContent(self.content, self.file_name);
}

pub fn syntaxAnalyzis(self: *Program) Parser.ParserError!void {
    var parser = Parser.init(self);
    try parser.parseTokens();
}

pub fn dataGen(self: *Program) datagen.DatagenError!void {
    try datagen.genDataBlockBuffer(self);
}

pub fn codeGen(self: *Program) Codegen.CodegenError!void {
    var codegen = Codegen.init(self);
    defer codegen.deinit();
    try codegen.genCodeBlockBuffer();
}

pub fn printBuffer(buf: []const u8) void {
    for (buf) |byte| {
        std.debug.print("{x:02}", .{byte});
    }
    std.debug.print("\n", .{});
}

pub fn printProgram(self: *Program) void {
    if (self.flags.has_entry) {
        std.debug.print("entry: {s}\n", .{self.entry});
    }

    if (self.flags.has_data) {
        std.debug.print("data block\n", .{});
        for (self.data_block.instr.items) |instr| {
            std.debug.print(" {s}: d{d} ", .{ instr.label, instr.size * 8 });
            for (instr.data.items, 0..) |item, i| {
                switch (item) {
                    .num => {
                        switch (item.num) {
                            .i => {
                                std.debug.print("{d}", .{item.num.i});
                            },
                            .u => {
                                std.debug.print("{d}", .{item.num.u});
                            },
                        }
                    },
                    .str => {
                        std.debug.print("\"{s}\"", .{item.str});
                    },
                    .repeat => {
                        switch (item.repeat.item) {
                            .num => {
                                switch (item.repeat.item.num) {
                                    .i => {
                                        std.debug.print("rep({d}, {d})", .{ item.repeat.count, item.repeat.item.num.i });
                                    },
                                    .u => {
                                        std.debug.print("rep({d}, {d})", .{ item.repeat.count, item.repeat.item.num.u });
                                    },
                                }
                            },
                            .str => {
                                std.debug.print("rep({d}, \"{s}\")", .{ item.repeat.count, item.repeat.item.str });
                            },
                        }
                    },
                }
                if (i < instr.data.items.len - 1) {
                    std.debug.print(", ", .{});
                }
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
    if (self.flags.has_code) {
        std.debug.print("code block\n", .{});
        for (self.code_block.instr.items) |instr| {
            switch (instr) {
                .cpu => {
                    printCPUInstruction(instr.cpu);
                },
                .label => {
                    std.debug.print("{s}:", .{instr.label.name});
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
        std.debug.print("d  {s} 0 {s:<20} {d:4} {d:4}\n", .{
            switch (data_var.value_ptr.visib) {
                .Export => "EXP",
                .Local => "LOC",
            },
            data_var.key_ptr.*,
            data_var.value_ptr.offset,
            data_var.value_ptr.size,
        });
    }
    var code_iter = self.funcs.iterator();
    while (code_iter.next()) |func| {
        std.debug.print(" c {s} 0 {s:<20} {d:4} {d:4}\n", .{
            switch (func.value_ptr.visib) {
                .Export => "EXP",
                .Local => "LOC",
            },
            func.key_ptr.*,
            func.value_ptr.offset,
            func.value_ptr.size,
        });
        var locals_iter = func.value_ptr.local_labels.iterator();
        while (locals_iter.next()) |local| {
            std.debug.print("         {s:<20} {d:4}\n", .{
                local.key_ptr.*,
                local.value_ptr.*,
            });
        }
    }
    var import_iter = self.imports.iterator();
    while (import_iter.next()) |imp| {
        std.debug.print("-- IMP {d:1} {s:<20} 0\n", .{
            imp.value_ptr.*,
            imp.key_ptr.*,
        });
    }
    std.debug.print("imports\n", .{});
    for (self.shared_libs.items, 0..) |lib, i| {
        std.debug.print("{d}: {s}\n", .{ i, lib });
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
        std.debug.print("{s:<20} {d:016}  {t:6} {d:12}\n", .{ reloc.name, reloc.offset, reloc.type, reloc.addend });
    }
    std.debug.print("\n", .{});

    std.debug.print("line program\n", .{});
    for (self.line_program.items) |entry| {
        std.debug.print("{d:016} - {d}\n", .{ entry.offset, entry.line });
    }
    std.debug.print("\n", .{});
}

pub fn printCPUInstruction(instr: CpuInstruction) void {
    std.debug.print("\x1b[35m {t} \x1b[0m", .{instr.mnem});
    for (instr.operands.items, 0..) |oper, i| {
        switch (oper) {
            .imm => {
                switch (oper.imm) {
                    .i => {
                        std.debug.print("\x1b[33m{d}\x1b[0m", .{oper.imm.i});
                    },
                    .u => {
                        std.debug.print("\x1b[33m{d}\x1b[0m", .{oper.imm.u});
                    },
                }
            },
            .label => {
                std.debug.print("\x1b[34m{s}\x1b[0m", .{oper.label.l});
                switch (oper.label.d) {
                    .u => {
                        if (oper.label.d.u != 0) {
                            std.debug.print("\x1b[33m +{d}\x1b[0m", .{oper.label.d.u});
                        }
                    },
                    .i => {
                        if (oper.label.d.i != 0) {
                            std.debug.print("\x1b[33m {s}{d}\x1b[0m", .{ if (oper.label.d.i > 0) "+" else "", oper.label.d.i });
                        }
                    },
                }
            },
            .reg => {
                std.debug.print("\x1b[36m{t}\x1b[0m", .{oper.reg.name});
            },
            .mem => {
                const base = if (oper.mem.addr.base) |bs| bs.name else null;
                const index = if (oper.mem.addr.index) |in| in.name else null;
                const scale = oper.mem.addr.scale;
                const disp = oper.mem.addr.disp;
                const label = oper.mem.addr.label;

                if (oper.mem.size) |sz| {
                    std.debug.print("p{d} ", .{sz * 8});
                }
                std.debug.print("[", .{});
                if (base != null) {
                    std.debug.print("\x1b[36m{t}\x1b[0m", .{base.?});
                }
                if (index != null) {
                    std.debug.print("{s}\x1b[31m{t}\x1b[0m", .{ if (base != null) " + " else "", index.? });
                }
                if (scale != null) {
                    std.debug.print("*\x1b[32m{d}\x1b[0m", .{scale.?});
                }
                if (disp != null) {
                    std.debug.print("\x1b[33m{s}{s}{d}\x1b[0m", .{ if (base != null or index != null) " " else "", if (disp.? >= 0) "+" else "", disp.? });
                }
                if (label != null) {
                    std.debug.print("\x1b[34m{s}{s}\x1b[0m", .{ if (base != null or index != null or disp != null) " + " else "", label.? });
                }
                std.debug.print("]", .{});
            },
        }
        if (i < instr.operands.items.len - 1) {
            std.debug.print(", ", .{});
        }
    }
}

pub fn deinit(self: *Program) void {
    utils.alloc.free(self.content);
    self.tokens.deinit(utils.alloc);
    for (self.data_block.instr.items) |*instr| {
        instr.data.deinit(utils.alloc);
    }
    self.data_block.instr.deinit(utils.alloc);
    for (self.code_block.instr.items) |*instr| {
        switch (instr.*) {
            .cpu => instr.cpu.operands.deinit(utils.alloc),
            .label => {},
        }
    }
    self.data_block.buffer.deinit(utils.alloc);
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
