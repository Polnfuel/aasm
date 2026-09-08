const std = @import("std");
const utils = @import("utils");

const Lexer = @import("Lexer");
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;

const Program = @import("Program");
const MemSize = Program.MemSize;
const Label = Program.Label;
const Register = Program.Register;
const Displacement = Program.Displacement;
const Immediate = Program.Immediate;
const MemOperand = Program.MemOperand;
const CodeOperand = Program.CodeOperand;
const CodeInstruction = Program.CodeInstruction;

const Parser = @This();

const BlockType = enum {
    data,
    bss,
    code,
};

const RepeatOperand = struct {
    count: u32,
    num: Immediate,
};

program: *Program,
cur_func: Label,

pub const ParserError = error{ParsingFailed} || std.mem.Allocator.Error;

pub fn init(program: *Program) Parser {
    return Parser{
        .program = program,
        .cur_func = 0,
    };
}

fn appendImmediateBytes(self: *const Parser, imm: Immediate, bytes: u8) std.mem.Allocator.Error!void {
    const array = std.mem.toBytes(imm.bits);
    try self.program.data_buffer.appendSlice(utils.alloc, array[0..bytes]);
}

/// token must be .NumberLiteral, .HexNumLiteral or .BinNumLiteral
fn immFromToken(self: *const Parser, token: Token) ParserError!Immediate {
    const label = utils.stringValue(token.val_ind);
    const value = std.fmt.parseInt(u64, label, 0) catch {
        utils.printSrcLineColErrorFmt("value {s} doesn't fit in 64 bit", .{label}, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    };
    const imm = Immediate{ .bits = value, .sign = .u };
    return imm;
}

/// Adds 0 to consumed for "45", 1 for "- 45" and 2 for "- - 45"
fn parseNumber(self: *const Parser, tokens: []Token, consumed: *usize) ParserError!Immediate {
    var plus = true;
    for (tokens) |token| {
        if (token.type == .Plus) {
            plus = plus;
        } else if (token.type == .Minus) {
            plus = !plus;
        } else if (token.type == .NumberLiteral or token.type == .HexNumLiteral or token.type == .BinNumLiteral) {
            var imm = try self.immFromToken(token);
            if (!plus) {
                imm.negate() catch {
                    utils.printSrcLineColErrorFmt("value -{s} doesn't fit in 64 bit", .{utils.stringValue(token.val_ind)}, self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                };
            }
            return imm;
        } else {
            utils.printSrcLineColError("expected number", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        consumed.* += 1;
    } else {
        utils.printSrcLineColError("expected number", self.program, tokens[0].line, tokens[tokens.len - 1].col);
        return ParserError.ParsingFailed;
    }
}

fn parseRegister(self: *const Parser, tokens: []Token) ParserError!Register {
    var plus = true;
    for (tokens) |token| {
        if (token.type == .Plus) {
            plus = plus;
        } else if (token.type == .Minus) {
            plus = !plus;
        } else if (token.type.isReg()) {
            if (!plus) {
                utils.printSrcLineColError("register cannot follow minus sign", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            return Register.init(token.type);
        } else {
            utils.printSrcLineColError("expected register", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
    }
    unreachable;
}

fn parseLabel(self: *const Parser, tokens: []Token) ParserError!Label {
    var plus = true;
    for (tokens) |token| {
        if (token.type == .Plus) {
            plus = plus;
        } else if (token.type == .Minus) {
            plus = !plus;
        } else if (token.type == .Ident or token.type == .DotIdent) {
            if (!plus) {
                utils.printSrcLineColError("label cannot follow minus sign", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            return token.val_ind;
        } else {
            utils.printSrcLineColError("expected label", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
    }
    unreachable;
}

fn dispFromImm(self: *const Parser, imm: Immediate, line: u16, col: u16) ParserError!Displacement {
    var disp: Displacement = undefined;
    switch (imm.sign) {
        .u => {
            if (imm.bits <= std.math.maxInt(i32) + 1) {
                disp = @intCast(imm.bits);
            } else {
                utils.printSrcLineColError("too large displacement in operand", self.program, line, col);
                return ParserError.ParsingFailed;
            }
        },
        .i => {
            if (imm.fitsInBytes() <= 4) {
                disp = @truncate(imm.negative());
            } else {
                utils.printSrcLineColError("too large displacement in operand", self.program, line, col);
                return ParserError.ParsingFailed;
            }
        },
    }
    return disp;
}

fn parseRepeat(self: *const Parser, tokens: []Token, data_size: u8, consumed: *usize, max_size: usize) ParserError!RepeatOperand {
    var repeat_oper: RepeatOperand = undefined;
    const line = tokens[0].line;
    if (tokens[0].type != .OpenParenthes) {
        utils.printSrcLineColError("expected (", self.program, line, tokens[0].col);
        return ParserError.ParsingFailed;
    }
    var i: usize = 0;
    const count_token = tokens[1];
    switch (count_token.type) {
        .NumberLiteral, .HexNumLiteral, .BinNumLiteral, .Minus, .Plus => {
            var parsed: usize = 0;
            const count = try self.parseNumber(tokens[1..], &parsed);
            i += parsed;
            const count_value: u32 = switch (count.sign) {
                .u => @truncate(count.bits),
                .i => {
                    utils.printSrcLineColError("expected non-negative number as repeat count", self.program, line, tokens[i + 1].col);
                    return ParserError.ParsingFailed;
                },
            };
            if (count_value * data_size > max_size) {
                utils.printSrcLineColError("repeat count is too large for this data size", self.program, line, tokens[i + 1].col);
                return ParserError.ParsingFailed;
            }
            if (tokens[i + 2].type != .Comma) {
                utils.printSrcLineColError("expected ,", self.program, line, tokens[i + 2].col);
                return ParserError.ParsingFailed;
            }
            const value_token = tokens[i + 3];
            switch (value_token.type) {
                .NumberLiteral, .HexNumLiteral, .BinNumLiteral, .Minus, .Plus => {
                    parsed = 0;
                    const value = try self.parseNumber(tokens[i + 3 ..], &parsed);
                    i += parsed;
                    const value_size = value.fitsInBytes();
                    if (value_size <= data_size) {
                        repeat_oper = .{ .count = count_value, .num = value };
                    } else {
                        utils.printSrcLineColError("value doesn't fit in specified data size", self.program, line, value_token.col);
                        return ParserError.ParsingFailed;
                    }
                },
                .StringLiteral => {
                    if (utils.stringValue(value_token.val_ind).len == 1) {
                        if (data_size != 1) {
                            utils.printSrcLineColError("repeat string supported only by d8 directive", self.program, line, value_token.col);
                            return ParserError.ParsingFailed;
                        }
                        repeat_oper = .{ .count = count_value, .num = .{ .bits = utils.stringValue(value_token.val_ind)[0], .sign = .u } };
                    } else {
                        utils.printSrcLineColError("repeat supported only for 1-byte long strings", self.program, line, value_token.col);
                        return ParserError.ParsingFailed;
                    }
                },
                else => {
                    utils.printSrcLineColError("expected number or string literal", self.program, line, value_token.col);
                    return ParserError.ParsingFailed;
                },
            }
            if (tokens[i + 4].type != .CloseParenthes) {
                utils.printSrcLineColError("expected )", self.program, line, tokens[i + 4].col);
                return ParserError.ParsingFailed;
            }
            consumed.* = i + 5;
            return repeat_oper;
        },
        else => {
            utils.printSrcLineColError("expected non-negative number as repeat count", self.program, line, count_token.col);
            return ParserError.ParsingFailed;
        },
    }
}

fn parseEntry(self: *const Parser, tokens: []Token) ParserError!void {
    const next = tokens[0];
    if (next.type == .Ident) {
        self.program.entry = next.val_ind;
    } else {
        utils.printSrcLineColError("expected label name", self.program, next.line, next.col);
        return ParserError.ParsingFailed;
    }
    if (tokens[1].type != .NewLine) {
        utils.printSrcLineColError("expected end of line", self.program, tokens[1].line, tokens[1].col);
        return ParserError.ParsingFailed;
    }
}

fn parseDataInstr(self: *const Parser, tokens: []Token, next_col: u16) ParserError!void {
    const line = tokens[0].line;
    if (tokens[0].type != .Ident and tokens[0].type != .HashIdent) {
        utils.printSrcLineError("expected label name", self.program, line);
        return ParserError.ParsingFailed;
    }
    if (tokens.len < 2 or tokens[1].type != .Colon) {
        utils.printSrcLineColError("expected :", self.program, line, if (tokens.len < 2) next_col else tokens[1].col);
        return ParserError.ParsingFailed;
    }
    if (tokens.len < 3 or !tokens[2].type.isDataDirective()) {
        utils.printSrcLineColError("expected data size directive", self.program, line, if (tokens.len < 3) next_col else tokens[2].col);
        return ParserError.ParsingFailed;
    }
    if (tokens.len < 4 or tokens[3].type == .NewLine) {
        utils.printSrcLineColError("expected string, number or 'repeat' statement", self.program, line, if (tokens.len < 4) next_col else tokens[3].col);
        return ParserError.ParsingFailed;
    }
    const data_size: u8 = switch (tokens[2].type) {
        .d8 => 1,
        .d16 => 2,
        .d32 => 4,
        .d64 => 8,
        else => unreachable,
    };
    const label = utils.stringValue(tokens[0].val_ind);

    const next_aligned = std.mem.alignForward(usize, self.program.data_buffer.items.len, data_size);
    const padding = next_aligned - self.program.data_buffer.items.len;
    _ = try self.program.data_buffer.addManyAsSlice(utils.alloc, padding);
    const offset = self.program.data_buffer.items.len;

    var expect_value = true;
    var i: usize = 3;
    while (i < tokens.len) {
        const token = tokens[i];

        switch (token.type) {
            .StringLiteral => {
                if (expect_value) {
                    expect_value = false;
                } else {
                    utils.printSrcLineColError("expected ,", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
                if (data_size == 1) {
                    try self.program.data_buffer.appendSlice(utils.alloc, utils.stringValue(token.val_ind));
                } else {
                    utils.printSrcLineColError("strings only supported by d8 directive", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .NumberLiteral, .HexNumLiteral, .BinNumLiteral, .Minus, .Plus => {
                if (expect_value) {
                    expect_value = false;
                } else {
                    utils.printSrcLineColError("expected ,", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
                var parsed: usize = 0;
                const num = try self.parseNumber(tokens[i..], &parsed);
                const num_size = num.fitsInBytes();
                if (num_size <= data_size) {
                    try self.appendImmediateBytes(num, data_size);
                } else {
                    utils.printSrcLineColError("value doesn't fit in specified data size", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
                i += parsed;
            },
            .repeat => {
                if (expect_value) {
                    expect_value = false;
                } else {
                    utils.printSrcLineColError("expected ,", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
                var consumed: usize = undefined;
                const repeat_oper = try self.parseRepeat(tokens[i + 1 ..], data_size, &consumed, 0x4000);
                for (0..repeat_oper.count) |_| {
                    try self.appendImmediateBytes(repeat_oper.num, data_size);
                }
                i += consumed;
            },
            .Comma => {
                if (expect_value) {
                    utils.printSrcLineColError("expected string, number or 'repeat' statement", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                } else {
                    expect_value = true;
                }
            },
            .NewLine => {},
            else => {
                if (expect_value) {
                    utils.printSrcLineColError("expected string, number or 'repeat' statement", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                } else {
                    utils.printSrcLineColError("expected , or end of line", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
        }
        i += 1;
    }

    if (tokens[i - 1].type != .NewLine) {
        utils.printSrcLineColError("expected end of line", self.program, tokens[i - 1].line, next_col);
        return ParserError.ParsingFailed;
    }

    const in_data = try self.program.data_vars.getOrPut(utils.alloc, tokens[0].val_ind);
    if (in_data.found_existing) {
        utils.printSrcLineColErrorFmt("label '{s}' already defined in this block", .{label}, self.program, line, tokens[0].col);
        return ParserError.ParsingFailed;
    } else if (self.program.funcs.contains(tokens[0].val_ind)) {
        utils.printSrcLineColErrorFmt("label '{s}' already defined in code block", .{label}, self.program, line, tokens[0].col);
        return ParserError.ParsingFailed;
    } else if (self.program.imports.contains(tokens[0].val_ind)) {
        utils.printSrcLineColErrorFmt("label '{s}' already defined in import block", .{label}, self.program, line, tokens[0].col);
        return ParserError.ParsingFailed;
    } else {
        in_data.value_ptr.visib = if (tokens[0].type == .HashIdent) .Export else .Local;
        in_data.value_ptr.block = .Data;
        in_data.value_ptr.offset = @truncate(offset);
        in_data.value_ptr.size = @truncate(self.program.data_buffer.items.len - offset);
    }
}

fn parseBssInstr(self: *const Parser, tokens: []Token) ParserError!void {
    const line = tokens[0].line;
    const col = tokens[0].col;
    if (tokens[0].type != .Ident and tokens[0].type != .HashIdent) {
        utils.printSrcLineColError("expected label name", self.program, line, col);
        return ParserError.ParsingFailed;
    }
    if (tokens[1].type != .Colon) {
        utils.printSrcLineColError("expected :", self.program, line, tokens[1].col);
        return ParserError.ParsingFailed;
    }
    if (!tokens[2].type.isDataDirective()) {
        utils.printSrcLineColError("expected data size directive", self.program, line, tokens[2].col);
        return ParserError.ParsingFailed;
    }
    const data_size: u8 = switch (tokens[2].type) {
        .d8 => 1,
        .d16 => 2,
        .d32 => 4,
        .d64 => 8,
        else => unreachable,
    };
    const label = utils.stringValue(tokens[0].val_ind);
    var count: u32 = 0;

    var i: usize = 3;
    const token = tokens[i];
    switch (token.type) {
        .NumberLiteral, .HexNumLiteral, .BinNumLiteral, .Minus, .Plus => {
            var parsed: usize = 0;
            _ = try self.parseNumber(tokens[i..], &parsed);
            i += parsed;
            count = 1;
        },
        .repeat => {
            var consumed: usize = undefined;
            const repeat_oper = try self.parseRepeat(tokens[i + 1 ..], data_size, &consumed, 0x10000);
            i += consumed;
            count = repeat_oper.count;
        },
        else => {
            utils.printSrcLineColError("expected number or 'repeat' statement", self.program, line, token.col);
            return ParserError.ParsingFailed;
        },
    }

    if (tokens[i + 1].type != .NewLine) {
        utils.printSrcLineColError("expected end of line", self.program, line, tokens[i + 1].col);
        return ParserError.ParsingFailed;
    }

    const in_data = try self.program.data_vars.getOrPut(utils.alloc, tokens[0].val_ind);
    if (in_data.found_existing) {
        utils.printSrcLineColErrorFmt("label '{s}' already defined in data or bss block", .{label}, self.program, line, col);
        return ParserError.ParsingFailed;
    } else if (self.program.funcs.contains(tokens[0].val_ind)) {
        utils.printSrcLineColErrorFmt("label '{s}' already defined in code block", .{label}, self.program, line, col);
        return ParserError.ParsingFailed;
    } else if (self.program.imports.contains(tokens[0].val_ind)) {
        utils.printSrcLineColErrorFmt("label '{s}' already defined in import block", .{label}, self.program, line, col);
        return ParserError.ParsingFailed;
    } else {
        const next_aligned = std.mem.alignForward(u32, self.program.bss_len, data_size);
        const padding = next_aligned - self.program.bss_len;
        self.program.bss_len += padding;
        const offset = self.program.bss_len;
        const size = data_size * count;
        self.program.bss_len += size;

        in_data.value_ptr.visib = if (tokens[0].type == .HashIdent) .Export else .Local;
        in_data.value_ptr.block = .Bss;
        in_data.value_ptr.offset = offset;
        in_data.value_ptr.size = size;
    }
}

fn maxInstrOperandCount(mnem: TokenType) usize {
    return switch (mnem) {
        // zig fmt: off
        .syscall => 0,
        .dec, .div, .idiv, .inc, .ja, .jae, .jb, .jbe, .jc,
            .je, .jg, .jge, .jl, .jle, .jna, .jnae, .jnb, .jnbe, .jnc, .jne, .jng,
            .jnge, .jnl, .jnle, .jno, .jnp, .jns, .jnz, .jo, .jp, .jpe, .jpo, .js,
            .jz, .jmp, .mul, .neg, .not, .pop, .push, .ret, .call 
            => 1,
        .adc, .add, .@"and", .cmp, .lea, .mov, .movdqa, .movdqu, .movzx, .@"or",
            .rcl, .rcr, .rol, .ror,
            .sal, .sar, .sbb, .shl, .shr, .sub, .@"test", .xor
            => 2,
        .imul => 3,
        // zig fmt: on
        else => unreachable,
    };
}

fn checkInstrOpLen(mnem: TokenType, oplen: usize) []const u8 {
    const number = enum { n0, n1, n2, n01, n123 };
    const expected: number = switch (mnem) {
        // zig fmt: off
        .syscall => .n0,
        .dec, .div, .idiv, .inc, .ja, .jae, .jb, .jbe, .jc,
            .je, .jg, .jge, .jl, .jle, .jna, .jnae, .jnb, .jnbe, .jnc, .jne, .jng,
            .jnge, .jnl, .jnle, .jno, .jnp, .jns, .jnz, .jo, .jp, .jpe, .jpo, .js,
            .jz, .jmp, .mul, .neg, .not, .pop, .push, .call 
            => .n1,
        .adc, .add, .@"and", .cmp, .lea, .mov, .movdqa, .movdqu, .movzx, .@"or",
            .rcl, .rcr, .rol, .ror,
            .sal, .sar, .sbb, .shl, .shr, .sub, .@"test", .xor
            => .n2,
        .imul => .n123,
        .ret => .n01,
        // zig fmt: on
        else => unreachable,
    };

    return if (expected == .n0 and oplen != 0)
        "0"
    else if (expected == .n1 and oplen != 1)
        "1"
    else if (expected == .n2 and oplen != 2)
        "2"
    else if (expected == .n01 and oplen > 1)
        "0 or 1"
    else if (expected == .n123 and (oplen < 1 or oplen > 3))
        "1, 2 or 3"
    else
        &.{};
}

fn checkMemOperand(self: *const Parser, oper: *MemOperand, line: u16) ParserError!void {
    var b_size: ?u8 = null;
    var i_size: ?u8 = null;
    if (oper.base.size > 0) {
        b_size = oper.base.size;
        if (oper.base.name == .rip and oper.index.size != 0) {
            utils.printSrcLineError("rip-relative addressing with index is not allowed", self.program, line);
            return ParserError.ParsingFailed;
        }
    }
    if (oper.index.size > 0) {
        i_size = oper.index.size;
        if (oper.index.name == .rip) {
            utils.printSrcLineError("rip register cannot be index", self.program, line);
            return ParserError.ParsingFailed;
        }
    }
    if ((b_size orelse 8) <= 2) {
        utils.printSrcLineError("invalid base register size", self.program, line);
        return ParserError.ParsingFailed;
    } else if ((i_size orelse 8) <= 2) {
        utils.printSrcLineError("invalid index register size", self.program, line);
        return ParserError.ParsingFailed;
    } else if (b_size != null and i_size != null) {
        if (b_size.? != i_size.?) {
            utils.printSrcLineError("base and index registers must have equal sizes", self.program, line);
            return ParserError.ParsingFailed;
        }
    }
}

fn checkScale(self: *const Parser, scale: i32, line: u16, col: u16) ParserError!u8 {
    switch (scale) {
        1, 2, 4, 8 => {
            return @truncate(@abs(scale));
        },
        else => {
            utils.printSrcLineColError("invalid scale in addressing", self.program, line, col);
            return ParserError.ParsingFailed;
        },
    }
}

fn parseMemAddrOperand(self: *const Parser, tokens: []Token, consumed: *usize) ParserError!MemOperand {
    var memop: MemOperand = .{
        .base = .{ .name = undefined, .size = 0 },
        .disp = 0,
        .index = .{ .name = undefined, .size = 0 },
        .scale = 0,
        .label = 0,
        .size = 0,
    };
    const first = tokens[0];
    const line = tokens[0].line;
    var i: usize = 0;
    if (first.type.isPointerSize()) {
        memop.size = switch (first.type) {
            .p8 => 1,
            .p16 => 2,
            .p32 => 4,
            .p64 => 8,
            else => unreachable,
        };
        i += 1;
    }
    if (tokens[i].type != .OpenBracket) {
        utils.printSrcLineColError("expected [", self.program, line, tokens[i].col);
        return ParserError.ParsingFailed;
    }
    const opbr_col = tokens[i].col;

    i += 1;

    const Components = struct {
        b: bool = false,
        i: bool = false,
        s: bool = false,
        d: bool = false,
        l: bool = false,
    };

    var used: Components = Components{};
    var signs: u2 = 0;

    const OpType = enum { reg, num, lbl, numaster, regaster, none };
    var op: OpType = .none;
    var imm: ?Displacement = null;
    var imm_col: u16 = 0;
    var reg: Register = .{ .name = undefined, .size = 0 };

    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        const t = token.type;

        if (t == .CloseBracket) {
            if (!used.b and !used.i) {
                memop.base = reg;
                used.b = true;
            }
            if (imm) |num| {
                if (!used.d) {
                    memop.disp = num;
                    used.d = true;
                } else {
                    utils.printSrcLineColError("unexpected number", self.program, line, imm_col);
                    return ParserError.ParsingFailed;
                }
            }
            if (op == .numaster or op == .regaster) {
                utils.printSrcLineColError("incomplete scaled index", self.program, line, token.col);
                return ParserError.ParsingFailed;
            } else if (op == .none) {
                utils.printSrcLineColError("empty memory operand", self.program, line, opbr_col);
                return ParserError.ParsingFailed;
            }
            consumed.* = i;
            try self.checkMemOperand(&memop, line);
            return memop;
        } else if (t == .Plus or t == .Minus) {
            signs += 1;
        } else if (t.isReg()) {
            if (op == .regaster) {
                utils.printSrcLineColError("invalid scaled index", self.program, line, token.col);
                return ParserError.ParsingFailed;
            } else if (signs == 0 and op != .none and op != .numaster) {
                utils.printSrcLineColError("expected + before register", self.program, line, token.col);
                return ParserError.ParsingFailed;
            }
            const new_reg = try self.parseRegister(tokens[i - signs ..]);
            if (op == .numaster) {
                memop.scale = try self.checkScale(imm.?, line, imm_col);
                used.s = true;
                memop.index = new_reg;
                used.i = true;
                imm = null;
            } else if (!used.b and !used.i) {
                if (reg.size > 0) {
                    memop.base = reg;
                    memop.index = new_reg;
                    reg = new_reg;
                    used.b = true;
                    used.i = true;
                } else {
                    reg = new_reg;
                }
            } else if (used.i) {
                memop.base = new_reg;
                used.b = true;
            } else {
                utils.printSrcLineColError("unexpected register", self.program, line, token.col);
                return ParserError.ParsingFailed;
            }
            op = .reg;
            signs = 0;
        } else if (t == .NumberLiteral or t == .HexNumLiteral or t == .BinNumLiteral) {
            if (op == .numaster) {
                utils.printSrcLineColError("invalid scaled index", self.program, line, token.col);
                return ParserError.ParsingFailed;
            } else if (signs == 0 and op != .none and op != .regaster) {
                utils.printSrcLineColError("expected sign before number", self.program, line, token.col);
                return ParserError.ParsingFailed;
            } else if (used.s and used.d) {
                utils.printSrcLineColError("unexpected number", self.program, line, token.col);
                return ParserError.ParsingFailed;
            }
            var parsed: usize = 0;
            const value = try self.parseNumber(tokens[i - signs ..], &parsed);
            const imm1 = try self.dispFromImm(value, line, token.col);

            if (op == .regaster) {
                memop.scale = try self.checkScale(imm1, line, token.col);
                used.s = true;
                memop.index = reg;
                used.i = true;
                reg = .{ .name = undefined, .size = 0 };
                if (!used.d and imm != null) {
                    memop.disp = imm.?;
                    used.d = true;
                    imm = null;
                }
            } else if (used.s and !used.d) {
                memop.disp = imm1;
                used.d = true;
                imm = null;
            } else if (op == .num and !used.d) {
                memop.disp = imm.?;
                used.d = true;
                imm = imm1;
                imm_col = token.col;
            } else if (imm == null and !used.d) {
                imm = imm1;
                imm_col = token.col;
            } else {
                utils.printSrcLineColError("unexpected number", self.program, line, token.col);
                return ParserError.ParsingFailed;
            }
            op = .num;
            signs = 0;
        } else if (t == .Ident) {
            if (used.l) {
                utils.printSrcLineColError("unexpected second label", self.program, line, token.col);
                return ParserError.ParsingFailed;
            }
            const lbl = try self.parseLabel(tokens[i - signs ..]);
            memop.label = lbl;
            used.l = true;
            op = .lbl;
            signs = 0;
        } else if (t == .Asteriks) {
            if (used.s or (op != .num and op != .reg)) {
                utils.printSrcLineColError("operand already has scaled index", self.program, line, token.col);
                return ParserError.ParsingFailed;
            }
            if (op == .num) {
                op = .numaster;
            } else if (op == .reg) {
                op = .regaster;
            }
            signs = 0;
        } else {
            utils.printSrcLineColError("invalid symbol in memory operand", self.program, line, token.col);
            return ParserError.ParsingFailed;
        }
    } else {
        utils.printSrcLineColError("not closed brackets", self.program, line, opbr_col);
        return ParserError.ParsingFailed;
    }
}

fn parseCodeOperand(self: *const Parser, tokens: []Token) ParserError!CodeOperand {
    var oper: CodeOperand = undefined;

    const OpType = enum { reg, imm, lbl, lblimm, mem, none };
    var op: OpType = .none;
    var signs: u2 = 0;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        const t = token.type;

        if (t.isReg()) {
            if (op != .none) {
                utils.printSrcLineColError("unexpected register", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            } else if (t == .rip) {
                utils.printSrcLineColError("rip register cannot be operand", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            const reg = try self.parseRegister(tokens[i - signs ..]);
            oper = .initReg(reg);
            signs = 0;
            op = .reg;
        } else if (t == .Plus or t == .Minus) {
            signs += 1;
        } else if (t == .Ident or t == .DotIdent) {
            const label = try self.parseLabel(tokens[i - signs ..]);
            if (op == .none) {
                oper = .initLbl(label, null);
                op = .lbl;
            } else if (op == .imm) {
                oper = .initImm(oper.op.imm.i);
                op = .lblimm;
            } else {
                utils.printSrcLineColError("unexpected label", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            signs = 0;
        } else if (t == .NumberLiteral or t == .HexNumLiteral or t == .BinNumLiteral) {
            var parsed: usize = 0;
            const value = try self.parseNumber(tokens[i - signs ..], &parsed);
            if (op == .lbl) {
                oper.op.label.d = value;
                op = .lblimm;
            } else if (op == .none) {
                oper = .initImm(value);
                op = .imm;
            } else {
                utils.printSrcLineColError("unexpected number", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            signs = 0;
        } else if (t == .StringLiteral) {
            if (utils.stringValue(token.val_ind).len != 1) {
                utils.printSrcLineColError("string literal must be 1-byte long", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            const neg: bool = switch (signs) {
                0 => false,
                1 => (tokens[i - 1].type == .Minus),
                2 => (tokens[i - 1].type == .Minus or tokens[i - 2].type == .Minus) and !(tokens[i - 1].type == .Minus and tokens[i - 2].type == .Minus),
                else => unreachable,
            };
            const value = utils.stringValue(token.val_ind)[0];
            const imm = if (!neg) Immediate{ .bits = value, .sign = .u } else Immediate{ .bits = @intCast(-@as(i16, value)), .sign = .i };
            if (op == .lbl) {
                oper.op.label.d = imm;
                op = .lblimm;
            } else if (op == .none) {
                oper = .initImm(imm);
                op = .imm;
            } else {
                utils.printSrcLineColError("unexpected string literal", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            signs = 0;
        } else if (t.isPointerSize() or t == .OpenBracket) {
            if (op == .none) {
                var parsed: usize = 0;
                oper = .initMem(try self.parseMemAddrOperand(tokens[i..], &parsed));
                i += parsed;
                signs = 0;
                op = .mem;
            } else {
                utils.printSrcLineColError("unexpected memory operand", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        } else {
            utils.printSrcLineColError("unexpected symbol", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
    }

    return oper;
}

fn parseCodeInstr(self: *Parser, tokens: []Token) ParserError!void {
    const line = tokens[0].line;
    var instr: CodeInstruction = undefined;
    if (tokens[0].type.isAnyIdent()) {
        if (tokens[1].type != .Colon) {
            utils.printSrcLineColError("expected :", self.program, line, tokens[1].col);
            return ParserError.ParsingFailed;
        }
        const label = utils.stringValue(tokens[0].val_ind);
        const is_func = if (tokens[0].type == .DotIdent) false else true;

        if (is_func) {
            const in_code = try self.program.funcs.getOrPut(utils.alloc, tokens[0].val_ind);
            if (in_code.found_existing) {
                utils.printSrcLineColErrorFmt("label '{s}' already defined in this block", .{label}, self.program, line, tokens[0].col);
                return ParserError.ParsingFailed;
            } else if (self.program.data_vars.contains(tokens[0].val_ind)) {
                utils.printSrcLineColErrorFmt("label '{s}' already defined in data block", .{label}, self.program, line, tokens[0].col);
                return ParserError.ParsingFailed;
            } else if (self.program.imports.contains(tokens[0].val_ind)) {
                utils.printSrcLineColErrorFmt("label '{s}' already defined in import block", .{label}, self.program, line, tokens[0].col);
                return ParserError.ParsingFailed;
            } else {
                self.cur_func = tokens[0].val_ind;
                in_code.value_ptr.visib = if (tokens[0].type == .HashIdent) .Export else .Local;
                in_code.value_ptr.size = 0;
                in_code.value_ptr.offset = 0;
                in_code.value_ptr.local_labels = .empty;
            }
        } else {
            const function = self.program.funcs.getPtr(self.cur_func);
            if (function) |func| {
                const in_func = try func.local_labels.getOrPut(utils.alloc, tokens[0].val_ind);
                if (in_func.found_existing) {
                    utils.printSrcLineColErrorFmt("local label '{s}' already defined in function '{s}'", .{ label, utils.stringValue(self.cur_func) }, self.program, line, tokens[0].col);
                    return ParserError.ParsingFailed;
                } else {
                    in_func.value_ptr.* = std.math.maxInt(u32);
                }
            } else {
                utils.printSrcLineColErrorFmt("local label '{s}' does not belong to any function", .{label}, self.program, line, tokens[0].col);
                return ParserError.ParsingFailed;
            }
        }

        instr = .{ .label = .{ .name = tokens[0].val_ind, .line = line } };
        try self.program.code_block.instr.append(utils.alloc, instr);
    } else if (tokens[0].type.isMnemonic()) {
        instr = .{ .cpu = .{ .mnem = tokens[0].type, .operands = .{ .index = 0, .len = 0 }, .line = line } };

        var i: usize = 1;
        var oper_count: usize = 0;
        var oper_tokens: []Token = tokens[1..1];
        const max_oper_count = maxInstrOperandCount(instr.cpu.mnem);
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .Comma or token.type == .NewLine) {
                if (oper_tokens.len > 0) {
                    if (oper_count + 1 > max_oper_count) {
                        utils.printSrcLineColError("unexpected operand", self.program, token.line, oper_tokens[0].col);
                        return ParserError.ParsingFailed;
                    }
                    const operand = try self.parseCodeOperand(oper_tokens);
                    try self.program.code_block.operands.append(utils.alloc, operand);
                    if (instr.cpu.operands.len == 0) {
                        instr.cpu.operands = .{ .index = @truncate(self.program.code_block.operands.items.len - 1), .len = 1 };
                    } else {
                        instr.cpu.operands.len += 1;
                    }
                    oper_count += 1;
                    oper_tokens = tokens[i + 1 .. i + 1];
                } else if (token.type != .NewLine or i > 1) {
                    utils.printSrcLineColError("expected instruction operand", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            } else {
                oper_tokens.len += 1;
            }
        }

        const message = checkInstrOpLen(instr.cpu.mnem, instr.cpu.operands.len);
        if (message.len > 0) {
            utils.printSrcLineErrorFmt("wrong number of operands for '{t}' instruction, expected {s}", .{ instr.cpu.mnem, message }, self.program, line);
            return ParserError.ParsingFailed;
        }
        try self.program.code_block.instr.append(utils.alloc, instr);
    } else {
        utils.printSrcLineColError("expected label or mnemonic", self.program, line, tokens[0].col);
        return ParserError.ParsingFailed;
    }
}

fn parseImportBlock(self: *const Parser, tokens: []Token) ParserError!usize {
    var import_name: ?Label = null;
    var start: usize = 1;
    if (tokens[0].type == .NewLine) {
        import_name = null;
    } else if (tokens[0].type == .StringLiteral and tokens[1].type == .NewLine) {
        import_name = tokens[0].val_ind;
        start += 1;
    } else {
        utils.printSrcLineError("expected library name or end of line", self.program, tokens[0].line);
        return ParserError.ParsingFailed;
    }
    if (import_name) |imp| {
        if (self.program.shared_libs.items.len == 0) {
            try self.program.shared_libs.append(utils.alloc, 0);
        }
        try self.program.shared_libs.append(utils.alloc, imp);
        self.program.flags.has_shared = true;
    }
    const shared_index: u16 = if (import_name) |_| @truncate(self.program.shared_libs.items.len - 1) else 0;
    var expect_symbol = true;
    for (tokens[start..], start..) |token, i| {
        if (expect_symbol) {
            if (token.type == .Ident) {
                const label = utils.stringValue(token.val_ind);
                const in_import = try self.program.imports.getOrPut(utils.alloc, token.val_ind);
                if (in_import.found_existing) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in this block", .{label}, self.program, token.line);
                    return ParserError.ParsingFailed;
                } else if (self.program.data_vars.contains(token.val_ind)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in data block", .{label}, self.program, token.line);
                    return ParserError.ParsingFailed;
                } else if (self.program.funcs.contains(token.val_ind)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in code block", .{label}, self.program, token.line);
                    return ParserError.ParsingFailed;
                } else {
                    in_import.value_ptr.* = shared_index;
                }
                expect_symbol = false;
            } else if (token.type.isBlockDecl()) {
                return i;
            } else {
                utils.printSrcLineError("expected label name", self.program, token.line);
                return ParserError.ParsingFailed;
            }
        } else {
            if (token.type == .Comma or token.type == .NewLine) {
                expect_symbol = true;
            } else if (token.type.isBlockDecl() or token.type == .Eof) {
                return i;
            } else {
                utils.printSrcLineError("expected ,", self.program, token.line);
                return ParserError.ParsingFailed;
            }
        }
    }
    return tokens.len;
}

fn parseBlock(self: *Parser, tokens: []Token, block_type: BlockType) ParserError!usize {
    if (tokens[0].type != .NewLine) {
        utils.printSrcLineColError("expected end of line after block keyword", self.program, tokens[0].line, tokens[0].col);
        return ParserError.ParsingFailed;
    }
    var already_started = false;
    var cur_instr: []Token = tokens[1..1];
    var i: usize = 1;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        const is_block_decl = token.type.isBlockDecl() or token.type == .Eof;
        const data_instr_end = block_type == .data and (token.type == .Ident or token.type == .HashIdent or is_block_decl);
        if (data_instr_end) {
            if (!already_started) {
                already_started = true;
                cur_instr.len += 1;
                continue;
            }
            try self.parseDataInstr(cur_instr, token.col);
            cur_instr = tokens[i .. i + 1];
            if (is_block_decl) {
                return i;
            }
        } else if (token.type == .NewLine) {
            cur_instr.len += 1;
            switch (block_type) {
                .code => try self.parseCodeInstr(cur_instr),
                .bss => try self.parseBssInstr(cur_instr),
                else => continue,
            }
            cur_instr = tokens[i + 1 .. i + 1];
        } else if (token.type.isBlockDecl() or token.type == .Eof) {
            return i;
        } else {
            cur_instr.len += 1;
        }
    }
    return tokens.len;
}

pub fn parseTokens(self: *Parser) ParserError!void {
    var i: usize = 0;
    while (i < self.program.tokens.items.len) : (i += 1) {
        const token = self.program.tokens.items[i];

        switch (token.type) {
            .entry => {
                if (!self.program.flags.has_entry) {
                    try self.parseEntry(self.program.tokens.items[i + 1 ..]);
                    i += 2;
                    self.program.flags.has_entry = true;
                } else {
                    utils.printSrcLineColError("entry label already defined in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .data => {
                if (!self.program.flags.has_data) {
                    const len = try self.parseBlock(self.program.tokens.items[i + 1 ..], .data);
                    i += len;
                    if (self.program.data_buffer.items.len > 0) {
                        self.program.flags.has_data = true;
                    }
                } else {
                    utils.printSrcLineColError("data block already present in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .bss => {
                if (!self.program.flags.has_bss) {
                    const len = try self.parseBlock(self.program.tokens.items[i + 1 ..], .bss);
                    i += len;
                    if (self.program.bss_len > 0) {
                        self.program.flags.has_bss = true;
                    }
                } else {
                    utils.printSrcLineColError("bss block already present in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .code => {
                if (!self.program.flags.has_code) {
                    const len = try self.parseBlock(self.program.tokens.items[i + 1 ..], .code);
                    i += len;
                    if (self.program.code_block.instr.items.len > 0) {
                        self.program.flags.has_code = true;
                    }
                } else {
                    utils.printSrcLineColError("code block already present in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .import => {
                const len = try self.parseImportBlock(self.program.tokens.items[i + 1 ..]);
                i += len;
            },
            .NewLine, .Eof => {},
            else => {
                utils.printSrcLineColError("expected block declaration", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            },
        }
    }
}
