const std = @import("std");
const lexer = @import("lexer");
const object = @import("object");

const MAX_OPERAND_COUNT = 3;

pub const Register = struct {
    name: lexer.TokenType,
    size: u8,
    // Caller must be sure that reg param is actually register name
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

    pub fn invert(self: *Immediate) !void {
        switch (self.*) {
            .u => {
                const unsigned = self.u;
                if (unsigned < std.math.maxInt(i64)) {
                    const signed: i64 = @intCast(unsigned);
                    self.* = .{ .i = -signed };
                } else {
                    // error - integer doesn't fit in 64 bit
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
};

pub const CodeInstruction = union(enum) {
    label: []u8,
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

pub const SymBinding = enum {
    Local,
    Global,
};

pub const Symbol = struct {
    offset: u64,
    binding: SymBinding,
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
    symbols: std.StringHashMap(Symbol),
    buffer: std.ArrayList(u8),

    pub fn new(allocator: std.mem.Allocator) DataSection {
        return DataSection{
            .flags = SectionFlags.empty(),
            .instr = .empty,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .buffer = .empty,
        };
    }
};

pub const CodeSection = struct {
    flags: SectionFlags,
    instr: std.ArrayList(CodeInstruction),
    symbols: std.StringHashMap(Symbol),
    relocations: std.ArrayList(Relocation),
    buffer: std.ArrayList(u8),

    pub fn new(allocator: std.mem.Allocator) CodeSection {
        return CodeSection{
            .flags = SectionFlags.empty(),
            .instr = .empty,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .buffer = .empty,
            .relocations = .empty,
        };
    }
};

const ParserError = error{
    InvalidEntryName,
    WrongFlag,
    IncompleteDataInstr,
    LabelAlreadyDefined,

    UnexpectedSymbols,
    UnexpectedComma,

    ExpectedFlag,
    ExpectedNumOrString,
    ExpectedNonNegNum,
    ExpectedOpenedParenth,
    ExpectedClosedParenth,
    ExpectedComma,
    ExpectedSizeDirective,
    ExpectedLabelName,
    ExpectedColon,

    InvalidScale,
    InvalidDispSize,
    InvalidIndexSize,
    InvalidBaseSize,
    InvalidOperand,
    InvalidStrLitLen,

    TooManyOperands,
    DispIsZero,

    InvalidDataSize,
    RepeatCountTooLarge,
};

fn parseEntry(tokens: []lexer.Token, program: *object.Program) !void {
    const next = tokens[0];
    if (next.type == .Ident) {
        program.entry = next.value.?;
    } else {
        return ParserError.InvalidEntryName;
    }
    if (tokens[1].type != .NewLine) {
        return ParserError.UnexpectedSymbols;
    }
}

fn parseSectionFlags(token: lexer.Token) !SectionFlags {
    var flags = SectionFlags.empty();
    if (token.type == .Ident and token.value.?.len <= 3) {
        for (token.value.?) |char| {
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
                    return ParserError.WrongFlag;
                },
            }
        }
    } else {
        return ParserError.ExpectedFlag;
    }
    return flags;
}

fn immFromNumToken(token: lexer.Token) !Immediate {
    switch (token.type) {
        .NumberLiteral, .PosNumLiteral => {
            const value = try std.fmt.parseInt(u64, token.value.?, 10);
            const imm = Immediate{ .u = value };
            return imm;
        },
        .NegNumLiteral => {
            const value = try std.fmt.parseInt(u64, token.value.?, 10);
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
            } else if (imm.i >= std.math.minInt(i64) and imm.i <= std.math.maxInt(i64)) {
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
            } else if (imm.u <= std.math.maxInt(u64)) {
                return 8;
            }
        },
    }
    return 8; // but actually must be unreachable
}

fn dispFromNumToken(token: lexer.Token) !Displacement {
    const int = try std.fmt.parseInt(i64, token.value.?, 10);
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
            return ParserError.InvalidDispSize;
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
    } else if (disp.num >= std.math.minInt(i32) and disp.num <= std.math.maxInt(i32)) {
        return 4;
    } else {
        return 8; // should be unreachable
    }
}

fn scaleFromNumToken(token: lexer.Token) !Scale {
    const int = try std.fmt.parseInt(u8, token.value.?, 10);
    switch (int) {
        1, 2, 4, 8 => {
            return Scale{ .num = int };
        },
        else => {
            return ParserError.InvalidScale;
        },
    }
}

fn parseRepeat(tokens: []lexer.Token, data_size: u8) !DataInitialization {
    var data_init: DataInitialization = undefined;
    if (tokens[0].type == .OpenParenthes) {
        switch (tokens[1].type) {
            .NumberLiteral, .PosNumLiteral => {
                const count = try immFromNumToken(tokens[1]);
                const count_value = count.u;
                if (count_value * data_size > 16378) {
                    return ParserError.RepeatCountTooLarge;
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
                                        return ParserError.InvalidDataSize;
                                    }
                                },
                                .StringLiteral => {
                                    if (data_size == 1) {
                                        data_init = .{ .repeat = .{ .count = count, .item = .{ .str = tokens[3].value.? } } };
                                    } else {
                                        return ParserError.InvalidDataSize;
                                    }
                                },
                                else => {
                                    return ParserError.ExpectedNumOrString;
                                },
                            }
                            if (tokens[4].type == .CloseParenthes) {
                                return data_init;
                            } else {
                                return ParserError.ExpectedClosedParenth;
                            }
                        } else {
                            return ParserError.ExpectedComma;
                        }
                    },
                    .i => unreachable,
                }
            },
            else => {
                return ParserError.ExpectedNonNegNum;
            },
        }
    } else {
        return ParserError.ExpectedOpenedParenth;
    }
}

fn parseDataInstruction(tokens: []lexer.Token, program: *object.Program) !void {
    var instruction: DataInstruction = undefined;
    if (tokens.len < 4) {
        return ParserError.IncompleteDataInstr;
    }
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
                instruction.label = tokens[0].value.?;
                instruction.size = data_size;
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
                                return ParserError.ExpectedComma;
                            }
                            if (data_size == 1) {
                                const data_init: DataInitialization = .{ .str = token.value.? };
                                try instruction.data.append(program.allocator, data_init);
                            } else {
                                return ParserError.InvalidDataSize;
                            }
                        },
                        .NumberLiteral, .NegNumLiteral, .PosNumLiteral => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                return ParserError.ExpectedComma;
                            }
                            const num = try immFromNumToken(token);
                            const num_size = immMinSize(num);
                            if (num_size <= data_size) {
                                const data_init: DataInitialization = .{ .num = num };
                                try instruction.data.append(program.allocator, data_init);
                            } else {
                                return ParserError.InvalidDataSize;
                            }
                        },
                        .Repeat => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                return ParserError.ExpectedComma;
                            }
                            const data_init = try parseRepeat(tokens[i + 1 ..], data_size);
                            try instruction.data.append(program.allocator, data_init);
                            i += 5;
                        },
                        .Comma => {
                            if (!expect_value) {
                                expect_value = true;
                            } else {
                                return ParserError.UnexpectedComma;
                            }
                        },
                        else => {
                            return ParserError.UnexpectedSymbols;
                        },
                    }
                    i += 1;
                }
                // check if label is not in code section
                if (program.code_section) |*code_section| {
                    const result = code_section.symbols.get(instruction.label);
                    if (result != null) {
                        return ParserError.LabelAlreadyDefined;
                    }
                }
                // try to add to data symbols table
                const result = try program.data_section.?.symbols.getOrPut(instruction.label);
                if (result.found_existing) {
                    return ParserError.LabelAlreadyDefined;
                }
                try program.data_section.?.instr.append(program.allocator, instruction);
            } else {
                return ParserError.ExpectedSizeDirective;
            }
        } else {
            return ParserError.ExpectedColon;
        }
    } else {
        return ParserError.ExpectedLabelName;
    }
}

fn parseDataSection(tokens: []lexer.Token, program: *object.Program) !usize {
    program.data_section = DataSection.new(program.allocator);
    const first = tokens[0];
    program.data_section.?.flags = try parseSectionFlags(first);
    if (tokens[1].type == .NewLine) {
        var current_instruction: []lexer.Token = tokens[2..2];
        var i: usize = 2;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
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
        return ParserError.UnexpectedSymbols;
    }
    return tokens.len;
}

fn checkMemoryOperand(oper: *MemOperand) !void {
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
                            return ParserError.InvalidIndexSize;
                        }
                    }
                } else {
                    return ParserError.InvalidBaseSize;
                }
            }
        },
        .label => {},
    }
}

fn parseMemoryOperand(tokens: []lexer.Token) !MemOperand {
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
                    const disp = try dispFromNumToken(tokens[3]);
                    const scale = try scaleFromNumToken(tokens[2]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t1), .scale = scale, .disp = disp } }, .size = null };
                } else if (t5 == .NotPresent) {
                    const disp = try dispFromNumToken(tokens[3]);
                    const scale = try scaleFromNumToken(tokens[2]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t1), .scale = scale, .disp = disp } }, .size = null };
                }
            } else if (t4 == .Plus and t5.isReg()) {
                if (t6 == .PosNumLiteral or t6 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[5]);
                    const scale = try scaleFromNumToken(tokens[2]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t1), .scale = scale, .disp = disp } }, .size = null };
                } else if (t6 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[2]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t1), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t4 == .NotPresent) {
                const scale = try scaleFromNumToken(tokens[2]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t1), .scale = scale, .disp = null } }, .size = null };
            }
        } else if (t2 == .Plus and t3.isReg()) {
            if (t4 == .Asteriks and t5 == .NumberLiteral) {
                if (t6 == .PosNumLiteral or t6 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[5]);
                    const scale = try scaleFromNumToken(tokens[4]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t6 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[4]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t4 == .PosNumLiteral or t4 == .NegNumLiteral) {
                const disp = try dispFromNumToken(tokens[3]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = null, .disp = disp } }, .size = null };
            } else if (t4 == .NotPresent) {
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t3), .scale = null, .disp = null } }, .size = null };
            }
        } else if (t2 == .PosNumLiteral) {
            if (t3 == .Asteriks and t4.isReg()) {
                if (t5 == .PosNumLiteral or t5 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[4]);
                    const scale = try scaleFromNumToken(tokens[1]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
                } else if (t5 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[1]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = Register.init(t4), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t3 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[1]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = null, .scale = null, .disp = disp } }, .size = null };
            }
        } else if (t2 == .NegNumLiteral) {
            const disp = try dispFromNumToken(tokens[1]);
            oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = null, .scale = null, .disp = disp } }, .size = null };
        } else if (t2 == .NotPresent) {
            oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t1), .index = null, .scale = null, .disp = null } }, .size = null };
        }
    } else if (t1 == .NumberLiteral) {
        if (t2 == .Asteriks and t3.isReg()) {
            if (t4 == .PosNumLiteral or t4 == .NegNumLiteral) {
                if (t5 == .Plus and t6.isReg()) {
                    const disp = try dispFromNumToken(tokens[3]);
                    const scale = try scaleFromNumToken(tokens[0]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t5 == .NotPresent) {
                    const disp = try dispFromNumToken(tokens[3]);
                    const scale = try scaleFromNumToken(tokens[0]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                }
            } else if (t4 == .Plus and t5.isReg()) {
                if (t6 == .PosNumLiteral or t6 == .NegNumLiteral) {
                    const disp = try dispFromNumToken(tokens[5]);
                    const scale = try scaleFromNumToken(tokens[0]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t6 == .NotPresent) {
                    const scale = try scaleFromNumToken(tokens[0]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t5), .index = Register.init(t3), .scale = scale, .disp = null } }, .size = null };
                }
            } else if (t4 == .NotPresent) {
                const scale = try scaleFromNumToken(tokens[0]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t3), .scale = scale, .disp = null } }, .size = null };
            }
        } else if (t2 == .Plus and t3.isReg()) {
            if (t4 == .Asteriks and t5 == .NumberLiteral and t6 == .Plus and t7.isReg()) {
                const disp = try dispFromNumToken(tokens[0]);
                const scale = try scaleFromNumToken(tokens[4]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t7), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
            } else if (t4 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[0]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t3), .index = null, .scale = null, .disp = disp } }, .size = null };
            }
        } else if (t2 == .PosNumLiteral and t3 == .Asteriks and t4.isReg()) {
            if (t5 == .Plus and t6.isReg()) {
                const disp = try dispFromNumToken(tokens[0]);
                const scale = try scaleFromNumToken(tokens[1]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            } else if (t5 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[0]);
                const scale = try scaleFromNumToken(tokens[1]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            }
        } else if (t2 == .NotPresent) {
            const disp = try dispFromNumToken(tokens[0]);
            oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = null, .scale = null, .disp = disp } }, .size = null };
        }
    } else if (t1 == .PosNumLiteral or t1 == .NegNumLiteral) {
        if (t2 == .Plus) {
            if (t3.isReg()) {
                if (t4 == .Asteriks and t5 == .NumberLiteral and t6 == .Plus and t7.isReg()) {
                    const disp = try dispFromNumToken(tokens[0]);
                    const scale = try scaleFromNumToken(tokens[4]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t7), .index = Register.init(t3), .scale = scale, .disp = disp } }, .size = null };
                } else if (t4 == .NotPresent) {
                    const disp = try dispFromNumToken(tokens[0]);
                    oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t3), .index = null, .scale = null, .disp = disp } }, .size = null };
                }
            }
        } else if (t2 == .PosNumLiteral and t3 == .Asteriks and t4.isReg()) {
            if (t5 == .Plus and t6.isReg()) {
                const disp = try dispFromNumToken(tokens[0]);
                const scale = try scaleFromNumToken(tokens[1]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = Register.init(t6), .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            } else if (t5 == .NotPresent) {
                const disp = try dispFromNumToken(tokens[0]);
                const scale = try scaleFromNumToken(tokens[1]);
                oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = Register.init(t4), .scale = scale, .disp = disp } }, .size = null };
            }
        } else if (t2 == .NotPresent) {
            const disp = try dispFromNumToken(tokens[0]);
            oper = MemOperand{ .mem = .{ .addr = .{ .base = null, .index = null, .scale = null, .disp = disp } }, .size = null };
        }
    } else if (t1 == .Ident) {
        oper = MemOperand{ .mem = .{ .label = tokens[0].value.? }, .size = null };
    }

    if (oper) |*operand| {
        try checkMemoryOperand(operand);
        return operand.*;
    } else {
        return ParserError.InvalidOperand;
    }
}

fn parseOperand(tokens: []lexer.Token) !Operand {
    var oper: Operand = undefined;
    const first = tokens[0];
    switch (tokens.len) {
        1 => {
            const token = first;
            if (token.type.isReg()) {
                oper = .{ .reg = Register.init(token.type) };
            } else if (token.type == .Ident) {
                oper = .{ .label = token.value.? };
            } else if (token.type == .NumberLiteral or token.type == .NegNumLiteral or token.type == .PosNumLiteral) {
                oper = .{ .imm = try immFromNumToken(token) };
            } else if (token.type == .StringLiteral) {
                if (token.value.?.len == 1) {
                    const value = token.value.?[0];
                    oper = .{ .imm = .{ .u = value } };
                } else {
                    return ParserError.InvalidStrLitLen;
                }
            } else {
                return ParserError.InvalidOperand;
            }
        },
        else => {
            const second = tokens[1];
            const last = tokens[tokens.len - 1];
            if (first.type.isPointerSize() and tokens.len > 3) {
                if (second.type == .OpenBracket and last.type == .CloseBracket) {
                    var mem_operand = try parseMemoryOperand(tokens[2 .. tokens.len - 1]);
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
                    return ParserError.InvalidOperand;
                }
            } else if (first.type == .OpenBracket and last.type == .CloseBracket) {
                if (tokens.len > 2) {
                    const mem_operand = try parseMemoryOperand(tokens[1 .. tokens.len - 1]);
                    oper = .{ .mem = mem_operand };
                } else {
                    return ParserError.InvalidOperand;
                }
            } else {
                return ParserError.InvalidOperand;
            }
        },
    }
    return oper;
}

var instr_count: usize = 0;

fn parseCodeInstruction(tokens: []lexer.Token, program: *object.Program) !void {
    var instruction: CodeInstruction = undefined;
    if (tokens[0].type == .Ident) {
        if (tokens[1].type == .Colon) {
            const label = tokens[0].value.?;
            // check if label is not in data section
            if (program.data_section) |*data_section| {
                const result = data_section.symbols.get(label);
                if (result != null) {
                    return ParserError.LabelAlreadyDefined;
                }
            }
            // try to add to code symbols table
            const result = try program.code_section.?.symbols.getOrPut(label);
            if (result.found_existing) {
                return ParserError.LabelAlreadyDefined;
            }

            instruction = .{ .label = label };
            try program.code_section.?.instr.append(program.allocator, instruction);
        } else {
            return ParserError.ExpectedColon;
        }
    } else if (tokens[0].type.isMnemonic()) {
        instruction = .{ .cpu = .{ .mnem = tokens[0].type, .operands = .empty } };
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
                    const operand = try parseOperand(oper_tokens);
                    if (operand_number <= MAX_OPERAND_COUNT) {
                        try instruction.cpu.operands.append(program.allocator, operand);
                        operand_number += 1;
                        oper_tokens = tokens[i + 1 .. i + 1];
                    } else {
                        return ParserError.TooManyOperands;
                    }
                } else {
                    return ParserError.InvalidOperand;
                }
            } else {
                oper_tokens.len += 1;
            }
        }
        try program.code_section.?.instr.append(program.allocator, instruction);
    } else {
        return ParserError.UnexpectedSymbols;
    }
}

fn parseCodeSection(tokens: []lexer.Token, program: *object.Program) !usize {
    program.code_section = CodeSection.new(program.allocator);
    const first = tokens[0];
    program.code_section.?.flags = try parseSectionFlags(first);
    if (tokens[1].type == .NewLine) {
        var current_instruction: []lexer.Token = tokens[2..2];
        var i: usize = 2;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
                parseCodeInstruction(current_instruction, program) catch |err| {
                    std.debug.print("Instruction {d} (", .{instr_count});
                    for (current_instruction) |tok| {
                        std.debug.print("{t} ", .{tok.type});
                    }
                    std.debug.print(") failed parsing\n", .{});
                    return err;
                };
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
        return ParserError.UnexpectedSymbols;
    }
    return tokens.len;
}

pub fn parseTokensToAST(program: *object.Program) !void {
    var i: usize = 0;
    instr_count = 0;
    while (i < program.tokens.items.len) : (i += 1) {
        const token = program.tokens.items[i];

        if (token.type == .Entry) {
            if (program.entry == null) {
                try parseEntry(program.tokens.items[i + 1 ..], program);
                i += 2;
            } else {
                // error - second 'entry' keyword
            }
        } else if (token.type == .Section) {
            if (program.tokens.items[i + 1].type == .Data) {
                const len = try parseDataSection(program.tokens.items[i + 2 ..], program);
                i += (len + 1);
            } else if (program.tokens.items[i + 1].type == .Code) {
                const len = try parseCodeSection(program.tokens.items[i + 2 ..], program);
                i += (len + 1);
            } else {
                // error - unknown section type
            }
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

pub fn printAST(program: *object.Program) void {
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

pub fn printSymbolTables(program: *object.Program) void {
    std.debug.print(" Symbols\n", .{});
    if (program.data_section) |*data_section| {
        // data section
        std.debug.print("data section: \n", .{});
        var iter = data_section.symbols.iterator();
        while (iter.next()) |entry| {
            std.debug.print(" {s}: {d} \n", .{ entry.key_ptr.*, entry.value_ptr.offset });
        }
        std.debug.print("\n", .{});
    }
    if (program.code_section) |*code_section| {
        // code section
        std.debug.print("code section: \n", .{});
        var iter = code_section.symbols.iterator();
        while (iter.next()) |entry| {
            std.debug.print(" {s}: {d} \n", .{ entry.key_ptr.*, entry.value_ptr.offset });
        }
        std.debug.print("\n", .{});
    }
}
