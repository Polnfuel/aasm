const std = @import("std");
const lexer = @import("lexer");
const Program = @import("program").Program;
const stdbuffers = @import("stdbuffers");

const MAX_OPERAND_COUNT = 3;

pub const Register = struct {
    name: lexer.TokenType,
    size: u8,
    /// Caller must be sure that reg param is actually register name
    pub fn init(reg: lexer.TokenType) Register {
        const r = @intFromEnum(reg);
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
    }
};

pub const Displacement = struct {
    num: i32,
};

pub const Scale = struct {
    num: u8,
};

pub const ComplexAddress = struct {
    base: ?Register,
    index: ?Register,
    scale: ?Scale,
    disp: ?Displacement,
};

pub const MemOperand = struct {
    mem: union(enum) {
        label: []u8,
        addr: ComplexAddress,
    },
    size: ?u8,
};

pub const Immediate = union(enum) {
    u: u64,
    i: i64,

    pub fn invert(self: *Immediate) std.fmt.ParseIntError!void {
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
            .i => {
                const signed = self.i;
                self.* = .{ .u = @abs(signed) };
            },
        }
    }
};

pub const Operand = union(enum) {
    reg: Register,
    imm: Immediate,
    mem: MemOperand,
    label: []u8,
};

pub const CpuInstruction = struct {
    mnem: lexer.TokenType,
    operands: std.ArrayList(Operand),
    line: u16,
};

const DataInitialization = union(enum) {
    str: []u8,
    num: Immediate,
    repeat: struct {
        count: Immediate,
        item: union(enum) {
            str: []u8,
            num: Immediate,
        },
    },
};

const DataInstruction = struct {
    label: []u8,
    size: u8,
    data: std.ArrayList(DataInitialization),
    line: u16,
};

const LabelInstruction = struct {
    name: []u8,
    line: u16,
};

pub const CodeInstruction = union(enum) {
    label: LabelInstruction,
    cpu: CpuInstruction,
};

const SectionFlags = struct {
    read: bool,
    write: bool,
    exec: bool,

    pub fn empty() SectionFlags {
        return SectionFlags{ .read = false, .write = false, .exec = false };
    }
};

pub const SymType = enum {
    Local,
    Export,
    Import,
};

const SectionType = enum {
    Data,
    Code,
    Undef,
};

pub const Symbol = struct {
    offset: u64,
    type: SymType,
    section: SectionType,
};

pub const RelType = enum {
    Abs64D,
    Abs32D,
    Rel32C,
    Rel32D,
};

pub const Relocation = struct {
    type: RelType,
    name: []u8,
    offset: u64,
    addend: i32,
};

pub const DataSection = struct {
    flags: SectionFlags,
    instr: std.ArrayList(DataInstruction),
    buffer: std.ArrayList(u8),

    pub fn new() DataSection {
        return DataSection{
            .flags = SectionFlags.empty(),
            .instr = .empty,
            .buffer = .empty,
        };
    }
};

pub const CodeSection = struct {
    flags: SectionFlags,
    instr: std.ArrayList(CodeInstruction),
    relocations: std.ArrayList(Relocation),
    buffer: std.ArrayList(u8),

    pub fn new() CodeSection {
        return CodeSection{
            .flags = SectionFlags.empty(),
            .instr = .empty,
            .buffer = .empty,
            .relocations = .empty,
        };
    }
};

pub const ParserError = error{ParsingFailed} || std.mem.Allocator.Error || std.fmt.ParseIntError;

fn parseEntry(tokens: []lexer.Token, program: *Program) ParserError!void {
    const next = tokens[0];
    if (next.type == .Ident) {
        program.entry = next.value;
    } else {
        stdbuffers.printSourceError(program.file_name, "expected identifier after entry keyword", program.content, next.line);
        return ParserError.ParsingFailed;
    }
    if (tokens[1].type != .NewLine) {
        stdbuffers.printSourceError(program.file_name, "unexpected symbols on line", program.content, tokens[1].line);
        return ParserError.ParsingFailed;
    }
}

fn parseSectionFlags(token: lexer.Token, program: *Program) ParserError!SectionFlags {
    var flags = SectionFlags.empty();
    if (token.type == .Ident and token.value.len <= 3) {
        for (token.value) |char| {
            switch (char) {
                'r' => {
                    flags.read = true;
                },
                'w' => {
                    flags.write = true;
                },
                'x' => {
                    flags.exec = true;
                },
                else => {
                    stdbuffers.printSourceError(program.file_name, "wrong section flag", program.content, token.line);
                    return ParserError.ParsingFailed;
                },
            }
        }
    } else {
        stdbuffers.printSourceError(program.file_name, "expected section flags", program.content, token.line);
        return ParserError.ParsingFailed;
    }
    return flags;
}

fn immFromNumToken(token: lexer.Token) std.fmt.ParseIntError!Immediate {
    switch (token.type) {
        .NumberLiteral, .PosNumLiteral => {
            const value = try std.fmt.parseInt(u64, token.value, 10);
            const imm = Immediate{ .u = value };
            return imm;
        },
        .NegNumLiteral => {
            const value = try std.fmt.parseInt(u64, token.value, 10);
            var imm = Immediate{ .u = value };
            try imm.invert();
            return imm;
        },
        else => unreachable,
    }
}

pub fn immMinSize(imm: Immediate) u8 {
    switch (imm) {
        .i => {
            if (imm.i >= std.math.minInt(i8) and imm.i <= std.math.maxInt(i8)) {
                return 1;
            } else if (imm.i >= std.math.minInt(i16) and imm.i <= std.math.maxInt(i16)) {
                return 2;
            } else if (imm.i >= std.math.minInt(i32) and imm.i <= std.math.maxInt(i32)) {
                return 4;
            } else {
                return 8;
            }
        },
        .u => {
            if (imm.u <= std.math.maxInt(u8)) {
                return 1;
            } else if (imm.u <= std.math.maxInt(u16)) {
                return 2;
            } else if (imm.u <= std.math.maxInt(u32)) {
                return 4;
            } else {
                return 8;
            }
        },
    }
}

fn dispFromNumToken(token: lexer.Token, program: *Program) ParserError!Displacement {
    const int = try std.fmt.parseInt(i64, token.value, 10);
    if (int >= 0) {
        var value: i32 = undefined;
        if (int >= std.math.minInt(i32) and int <= std.math.maxInt(i32)) {
            value = @intCast(int);
            if (token.type == .NegNumLiteral) {
                value = -value;
            }
        } else if (int == std.math.maxInt(i32) + 1 and token.type == .NegNumLiteral) {
            value = std.math.minInt(i32);
        } else {
            stdbuffers.printSourceError(program.file_name, "displacement value doesn't fit in 32 bits", program.content, token.line);
            return ParserError.ParsingFailed;
        }
        const disp = Displacement{ .num = value };
        return disp;
    } else {
        unreachable;
    }
}

pub fn dispMinSize(disp: Displacement) u8 {
    if (disp.num >= std.math.minInt(i8) and disp.num <= std.math.maxInt(i8)) {
        return 1;
    } else if (disp.num >= std.math.minInt(i16) and disp.num <= std.math.maxInt(i16)) {
        return 2;
    } else {
        return 4;
    }
}

fn scaleFromNumToken(token: lexer.Token, program: *Program) ParserError!Scale {
    const int = try std.fmt.parseInt(u8, token.value, 10);
    switch (int) {
        1, 2, 4, 8 => {
            return Scale{ .num = int };
        },
        else => {
            stdbuffers.printSourceErrorFormatted(program.file_name, "expected scale 1, 2, 4 or 8; found {d}", .{int}, program.content, token.line);
            return ParserError.ParsingFailed;
        },
    }
}

fn parseRepeat(tokens: []lexer.Token, data_size: u8, program: *Program, line: u16) ParserError!DataInitialization {
    var data_init: DataInitialization = undefined;
    if (tokens[0].type == .OpenParenthes) {
        switch (tokens[1].type) {
            .NumberLiteral, .PosNumLiteral => {
                const count = try immFromNumToken(tokens[1]);
                const count_value = count.u;
                if (count_value * data_size > 16378) {
                    stdbuffers.printSourceError(program.file_name, "repeat count is too large for this data size", program.content, line);
                    return ParserError.ParsingFailed;
                }
                switch (count) {
                    .u => {
                        if (tokens[2].type == .Comma) {
                            switch (tokens[3].type) {
                                .NumberLiteral, .PosNumLiteral, .NegNumLiteral => {
                                    const value = try immFromNumToken(tokens[3]);
                                    const value_size = immMinSize(value);
                                    if (value_size <= data_size) {
                                        data_init = .{ .repeat = .{ .count = count, .item = .{ .num = value } } };
                                    } else {
                                        stdbuffers.printSourceError(program.file_name, "value doesn't fit in given data size", program.content, tokens[3].line);
                                        return ParserError.ParsingFailed;
                                    }
                                },
                                .StringLiteral => {
                                    if (data_size == 1) {
                                        data_init = .{ .repeat = .{ .count = count, .item = .{ .str = tokens[3].value } } };
                                    } else {
                                        stdbuffers.printSourceError(program.file_name, "string value must have data size d8", program.content, line);
                                        return ParserError.ParsingFailed;
                                    }
                                },
                                else => {
                                    stdbuffers.printSourceError(program.file_name, "expected number or string literal", program.content, line);
                                    return ParserError.ParsingFailed;
                                },
                            }
                            if (tokens[4].type == .CloseParenthes) {
                                return data_init;
                            } else {
                                stdbuffers.printSourceError(program.file_name, "expected ')'", program.content, line);
                                return ParserError.ParsingFailed;
                            }
                        } else {
                            stdbuffers.printSourceError(program.file_name, "expected ','", program.content, line);
                            return ParserError.ParsingFailed;
                        }
                    },
                    .i => unreachable,
                }
            },
            else => {
                stdbuffers.printSourceError(program.file_name, "expected non-negative number", program.content, line);
                return ParserError.ParsingFailed;
            },
        }
    } else {
        stdbuffers.printSourceError(program.file_name, "expected '('", program.content, line);
        return ParserError.ParsingFailed;
    }
}

fn parseDataInstruction(tokens: []lexer.Token, program: *Program) ParserError!void {
    var instruction: DataInstruction = undefined;
    if (tokens[0].type == .Ident) {
        if (tokens[1].type == .Colon) {
            if (tokens[2].type.isDataDirective()) {
                const data_size: u8 = switch (tokens[2].type) {
                    .D8 => 1,
                    .D16 => 2,
                    .D32 => 4,
                    .D64 => 8,
                    else => unreachable,
                };
                instruction.label = tokens[0].value;
                instruction.size = data_size;
                instruction.data = .empty;
                errdefer instruction.data.deinit(program.allocator);
                var expect_value = true;
                var i: usize = 3;
                while (i < tokens.len) {
                    const token = tokens[i];
                    switch (token.type) {
                        .StringLiteral => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                stdbuffers.printSourceError(program.file_name, "expected ','", program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                            if (data_size == 1) {
                                const data_init: DataInitialization = .{ .str = token.value };
                                try instruction.data.append(program.allocator, data_init);
                            } else {
                                stdbuffers.printSourceError(program.file_name, "wrong data size", program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        .NumberLiteral, .NegNumLiteral, .PosNumLiteral => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                stdbuffers.printSourceError(program.file_name, "expected ','", program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                            const num = try immFromNumToken(token);
                            const num_size = immMinSize(num);
                            if (num_size <= data_size) {
                                const data_init: DataInitialization = .{ .num = num };
                                try instruction.data.append(program.allocator, data_init);
                            } else {
                                stdbuffers.printSourceError(program.file_name, "wrong data size", program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        .Repeat => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                stdbuffers.printSourceError(program.file_name, "expected ','", program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                            const data_init = try parseRepeat(tokens[i + 1 ..], data_size, program, token.line);
                            try instruction.data.append(program.allocator, data_init);
                            i += 5;
                        },
                        .Comma, .NewLine => {
                            if (!expect_value) {
                                expect_value = true;
                            } else {
                                stdbuffers.printSourceError(program.file_name, "expected ','", program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        else => {
                            if (expect_value) {
                                stdbuffers.printSourceError(program.file_name, "expected string or number literal or 'repeat' statement", program.content, token.line);
                                return ParserError.ParsingFailed;
                            } else {
                                stdbuffers.printSourceError(program.file_name, "expected ',' or end of line", program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                    }
                    i += 1;
                }

                const result = try program.symbols.getOrPut(instruction.label);
                if (result.found_existing) {
                    stdbuffers.printSourceErrorFormatted(program.file_name, "label '{s}' already defined in this file", .{instruction.label}, program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                } else {
                    result.value_ptr.type = .Local;
                    result.value_ptr.section = .Data;
                }

                try program.data_section.?.instr.append(program.allocator, instruction);
            } else {
                stdbuffers.printSourceError(program.file_name, "expected data size directive", program.content, tokens[2].line);
                return ParserError.ParsingFailed;
            }
        } else {
            stdbuffers.printSourceError(program.file_name, "expected ':'", program.content, tokens[1].line);
            return ParserError.ParsingFailed;
        }
    } else {
        stdbuffers.printSourceError(program.file_name, "expected label name", program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
}

fn parseDataSection(tokens: []lexer.Token, program: *Program) ParserError!usize {
    program.data_section = DataSection.new();
    const first = tokens[0];
    program.data_section.?.flags = try parseSectionFlags(first, program);
    if (tokens[1].type == .NewLine) {
        var current_instruction: []lexer.Token = tokens[2..2];
        var i: usize = 2;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
                current_instruction.len += 1;
                try parseDataInstruction(current_instruction, program);
                current_instruction.ptr = tokens[i + 1 .. i + 1].ptr;
                current_instruction.len = 0;
            } else if (token.type == .Section) {
                return i;
            } else {
                current_instruction.len += 1;
            }
        }
    } else {
        stdbuffers.printSourceError(program.file_name, "unexpected symbols on line", program.content, tokens[1].line);
        return ParserError.ParsingFailed;
    }
    return tokens.len;
}

fn checkMemoryOperand(oper: *MemOperand, program: *Program, line: u16) ParserError!void {
    switch (oper.mem) {
        .addr => {
            if (oper.mem.addr.disp) |disp| {
                if (disp.num == 0 and (oper.mem.addr.base != null or oper.mem.addr.index != null)) {
                    oper.mem.addr.disp = null;
                }
            }
            if (oper.mem.addr.base) |base| {
                const b_size = base.size;
                if (b_size > 2) {
                    if (oper.mem.addr.index) |index| {
                        const i_size = index.size;
                        if (b_size != i_size) {
                            stdbuffers.printSourceError(program.file_name, "base and index registers' sizes doesn't match", program.content, line);
                            return ParserError.ParsingFailed;
                        }
                    }
                } else {
                    stdbuffers.printSourceError(program.file_name, "invalid base register size", program.content, line);
                    return ParserError.ParsingFailed;
                }
            }
        },
        .label => {},
    }
}

fn parseMemoryOperand(tokens: []lexer.Token, program: *Program) ParserError!MemOperand {
    var oper: ?MemOperand = null;

    var toks: [7]lexer.TokenType = .{ .NotPresent, .NotPresent, .NotPresent, .NotPresent, .NotPresent, .NotPresent, .NotPresent };
    for (tokens, 0..) |token, i| {
        toks[i] = token.type;
    }
    const t1 = toks[0];
    const t2 = toks[1];
    const t3 = toks[2];
    const t4 = toks[3];
    const t5 = toks[4];
    const t6 = toks[5];
    const t7 = toks[6];

    if (t1.isReg()) {
        if (t2 == .Asteriks and t3 == .NumberLiteral) {
            if (t4 == .PosNumLiteral or t4 == .NegNumLiteral) {
                if (t5 == .Plus and t6.isReg()) {
                    const disp = try dispFromNumToken(tokens[3], program);
                    const scale = try scaleFromNumToken(tokens[2], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t1), .scale = scale, .disp = disp } }, .size = null };
                } else if (t5 == .NotPresent) {
                    const disp = try dispFromNumToken(tokens[3], program);
                    const scale = try scaleFromNumToken(tokens[2], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t1), .scale = scale, .disp = disp } }, .size = null };
                }
            } else if (t4 == .Plus and t5.isReg()) {
                if (t6 == .PosNumLiteral or t6 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[5], program);
                    const scale = try scaleFromNumToken(tokens[2], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t1), .scale = scale, .disp = disp } }, .size = null };
                } else if (t6 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[2], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t1), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t4 == .NotPresent) {
                const scale = try scaleFromNumToken(tokens[2], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t1), .scale = scale, .disp = null } }, .size = null };
            }
        } else if (t2 == .Plus and t3.isReg()) {
            if (t4 == .Asteriks and t5 == .NumberLiteral) {
                if (t6 == .PosNumLiteral or t6 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[5], program);
                    const scale = try scaleFromNumToken(tokens[4], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t6 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[4], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t4 == .PosNumLiteral or t4 == .NegNumLiteral) {
                const disp = try dispFromNumToken(tokens[3], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = null, .disp = disp } }, .size = null };
            } else if (t4 == .NotPresent) {
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = null, .disp = null } }, .size = null };
            }
        } else if (t2 == .PosNumLiteral) {
            if (t3 == .Asteriks and t4.isReg()) {
                if (t5 == .PosNumLiteral or t5 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[4], program);
                    const scale = try scaleFromNumToken(tokens[1], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
                } else if (t5 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[1], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t4), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t3 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[1], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = null, .scale = null, .disp = disp } }, .size = null };
            }
        } else if (t2 == .NegNumLiteral) {
            const disp = try dispFromNumToken(tokens[1], program);
            oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = null, .scale = null, .disp = disp } }, .size = null };
        } else if (t2 == .NotPresent) {
            oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = null, .scale = null, .disp = null } }, .size = null };
        }
    } else if (t1 == .NumberLiteral) {
        if (t2 == .Asteriks and t3.isReg()) {
            if (t4 == .PosNumLiteral or t4 == .NegNumLiteral) {
                if (t5 == .Plus and t6.isReg()) {
                    const disp = try dispFromNumToken(tokens[3], program);
                    const scale = try scaleFromNumToken(tokens[0], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t5 == .NotPresent) {
                    const disp = try dispFromNumToken(tokens[3], program);
                    const scale = try scaleFromNumToken(tokens[0], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                }
            } else if (t4 == .Plus and t5.isReg()) {
                if (t6 == .PosNumLiteral or t6 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[5], program);
                    const scale = try scaleFromNumToken(tokens[0], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t6 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[0], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t3), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t4 == .NotPresent) {
                const scale = try scaleFromNumToken(tokens[0], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t3), .scale = scale, .disp = null } }, .size = null };
            }
        } else if (t2 == .Plus and t3.isReg()) {
            if (t4 == .Asteriks and t5 == .NumberLiteral and t6 == .Plus and t7.isReg()) {
                const disp = try dispFromNumToken(tokens[0], program);
                const scale = try scaleFromNumToken(tokens[4], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t7), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
            } else if (t4 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[0], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t3), .index = null, .scale = null, .disp = disp } }, .size = null };
            }
        } else if (t2 == .PosNumLiteral and t3 == .Asteriks and t4.isReg()) {
            if (t5 == .Plus and t6.isReg()) {
                const disp = try dispFromNumToken(tokens[0], program);
                const scale = try scaleFromNumToken(tokens[1], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            } else if (t5 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[0], program);
                const scale = try scaleFromNumToken(tokens[1], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            }
        } else if (t2 == .NotPresent) {
            const disp = try dispFromNumToken(tokens[0], program);
            oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = null, .scale = null, .disp = disp } }, .size = null };
        }
    } else if (t1 == .PosNumLiteral or t1 == .NegNumLiteral) {
        if (t2 == .Plus) {
            if (t3.isReg()) {
                if (t4 == .Asteriks and t5 == .NumberLiteral and t6 == .Plus and t7.isReg()) {
                    const disp = try dispFromNumToken(tokens[0], program);
                    const scale = try scaleFromNumToken(tokens[4], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t7), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t4 == .NotPresent) {
                    const disp = try dispFromNumToken(tokens[0], program);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t3), .index = null, .scale = null, .disp = disp } }, .size = null };
                }
            }
        } else if (t2 == .PosNumLiteral and t3 == .Asteriks and t4.isReg()) {
            if (t5 == .Plus and t6.isReg()) {
                const disp = try dispFromNumToken(tokens[0], program);
                const scale = try scaleFromNumToken(tokens[1], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            } else if (t5 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[0], program);
                const scale = try scaleFromNumToken(tokens[1], program);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            }
        } else if (t2 == .NotPresent) {
            const disp = try dispFromNumToken(tokens[0], program);
            oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = null, .scale = null, .disp = disp } }, .size = null };
        }
    } else if (t1 == .Ident) {
        oper = MemOperand{ .mem = .{ .label = tokens[0].value }, .size = null };
    }

    const line = tokens[0].line;
    if (oper) |*operand| {
        try checkMemoryOperand(operand, program, line);
        return operand.*;
    } else {
        stdbuffers.printSourceError(program.file_name, "invalid operand", program.content, line);
        return ParserError.ParsingFailed;
    }
}

fn parseOperand(tokens: []lexer.Token, program: *Program) ParserError!Operand {
    var oper: Operand = undefined;
    const first = tokens[0];
    switch (tokens.len) {
        1 => {
            const token = first;
            if (token.type.isReg()) {
                oper = .{ .reg = Register.init(token.type) };
            } else if (token.type == .Ident) {
                oper = .{ .label = token.value };
            } else if (token.type == .NumberLiteral or token.type == .NegNumLiteral or token.type == .PosNumLiteral) {
                oper = .{ .imm = try immFromNumToken(token) };
            } else if (token.type == .StringLiteral) {
                if (token.value.len == 1) {
                    const value = token.value[0];
                    oper = .{ .imm = .{ .u = value } };
                } else {
                    stdbuffers.printSourceError(program.file_name, "string literal operand must be 1 character long", program.content, token.line);
                    return ParserError.ParsingFailed;
                }
            } else {
                stdbuffers.printSourceError(program.file_name, "expected register, number or character", program.content, token.line);
                return ParserError.ParsingFailed;
            }
        },
        else => {
            const second = tokens[1];
            const last = tokens[tokens.len - 1];
            if (first.type.isPointerSize() and tokens.len > 3) {
                if (second.type == .OpenBracket and last.type == .CloseBracket) {
                    var mem_operand = try parseMemoryOperand(tokens[2 .. tokens.len - 1], program);
                    const ptr_size: u8 = switch (first.type) {
                        .P8 => 1,
                        .P16 => 2,
                        .P32 => 4,
                        .P64 => 8,
                        else => unreachable,
                    };
                    mem_operand.size = ptr_size;
                    oper = .{ .mem = mem_operand };
                } else {
                    stdbuffers.printSourceError(program.file_name, "expected operand in [] brackets", program.content, second.line);
                    return ParserError.ParsingFailed;
                }
            } else if (first.type == .OpenBracket and last.type == .CloseBracket) {
                if (tokens.len > 2) {
                    const mem_operand = try parseMemoryOperand(tokens[1 .. tokens.len - 1], program);
                    oper = .{ .mem = mem_operand };
                } else {
                    stdbuffers.printSourceError(program.file_name, "expected operand in [] brackets", program.content, first.line);
                    return ParserError.ParsingFailed;
                }
            } else {
                stdbuffers.printSourceError(program.file_name, "unexpected symbols", program.content, first.line);
                return ParserError.ParsingFailed;
            }
        },
    }
    return oper;
}

var instr_count: usize = 0;

fn parseCodeInstruction(tokens: []lexer.Token, program: *Program) ParserError!void {
    var instruction: CodeInstruction = undefined;
    if (tokens[0].type == .Ident) {
        if (tokens.len > 1 and tokens[1].type == .Colon) {
            const label = tokens[0].value;

            const result = try program.symbols.getOrPut(label);
            if (result.found_existing) {
                stdbuffers.printSourceErrorFormatted(program.file_name, "label '{s}' already defined in this file", .{label}, program.content, tokens[0].line);
                return ParserError.ParsingFailed;
            } else {
                result.value_ptr.type = .Local;
                result.value_ptr.section = .Code;
            }

            instruction = .{ .label = .{ .name = label, .line = tokens[0].line } };
            try program.code_section.?.instr.append(program.allocator, instruction);
        } else {
            stdbuffers.printSourceError(program.file_name, "expected ':'", program.content, tokens[0].line);
            return ParserError.ParsingFailed;
        }
    } else if (tokens[0].type.isMnemonic()) {
        instruction = .{ .cpu = .{ .mnem = tokens[0].type, .operands = .empty, .line = tokens[0].line } };
        errdefer instruction.cpu.operands.deinit(program.allocator);
        var i: usize = 1;
        var operand_number: usize = 1;
        var oper_tokens: []lexer.Token = tokens[1..1];
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .Comma or i == tokens.len - 1) {
                if (i == tokens.len - 1) {
                    oper_tokens.len += 1;
                }
                if (oper_tokens.len > 0) {
                    const operand = try parseOperand(oper_tokens, program);
                    if (operand_number <= MAX_OPERAND_COUNT) {
                        try instruction.cpu.operands.append(program.allocator, operand);
                        operand_number += 1;
                        oper_tokens = tokens[i + 1 .. i + 1];
                    } else {
                        stdbuffers.printSourceError(program.file_name, "too many operands for instruction", program.content, token.line);
                        return ParserError.ParsingFailed;
                    }
                } else {
                    stdbuffers.printSourceError(program.file_name, "expected instruction operand", program.content, token.line);
                    return ParserError.ParsingFailed;
                }
            } else {
                oper_tokens.len += 1;
            }
        }
        try program.code_section.?.instr.append(program.allocator, instruction);
    } else {
        stdbuffers.printSourceError(program.file_name, "unexpected symbols on line", program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
}

fn parseCodeSection(tokens: []lexer.Token, program: *Program) ParserError!usize {
    program.code_section = CodeSection.new();
    const first = tokens[0];
    program.code_section.?.flags = try parseSectionFlags(first, program);
    if (tokens[1].type == .NewLine) {
        var current_instruction: []lexer.Token = tokens[2..2];
        var i: usize = 2;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
                try parseCodeInstruction(current_instruction, program);
                instr_count += 1;
                current_instruction.ptr = tokens[i + 1 .. i + 1].ptr;
                current_instruction.len = 0;
            } else if (token.type == .Section) {
                return i;
            } else {
                current_instruction.len += 1;
            }
        }
    } else {
        stdbuffers.printSourceError(program.file_name, "unexpected symbols on line", program.content, tokens[1].line);
        return ParserError.ParsingFailed;
    }
    return tokens.len;
}

fn parseExportSection(tokens: []lexer.Token, program: *Program) ParserError!usize {
    if (tokens[0].type != .NewLine) {
        stdbuffers.printSourceError(program.file_name, "unexpected symbols on line", program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
    var expect_symbol = true;
    for (tokens[1..], 1..) |token, i| {
        if (expect_symbol) {
            if (token.type == .Ident) {
                const result = try program.exports.getOrPut(token.value);
                if (result.found_existing) {
                    stdbuffers.printSourceErrorFormatted(program.file_name, "label '{s}' already defined in this file", .{token.value}, program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                expect_symbol = false;
            } else if (token.type == .Section) {
                return i;
            } else {
                stdbuffers.printSourceError(program.file_name, "expected label name", program.content, token.line);
                return ParserError.ParsingFailed;
            }
        } else {
            if (token.type == .Comma or token.type == .NewLine) {
                expect_symbol = true;
            } else if (token.type == .Section) {
                return i;
            } else {
                stdbuffers.printSourceError(program.file_name, "expected ','", program.content, token.line);
                return ParserError.ParsingFailed;
            }
        }
    }
    return tokens.len;
}

fn parseImportSection(tokens: []lexer.Token, program: *Program) !usize {
    if (tokens[0].type != .NewLine) {
        stdbuffers.printSourceError(program.file_name, "unexpected symbols on line", program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
    var expect_symbol = true;
    for (tokens[1..], 1..) |token, i| {
        if (expect_symbol) {
            if (token.type == .Ident) {
                const result = try program.symbols.getOrPut(token.value);
                if (result.found_existing) {
                    stdbuffers.printSourceErrorFormatted(program.file_name, "label '{s}' already defined in this file", .{token.value}, program.content, token.line);
                    return ParserError.ParsingFailed;
                } else {
                    result.value_ptr.section = .Undef;
                    result.value_ptr.type = .Import;
                    result.value_ptr.offset = 0;
                }
                expect_symbol = false;
            } else if (token.type == .Section) {
                return i;
            } else {
                stdbuffers.printSourceError(program.file_name, "expected label name", program.content, token.line);
                return ParserError.ParsingFailed;
            }
        } else {
            if (token.type == .Comma or token.type == .NewLine) {
                expect_symbol = true;
            } else if (token.type == .Section) {
                return i;
            } else {
                stdbuffers.printSourceError(program.file_name, "expected ','", program.content, token.line);
                return ParserError.ParsingFailed;
            }
        }
    }
    return tokens.len;
}

pub fn parseTokens(program: *Program) ParserError!void {
    var i: usize = 0;
    instr_count = 0;
    var skip_entry = false;
    var datsec_defined = false;
    var codsec_defined = false;
    while (i < program.tokens.items.len) : (i += 1) {
        const token = program.tokens.items[i];

        if (token.type == .Entry and !skip_entry) {
            if (program.entry == null) {
                try parseEntry(program.tokens.items[i + 1 ..], program);
                i += 2;
            } else {
                stdbuffers.printSourceError(program.file_name, "entry label already defined in this file", program.content, token.line);
                return ParserError.ParsingFailed;
            }
        } else if (token.type == .Section) {
            skip_entry = true;
            if (program.tokens.items[i + 1].type == .Data) {
                if (datsec_defined) {
                    stdbuffers.printSourceError(program.file_name, "data section already present in this file", program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                const len = try parseDataSection(program.tokens.items[i + 2 ..], program);
                i += (len + 1);
                datsec_defined = true;
            } else if (program.tokens.items[i + 1].type == .Code) {
                if (codsec_defined) {
                    stdbuffers.printSourceError(program.file_name, "code section already present in this file", program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                const len = try parseCodeSection(program.tokens.items[i + 2 ..], program);
                i += (len + 1);
                codsec_defined = true;
            } else if (program.tokens.items[i + 1].type == .Export) {
                const len = try parseExportSection(program.tokens.items[i + 2 ..], program);
                i += (len + 1);
            } else if (program.tokens.items[i + 1].type == .Import) {
                const len = try parseImportSection(program.tokens.items[i + 2 ..], program);
                i += (len + 1);
            } else {
                stdbuffers.printSourceError(program.file_name, "unknown section type", program.content, token.line);
                return ParserError.ParsingFailed;
            }
        } else {
            stdbuffers.printSourceError(program.file_name, "unexpected symbols on line", program.content, token.line);
            return ParserError.ParsingFailed;
        }
    }
}

pub fn printCPUInstruction(instr: CpuInstruction) void {
    std.debug.print(" {t} ", .{instr.mnem});
    for (instr.operands.items, 0..) |oper, i| {
        switch (oper) {
            .imm => {
                switch (oper.imm) {
                    .i => {
                        std.debug.print("{d}", .{oper.imm.i});
                    },
                    .u => {
                        std.debug.print("{d}", .{oper.imm.u});
                    },
                }
            },
            .label => {
                std.debug.print("{s}", .{oper.label});
            },
            .reg => {
                std.debug.print("{t}", .{oper.reg.name});
            },
            .mem => {
                switch (oper.mem.mem) {
                    .label => {
                        if (oper.mem.size != null) {
                            std.debug.print("p{d} ", .{oper.mem.size.?});
                        }
                        std.debug.print("[{s}]", .{oper.mem.mem.label});
                    },
                    .addr => {
                        const base: ?lexer.TokenType = if (oper.mem.mem.addr.base) |bs| bs.name else null;
                        const index: ?lexer.TokenType = if (oper.mem.mem.addr.index) |in| in.name else null;
                        const scale: ?u8 = if (oper.mem.mem.addr.scale) |sc| sc.num else null;
                        const disp: ?i32 = if (oper.mem.mem.addr.disp) |ds| ds.num else null;

                        if (oper.mem.size != null) {
                            std.debug.print("p{d} ", .{oper.mem.size.?});
                        }
                        std.debug.print("[", .{});
                        if (base != null) {
                            std.debug.print("<{t}>", .{base.?});
                        }
                        if (index != null) {
                            std.debug.print("<{t}>", .{index.?});
                        }
                        if (scale != null) {
                            std.debug.print("*({d})", .{scale.?});
                        }
                        if (disp != null) {
                            std.debug.print("+|{d}|", .{disp.?});
                        }
                        std.debug.print("]", .{});
                    },
                }
            },
        }
        if (i < instr.operands.items.len - 1) {
            std.debug.print(", ", .{});
        }
    }
}

pub fn printAST(program: *Program) void {
    if (program.entry) |entry| {
        std.debug.print("entry: {s}\n", .{entry});
    } else {
        std.debug.print("entry: null\n", .{});
    }

    if (program.data_section) |*data_section| {
        // data section
        std.debug.print("section data\n", .{});
        std.debug.print("flags: r - {}, w - {}, e - {}\n", .{ data_section.flags.read, data_section.flags.write, data_section.flags.exec });
        for (data_section.instr.items) |instr| {
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
                                        std.debug.print("rep({d}, {d})", .{ item.repeat.count.u, item.repeat.item.num.i });
                                    },
                                    .u => {
                                        std.debug.print("rep({d}, {d})", .{ item.repeat.count.u, item.repeat.item.num.u });
                                    },
                                }
                            },
                            .str => {
                                std.debug.print("rep({d}, \"{s}\")", .{ item.repeat.count.u, item.repeat.item.str });
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
    if (program.code_section) |*code_section| {
        // code section
        std.debug.print("section code\n", .{});
        std.debug.print("flags: r - {}, w - {}, e - {}\n", .{ code_section.flags.read, code_section.flags.write, code_section.flags.exec });
        for (code_section.instr.items) |instr| {
            switch (instr) {
                .cpu => {
                    printCPUInstruction(instr.cpu);
                },
                .label => {
                    std.debug.print("label {s}:", .{instr.label});
                },
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
}

pub fn printSymbolTable(program: *Program) void {
    std.debug.print(" Symbols\n", .{});
    var iter = program.symbols.iterator();
    while (iter.next()) |sym| {
        std.debug.print("{s} {s} {s}: {d}\n", .{
            switch (sym.value_ptr.section) {
                .Code => " c",
                .Data => "d ",
                .Undef => "--",
            },
            switch (sym.value_ptr.type) {
                .Local => "LOC",
                .Export => "EXP",
                .Import => "IMP",
            },
            sym.key_ptr.*,
            sym.value_ptr.offset,
        });
    }
    std.debug.print("\n", .{});
}
