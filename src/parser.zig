const std = @import("std");
const lexer = @import("lexer");

const MAX_OPERAND_COUNT = 3;

pub const Register = struct {
    name: lexer.TokenType,
    size: u8,

    pub fn init(reg: lexer.TokenType) !Register {
        const r = @intFromEnum(reg);
        if (reg.isReg()) {
            const r64_end = @intFromEnum(lexer.TokenType.R15);
            const r32_end = @intFromEnum(lexer.TokenType.R15d);
            const r16_end = @intFromEnum(lexer.TokenType.R15w);
            if (r <= r64_end) {
                return Register{ .name = reg, .size = 8 };
            } else if (r <= r32_end) {
                return Register{ .name = reg, .size = 4 };
            } else if (r <= r16_end) {
                return Register{ .name = reg, .size = 2 };
            } else {
                return Register{ .name = reg, .size = 1 };
            }
        } else {
            // error - not a register name
            return Register{ .name = reg, .size = undefined };
        }
    }
};

pub const ComplexAddress = struct {
    base: Register,
    index: ?Register,
    scale: ?u8,
};

pub const MemOperand = struct {
    mem: union(enum) {
        label: []u8,
        addr: ComplexAddress,
    },
    size: ?u8,
};

pub const Operand = union(enum) {
    reg: Register,
    imm: i64,
    mem: MemOperand,
    label: struct {
        name: []u8,
    },
};

pub const CpuInstruction = struct {
    mnem: lexer.TokenType,
    operands: std.ArrayList(Operand),
    size: u8,
};

const CodeLabel = struct {
    name: []u8,
};

const DataLabel = struct {
    name: []u8,
};

const DataInitialization = union(enum) {
    str_lit: []u8,
    num_lit: []u8,
    repeat: struct {
        count: []u8,
        item: union(enum) {
            str_lit: []u8,
            num_lit: []u8,
        },
    },
};

const DataInstruction = struct {
    label: DataLabel,
    type: lexer.TokenType,
    data: std.ArrayList(DataInitialization),
};

pub const CodeInstruction = union(enum) {
    label: CodeLabel,
    cpu: CpuInstruction,
};

const SectionFlag = enum {
    Read,
    Write,
    Exec,
};

const SectionFlags = struct {
    read: bool,
    write: bool,
    exec: bool,

    pub fn empty() SectionFlags {
        return SectionFlags{ .read = false, .write = false, .exec = false };
    }
};

const SectionType = enum {
    Data,
    Code,
};

pub const DataSection = struct {
    name: []const u8,
    flags: SectionFlags,
    instr: std.ArrayList(DataInstruction),

    pub fn new() DataSection {
        return DataSection{
            .name = ".data",
            .flags = SectionFlags.empty(),
            .instr = .empty,
        };
    }
};

pub const CodeSection = struct {
    name: []const u8,
    flags: SectionFlags,
    instr: std.ArrayList(CodeInstruction),

    pub fn new() CodeSection {
        return CodeSection{
            .name = ".text",
            .flags = SectionFlags.empty(),
            .instr = .empty,
        };
    }
};

const Section = struct {
    type: SectionType,
    section: union {
        data: DataSection,
        code: CodeSection,
    },
};

const Entry = struct {
    addr: u64,
    name: []u8,
};

const Program = struct {
    entry: Entry,
    //flags
    sections: std.ArrayList(Section),
};

pub var program: Program = undefined;

fn parseEntry(tokens: []lexer.Token, allocator: std.mem.Allocator) !void {
    _ = allocator;
    const next = tokens[0];
    if (next.type == .Ident) {
        const result = try cl_table.getOrPut(next.value.?);
        if (!result.found_existing) {
            result.value_ptr.defined = false;
            program.entry.name = next.value.?;
        }
    } else {
        // error - invalid entry name
    }
    if (tokens[1].type != .NewLine) {
        // error - unexpected symbols on line
    }
}

fn parseDataSectionFlag(token: lexer.Token, data_section: *DataSection) !void {
    if (token.type == .Ident and token.value.?.len <= 3) {
        for (token.value.?) |char| {
            switch (char) {
                'r' => {
                    data_section.flags.read = true;
                },
                'w' => {
                    data_section.flags.write = true;
                },
                'x' => {
                    data_section.flags.exec = true;
                },
                else => {
                    // error - wrong flag
                },
            }
        }
    } else {
        // error - expected flag
    }
}

fn parseRepeat(tokens: []lexer.Token, allocator: std.mem.Allocator, instr: *DataInstruction) !void {
    var data_init: DataInitialization = undefined;
    if (tokens[0].type == .OpenParenthes) {
        if (tokens[1].type == .NumberLiteral) {
            if (tokens[2].type == .Comma) {
                if (tokens[3].type == .NumberLiteral) {
                    data_init = .{ .repeat = .{ .count = tokens[1].value.?, .item = .{ .num_lit = tokens[3].value.? } } };
                } else if (tokens[3].type == .StringLiteral) {
                    data_init = .{ .repeat = .{ .count = tokens[1].value.?, .item = .{ .str_lit = tokens[3].value.? } } };
                } else {
                    // error - expected number or string literals
                }
                if (tokens[4].type == .CloseParenthes) {
                    try instr.data.append(allocator, data_init);
                } else {
                    // error - expected close parenth
                }
            } else {
                // error - expected comma
            }
        } else {
            // error - expected number
        }
    } else {
        // error - expected open parenth
    }
}

fn parseDataInstruction(tokens: []lexer.Token, allocator: std.mem.Allocator, data_section: *DataSection) !void {
    var instruction: DataInstruction = undefined;
    const lower = @intFromEnum(lexer.TokenType.D8);
    const upper = @intFromEnum(lexer.TokenType.D64);
    if (tokens[0].type == .Ident) {
        if (tokens[1].type == .Colon) {
            const dir = @intFromEnum(tokens[2].type);
            if (dir >= lower and dir <= upper) {
                instruction.label.name = tokens[0].value.?;
                instruction.type = tokens[2].type;
                instruction.data = .empty;
                var expect_value = true;
                var i: usize = 3;
                while (i < tokens.len) {
                    const token = tokens[i];
                    switch (token.type) {
                        .StringLiteral => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                // error - expected comma
                            }
                            const data_init: DataInitialization = .{ .str_lit = token.value.? };
                            try instruction.data.append(allocator, data_init);
                        },
                        .NumberLiteral => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                // error - expected comma
                            }
                            const data_init: DataInitialization = .{ .num_lit = token.value.? };
                            try instruction.data.append(allocator, data_init);
                        },
                        .Repeat => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                // error - expected comma
                            }
                            try parseRepeat(tokens[i + 1 ..], allocator, &instruction);
                            i += 5;
                        },
                        .Comma => {
                            if (!expect_value) {
                                expect_value = true;
                            } else {
                                // error - unexpected comma
                            }
                        },
                        else => {
                            // error - unexpected value
                        },
                    }
                    i += 1;
                }
                try data_section.instr.append(allocator, instruction);
            } else {
                // error - expected size directive
            }
        } else {
            // error - expected colon
        }
    } else {
        // error - expected label name
    }
}

fn parseDataSection(tokens: []lexer.Token, allocator: std.mem.Allocator) !usize {
    var data_section = DataSection.new();
    const first = tokens[0];
    try parseDataSectionFlag(first, &data_section);
    if (tokens[1].type == .NewLine) {
        var current_instruction: []lexer.Token = tokens[2..2];
        var i: usize = 2;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
                try parseDataInstruction(current_instruction, allocator, &data_section);
                current_instruction.ptr = tokens[i + 1 .. i + 1].ptr;
                current_instruction.len = 0;
            } else if (token.type == .Section) {
                // calibration needed
                const section: Section = .{ .type = .Data, .section = .{ .data = data_section } };
                try program.sections.append(allocator, section);
                return i;
            } else {
                current_instruction.len += 1;
            }
        }
    } else {
        // error - unexpected symbols on line
    }
    return tokens.len;
}

fn parseCodeSectionFlag(token: lexer.Token, code_section: *CodeSection) !void {
    if (token.type == .Ident and token.value.?.len <= 3) {
        for (token.value.?) |char| {
            switch (char) {
                'r' => {
                    code_section.flags.read = true;
                },
                'w' => {
                    code_section.flags.write = true;
                },
                'x' => {
                    code_section.flags.exec = true;
                },
                else => {
                    // error - wrong flag
                },
            }
        }
    } else {
        // error - expected flag
    }
}

fn parseOperand(tokens: []lexer.Token) !Operand {
    var oper: Operand = undefined;
    switch (tokens.len) {
        0 => {
            // error - absent operand
        },
        1 => {
            const token = tokens[0];
            if (token.type.isReg()) {
                oper = .{ .reg = try Register.init(token.type) };
                return oper;
            } else if (token.type == .Ident) {
                oper = .{ .label = .{ .name = token.value.? } };
                // add label?
                return oper;
            } else if (token.type == .NumberLiteral) {
                const value = try std.fmt.parseInt(i64, token.value.?, 10);
                oper = .{ .imm = value };
                return oper;
            } else if (token.type == .StringLiteral) {
                if (token.value.?.len > 0 and token.value.?.len < 2) {
                    const value = token.value.?[0];
                    oper = .{ .imm = value };
                    return oper;
                } else {
                    // error - invalid string literal length (must be 1 char)
                }
            } else {
                // error - invalid operand
            }
        },
        3 => {
            if (tokens[0].type == .OpenBracket) {
                if (tokens[2].type == .CloseBracket) {
                    const token = tokens[1];
                    if (token.type.isReg()) {
                        oper = .{ .mem = .{ .mem = .{ .addr = .{ .base = try Register.init(token.type), .index = null, .scale = null } }, .size = null } };
                        return oper;
                    } else if (token.type == .Ident) {
                        oper = .{ .mem = .{ .mem = .{ .label = token.value.? }, .size = null } };
                        return oper;
                    } else {
                        // error - invalid memory operand
                    }
                } else {
                    // error - expected closed bracket
                }
            } else {
                // error - invalid operand
            }
        },
        4 => {
            if (tokens[0].type.isPointerSize()) {
                const mem_size: u8 = switch (tokens[0].type) {
                    .P8 => 1,
                    .P16 => 2,
                    .P32 => 4,
                    .P64 => 8,
                    else => unreachable,
                };
                if (tokens[1].type == .OpenBracket) {
                    if (tokens[3].type == .CloseBracket) {
                        const token = tokens[2];
                        if (token.type.isReg()) {
                            oper = .{ .mem = .{ .mem = .{ .addr = .{ .base = try Register.init(token.type), .index = null, .scale = null } }, .size = mem_size } };
                            return oper;
                        } else if (token.type == .Ident) {
                            oper = .{ .mem = .{ .mem = .{ .label = token.value.? }, .size = mem_size } };
                            return oper;
                        } else {
                            // error - invalid memory operand
                        }
                    } else {
                        // error - expected closed bracket
                    }
                } else {
                    // error - invalid operand
                }
            } else {
                // error - invalid operand
            }
        },
        5 => {
            if (tokens[0].type == .OpenBracket) {
                if (tokens[4].type == .CloseBracket) {
                    if (tokens[2].type == .Plus) {
                        const tok1 = tokens[1];
                        const tok2 = tokens[3];
                        if (tok1.type.isReg()) {
                            oper = .{ .mem = .{ .mem = .{ .addr = .{ .base = try Register.init(tok1.type), .index = null, .scale = null } }, .size = null } };
                            if (tok2.type.isReg()) {
                                oper.mem.mem.addr.index = try Register.init(tok2.type);
                                return oper;
                            } else if (tok2.type == .NumberLiteral) {
                                // TODO: number displacement
                            } else {
                                // error - unknown type of displacement
                            }
                        } else if (tok1.type == .Ident) {
                            // TODO: label name as base
                        } else {
                            // error - unknown type of base
                        }
                    } else {
                        // error - should be plus sign
                    }
                } else {
                    // error - expected closed bracket
                }
            } else {
                // error - invalid operand
            }
        },
        else => {
            // error - invalid operand
        },
    }
    return oper;
}

fn parseCodeInstruction(tokens: []lexer.Token, allocator: std.mem.Allocator, code_section: *CodeSection) !void {
    var instruction: CodeInstruction = undefined;
    if (tokens[0].type == .Ident) {
        if (tokens[1].type == .Colon) {
            const check_dl = dl_table.contains(tokens[0].value.?);
            const check_cl = cl_table.contains(tokens[0].value.?);
            if (!check_dl) {
                if (!check_cl or std.mem.eql(u8, tokens[0].value.?, program.entry.name)) {
                    const result = try cl_table.getOrPut(tokens[0].value.?);
                    result.value_ptr.defined = true;
                    instruction = .{ .label = .{ .name = tokens[0].value.? } };
                    try code_section.instr.append(allocator, instruction);
                } else {
                    // error - label already defined
                }
            } else {
                // error - label already defined in data section
            }
        } else {
            // error - expected colon
        }
    } else if (tokens[0].type.isMnemonic()) {
        // instruction.cpu.mnem = tokens[0].type;
        instruction = .{ .cpu = .{ .mnem = tokens[0].type, .operands = .empty, .size = undefined } };
        var i: usize = 1;
        var operand_number: usize = 0;
        var oper_tokens: []lexer.Token = tokens[1..1];
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .Comma or i == tokens.len - 1) {
                if (i == tokens.len - 1) {
                    oper_tokens.len += 1;
                }
                const operand = try parseOperand(oper_tokens);
                if (operand_number <= 3) {
                    try instruction.cpu.operands.append(allocator, operand);
                    operand_number += 1;
                    oper_tokens = tokens[i + 1 .. i + 1];
                } else {
                    // error - too many operands on line
                }
            } else {
                oper_tokens.len += 1;
            }
        }
        try code_section.instr.append(allocator, instruction);
    } else {
        // error - invalid symbol (must be label name or instr mnemonic)
    }
}

fn parseCodeSection(tokens: []lexer.Token, allocator: std.mem.Allocator) !usize {
    var code_section = CodeSection.new();
    const first = tokens[0];
    try parseCodeSectionFlag(first, &code_section);
    if (tokens[1].type == .NewLine) {
        var current_instruction: []lexer.Token = tokens[2..2];
        var i: usize = 2;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
                try parseCodeInstruction(current_instruction, allocator, &code_section);
                current_instruction.ptr = tokens[i + 1 .. i + 1].ptr;
                current_instruction.len = 0;
            } else if (token.type == .Section) {
                // calibration needed
                const section: Section = .{ .type = .Code, .section = .{ .code = code_section } };
                try program.sections.append(allocator, section);
                return i;
            } else {
                current_instruction.len += 1;
            }
        }
    } else {
        // error - unexpected symbols on line
    }
    const section: Section = .{ .type = .Code, .section = .{ .code = code_section } };
    try program.sections.append(allocator, section);
    return tokens.len;
}

pub fn parseTokensToAST(allocator: std.mem.Allocator) !void {
    dl_table = std.StringHashMap(Record).init(allocator);
    cl_table = std.StringHashMap(Record).init(allocator);
    var entry_found = false;
    var i: usize = 0;
    while (i < lexer.tokens.items.len) : (i += 1) {
        const token = lexer.tokens.items[i];
        if (i == 0 and token.type != .Entry) {
            // error - first instruction should be 'entry'
        }
        if (token.type == .Entry) {
            if (!entry_found) {
                try parseEntry(lexer.tokens.items[i + 1 ..], allocator);
                entry_found = true;
                i += 2;
                continue;
            } else {
                // error - second 'entry' keyword
            }
        } else if (token.type == .Section) {
            if (lexer.tokens.items[i + 1].type == .Data) {
                const len = try parseDataSection(lexer.tokens.items[i + 2 ..], allocator);
                i += (len + 1);
            } else if (lexer.tokens.items[i + 1].type == .Code) {
                const len = try parseCodeSection(lexer.tokens.items[i + 2 ..], allocator);
                i += (len + 1);
            } else {
                // error - unknown section type
            }
        }
    }
}

const Record = struct {
    defined: bool,
    offset: usize,
};

pub var dl_table: std.StringHashMap(Record) = undefined;
pub var cl_table: std.StringHashMap(Record) = undefined;

pub fn printAST() void {
    std.debug.print("entry: {s}\n", .{program.entry.name});
    for (program.sections.items) |section| {
        std.debug.print("section {}\n", .{section.type});
        if (section.type == .Data) {
            std.debug.print("flags: r - {}, w - {}, e - {}\n", .{ section.section.data.flags.read, section.section.data.flags.write, section.section.data.flags.exec });
            for (section.section.data.instr.items) |instr| {
                std.debug.print(" {s}: {} ", .{ instr.label.name, instr.type });
                for (instr.data.items, 0..) |item, i| {
                    switch (item) {
                        .num_lit => {
                            std.debug.print("{s}", .{item.num_lit});
                        },
                        .str_lit => {
                            std.debug.print("\"{s}\"", .{item.str_lit});
                        },
                        .repeat => {
                            switch (item.repeat.item) {
                                .num_lit => {
                                    std.debug.print("rep({s}, {s})", .{ item.repeat.count, item.repeat.item.num_lit });
                                },
                                .str_lit => {
                                    std.debug.print("rep({s}, \"{s}\")", .{ item.repeat.count, item.repeat.item.str_lit });
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
        } else if (section.type == .Code) {
            std.debug.print("flags: r - {}, w - {}, e - {}\n", .{ section.section.code.flags.read, section.section.code.flags.write, section.section.code.flags.exec });
            for (section.section.code.instr.items) |instr| {
                switch (instr) {
                    .cpu => {
                        std.debug.print(" {} ", .{instr.cpu.mnem});
                        for (instr.cpu.operands.items, 0..) |oper, i| {
                            switch (oper) {
                                .imm => {
                                    std.debug.print("{}", .{oper.imm});
                                },
                                .label => {
                                    std.debug.print("{s}", .{oper.label.name});
                                },
                                .reg => {
                                    std.debug.print("{}", .{oper.reg.name});
                                },
                                .mem => {
                                    switch (oper.mem.mem) {
                                        .label => {
                                            std.debug.print("p{?} [{s}]", .{ oper.mem.size, oper.mem.mem.label });
                                        },
                                        .addr => {
                                            std.debug.print("p{?} [{}+{?}*{?}]", .{ oper.mem.size, oper.mem.mem.addr.base.name, oper.mem.mem.addr.index, oper.mem.mem.addr.scale });
                                        },
                                    }
                                },
                            }
                            if (i < instr.cpu.operands.items.len - 1) {
                                std.debug.print(", ", .{});
                            }
                        }
                    },
                    .label => {
                        std.debug.print("label {s}:", .{instr.label.name});
                    },
                }
                std.debug.print("\n", .{});
            }
        }
        std.debug.print("\n", .{});
    }
}
