const std = @import("std");
const utils = @import("utils");

const lexer = @import("lexer");
const Token = lexer.Token;

const Program = @import("Program");
const Register = Program.Register;
const Displacement = Program.Displacement;
const Immediate = Program.Immediate;
const Address = Program.Address;
const CodeOperand = Program.CodeOperand;
const DataOperand = Program.DataOperand;
const DataInstruction = Program.DataInstruction;
const CodeInstruction = Program.CodeInstruction;

const Parser = @This();

program: *Program,
cur_func: []const u8,

const MAX_OPERAND_COUNT = 3;

pub const ParserError = error{ParsingFailed} || std.mem.Allocator.Error;

pub fn init(program: *Program) Parser {
    return Parser{
        .program = program,
        .cur_func = &.{},
    };
}

/// token must be .NumberLiteral
fn immFromToken(self: *const Parser, token: Token) ParserError!Immediate {
    const value = std.fmt.parseInt(u64, token.value, 10) catch {
        utils.printSrcLineErrorFmt("value {s} doesn't fit in 64 bit", .{token.value}, self.program.file_name, self.program.content, token.line);
        return ParserError.ParsingFailed;
    };
    const imm = Immediate{ .u = value };
    return imm;
}

fn parseEntry(self: *const Parser, tokens: []Token) ParserError!void {
    const next = tokens[0];
    if (next.type == .Ident) {
        self.program.entry = next.value;
    } else {
        utils.printSrcLineError("expected identifier after entry keyword", self.program.file_name, self.program.content, next.line);
        return ParserError.ParsingFailed;
    }
    if (tokens[1].type != .NewLine) {
        utils.printSrcLineError("unexpected symbols on line", self.program.file_name, self.program.content, tokens[1].line);
        return ParserError.ParsingFailed;
    }
}

/// Adds 0 to consumed for "45", 1 for "- 45" and 2 for "- - 45"
fn parseNumber(self: *const Parser, tokens: []Token, consumed: *usize) ParserError!Immediate {
    var plus = true;
    for (tokens) |token| {
        if (token.type == .Plus) {
            plus = plus;
        } else if (token.type == .Minus) {
            plus = !plus;
        } else if (token.type == .NumberLiteral) {
            var imm = try self.immFromToken(token);
            if (!plus) {
                imm.toNegative() catch {
                    utils.printSrcLineErrorFmt("value -{s} doesn't fit in 64 bit", .{token.value}, self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                };
            }
            return imm;
        } else {
            utils.printSrcLineError("expected number", self.program.file_name, self.program.content, token.line);
            return ParserError.ParsingFailed;
        }
        consumed.* += 1;
    } else {
        utils.printSrcLineError("expected number", self.program.file_name, self.program.content, tokens[0].line);
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
                utils.printSrcLineError("register cannot follow minus sign", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
            return Register.init(token.type);
        } else {
            utils.printSrcLineError("expected register", self.program.file_name, self.program.content, token.line);
            return ParserError.ParsingFailed;
        }
    } else {
        utils.printSrcLineError("expected register", self.program.file_name, self.program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
}

fn parseLabel(self: *const Parser, tokens: []Token) ParserError![]const u8 {
    var plus = true;
    for (tokens) |token| {
        if (token.type == .Plus) {
            plus = plus;
        } else if (token.type == .Minus) {
            plus = !plus;
        } else if (token.type == .Ident or token.type == .DotIdent) {
            if (!plus) {
                utils.printSrcLineError("label cannot follow minus sign", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
            return token.value;
        } else {
            utils.printSrcLineError("expected label", self.program.file_name, self.program.content, token.line);
            return ParserError.ParsingFailed;
        }
    } else {
        utils.printSrcLineError("expected label", self.program.file_name, self.program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
}

fn dispFromImm(self: *const Parser, imm: Immediate, line: u16) ParserError!Displacement {
    var disp: i32 = undefined;
    switch (imm) {
        .u => {
            if (imm.u <= std.math.maxInt(i32)) {
                disp = @intCast(imm.u);
            } else {
                utils.printSrcLineError("too large displacement in operand", self.program.file_name, self.program.content, line);
                return ParserError.ParsingFailed;
            }
        },
        .i => {
            if (imm.fitsInBytes() <= 4) {
                disp = @truncate(imm.i);
            } else {
                utils.printSrcLineError("too large displacement in operand", self.program.file_name, self.program.content, line);
                return ParserError.ParsingFailed;
            }
        },
    }
    return disp;
}

fn parseRepeat(self: *const Parser, tokens: []Token, data_size: u8, line: u16, consumed: *usize) ParserError!DataOperand {
    var data_oper: DataOperand = undefined;
    var i: usize = 0;
    if (tokens[i].type == .OpenParenthes) {
        switch (tokens[i + 1].type) {
            .NumberLiteral, .Minus, .Plus => {
                var parsed: usize = 0;
                const count = try self.parseNumber(tokens[i + 1 ..], &parsed);
                i += parsed;
                const count_value: u32 = switch (count) {
                    .u => @truncate(count.u),
                    .i => {
                        utils.printSrcLineError("expected non-negative number as repeat count", self.program.file_name, self.program.content, line);
                        return ParserError.ParsingFailed;
                    },
                };
                if (count_value * data_size > 16384) {
                    utils.printSrcLineError("repeat count is too large for this data size", self.program.file_name, self.program.content, line);
                    return ParserError.ParsingFailed;
                }
                if (tokens[i + 2].type == .Comma) {
                    switch (tokens[i + 3].type) {
                        .NumberLiteral, .Minus, .Plus => {
                            parsed = 0;
                            const value = try self.parseNumber(tokens[i + 3 ..], &parsed);
                            i += parsed;
                            const value_size = value.fitsInBytes();
                            if (value_size <= data_size) {
                                data_oper = .{ .repeat = .{ .count = count_value, .item = .{ .num = value } } };
                            } else {
                                utils.printSrcLineError("value doesn't fit in specified data size", self.program.file_name, self.program.content, tokens[i + 3].line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        .StringLiteral => {
                            if (data_size == 1) {
                                data_oper = .{ .repeat = .{ .count = count_value, .item = .{ .str = tokens[3].value } } };
                            } else {
                                utils.printSrcLineError("strings only supported by d8 directive", self.program.file_name, self.program.content, line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        else => {
                            utils.printSrcLineError("expected number or string literal", self.program.file_name, self.program.content, line);
                            return ParserError.ParsingFailed;
                        },
                    }
                    if (tokens[i + 4].type == .CloseParenthes) {
                        consumed.* = i + 4 + 1;
                        return data_oper;
                    } else {
                        utils.printSrcLineErrorFmt("expected ) after {s}", .{tokens[i + 3].value}, self.program.file_name, self.program.content, line);
                        return ParserError.ParsingFailed;
                    }
                } else {
                    utils.printSrcLineErrorFmt("expected , after {s}", .{tokens[i + 1].value}, self.program.file_name, self.program.content, line);
                    return ParserError.ParsingFailed;
                }
            },
            else => {
                utils.printSrcLineError("expected non-negative number as repeat count", self.program.file_name, self.program.content, line);
                return ParserError.ParsingFailed;
            },
        }
    } else {
        utils.printSrcLineError("expected '(' after repeat keyword", self.program.file_name, self.program.content, line);
        return ParserError.ParsingFailed;
    }
}

fn parseDataInstr(self: *const Parser, tokens: []Token) ParserError!void {
    var instr: DataInstruction = undefined;
    if (tokens[0].type == .Ident or tokens[0].type == .HashIdent) {
        if (tokens[1].type == .Colon) {
            if (tokens[2].type.isDataDirective()) {
                const data_size: u8 = switch (tokens[2].type) {
                    .d8 => 1,
                    .d16 => 2,
                    .d32 => 4,
                    .d64 => 8,
                    else => unreachable,
                };
                instr.label = tokens[0].value;
                instr.size = data_size;
                instr.data = .empty;
                errdefer instr.data.deinit(utils.alloc);

                var expect_value = true;
                var i: usize = 3;
                while (i < tokens.len) {
                    const token = tokens[i];

                    switch (token.type) {
                        .StringLiteral => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                utils.printSrcLineError("expected ','", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                            if (data_size == 1) {
                                const data_oper = DataOperand{ .str = token.value };
                                try instr.data.append(utils.alloc, data_oper);
                            } else {
                                utils.printSrcLineError("strings only supported by d8 directive", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        .NumberLiteral, .Minus, .Plus => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                utils.printSrcLineError("expected ','", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                            var parsed: usize = 0;
                            const num = try self.parseNumber(tokens[i..], &parsed);
                            const num_size = num.fitsInBytes();
                            if (num_size <= data_size) {
                                const data_oper = DataOperand{ .num = num };
                                try instr.data.append(utils.alloc, data_oper);
                            } else {
                                utils.printSrcLineError("value doesn't fit in specified data size", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                            i += parsed;
                        },
                        .repeat => {
                            if (expect_value) {
                                expect_value = false;
                            } else {
                                utils.printSrcLineError("expected ','", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                            var consumed: usize = undefined;
                            const data_oper = try self.parseRepeat(tokens[i + 1 ..], data_size, token.line, &consumed);
                            try instr.data.append(utils.alloc, data_oper);
                            i += consumed;
                        },
                        .Comma => {
                            if (!expect_value) {
                                expect_value = true;
                            } else {
                                utils.printSrcLineError("expected ','", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        .NewLine => {
                            if (!expect_value) {
                                expect_value = true;
                            } else {
                                utils.printSrcLineError("expected string, number or 'repeat' statement", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                        else => {
                            if (expect_value) {
                                utils.printSrcLineError("expected string, number or 'repeat' statement", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            } else {
                                utils.printSrcLineError("expected ',' or end of line", self.program.file_name, self.program.content, token.line);
                                return ParserError.ParsingFailed;
                            }
                        },
                    }
                    i += 1;
                }

                const in_data = try self.program.data_vars.getOrPut(instr.label);
                if (in_data.found_existing) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in this block", .{instr.label}, self.program.file_name, self.program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                } else if (self.program.funcs.contains(instr.label)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in code block", .{instr.label}, self.program.file_name, self.program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                } else if (self.program.imports.contains(instr.label)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in import block", .{instr.label}, self.program.file_name, self.program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                } else {
                    in_data.value_ptr.visib = if (tokens[0].type == .HashIdent) .Export else .Local;
                    in_data.value_ptr.offset = 0;
                    in_data.value_ptr.size = 0;
                }

                try self.program.data_block.instr.append(utils.alloc, instr);
            } else {
                utils.printSrcLineError("expected data size directive", self.program.file_name, self.program.content, tokens[2].line);
                return ParserError.ParsingFailed;
            }
        } else {
            utils.printSrcLineError("expected ':' after label name", self.program.file_name, self.program.content, tokens[1].line);
            return ParserError.ParsingFailed;
        }
    } else {
        utils.printSrcLineError("expected label name", self.program.file_name, self.program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
}

fn parseDataBlock(self: *const Parser, tokens: []Token) ParserError!usize {
    if (tokens[0].type == .NewLine) {
        var cur_instr: []Token = tokens[1..1];
        var i: usize = 1;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
                cur_instr.len += 1;
                try self.parseDataInstr(cur_instr);
                cur_instr = tokens[i + 1 .. i + 1];
            } else if (token.type.isBlockDecl()) {
                return i;
            } else {
                cur_instr.len += 1;
            }
        }
    } else {
        utils.printSrcLineError("unexpected symbols in block declaration", self.program.file_name, self.program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
    return tokens.len;
}

fn checkMemOperand(self: *const Parser, oper: *Address, line: u16) ParserError!void {
    if (oper.disp == 0 and !(oper.base == null and oper.index == null)) {
        oper.disp = null;
    }
    var b_size: ?u8 = null;
    var i_size: ?u8 = null;
    if (oper.base) |base| {
        b_size = base.size;
        if (base.name == .rip and oper.index != null) {
            utils.printSrcLineError("rip-relative addressing with index is not allowed", self.program.file_name, self.program.content, line);
            return ParserError.ParsingFailed;
        }
    }
    if (oper.index) |index| {
        i_size = index.size;
        if (index.name == .rip) {
            utils.printSrcLineError("rip register cannot be index", self.program.file_name, self.program.content, line);
            return ParserError.ParsingFailed;
        }
    }
    if ((b_size orelse 8) <= 2) {
        utils.printSrcLineError("invalid base register size", self.program.file_name, self.program.content, line);
        return ParserError.ParsingFailed;
    } else if ((i_size orelse 8) <= 2) {
        utils.printSrcLineError("invalid index register size", self.program.file_name, self.program.content, line);
        return ParserError.ParsingFailed;
    } else if (b_size != null and i_size != null) {
        if (b_size.? != i_size.?) {
            utils.printSrcLineError("base and index registers must have equal sizes", self.program.file_name, self.program.content, line);
            return ParserError.ParsingFailed;
        }
    }
}

fn checkScale(self: *const Parser, scale: i32, line: u16) ParserError!u8 {
    switch (scale) {
        1, 2, 4, 8 => {
            return @truncate(@abs(scale));
        },
        else => {
            utils.printSrcLineError("invalid scale in addressing", self.program.file_name, self.program.content, line);
            return ParserError.ParsingFailed;
        },
    }
}

fn parseMemAddrOperand(self: *const Parser, tokens: []Token, consumed: *usize) ParserError!CodeOperand {
    var addr: Address = .{ .base = null, .disp = null, .index = null, .scale = null, .label = null };
    var ptr_size: ?u8 = null;
    const first = tokens[0];
    var i: usize = 0;
    if (first.type.isPointerSize()) {
        ptr_size = switch (first.type) {
            .p8 => 1,
            .p16 => 2,
            .p32 => 4,
            .p64 => 8,
            else => unreachable,
        };
        i += 1;
    }
    if (tokens[i].type == .OpenBracket) {
        i += 1;

        const Components = struct {
            b: bool,
            i: bool,
            s: bool,
            d: bool,
            l: bool,

            const empty = @This(){
                .b = false,
                .i = false,
                .s = false,
                .d = false,
                .l = false,
            };
        };

        var used: Components = .empty;
        var signs: u2 = 0;

        const OpType = enum {
            reg,
            num,
            lbl,
            numaster,
            regaster,
            none,
        };

        var op: OpType = .none;
        var imm: ?i32 = null;
        var reg: ?Register = null;

        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            const t = token.type;

            if (t == .CloseBracket) {
                if (!used.b and !used.i) {
                    addr.base = reg;
                    used.b = true;
                }
                if (imm) |num| {
                    if (!used.d) {
                        addr.disp = num;
                        used.d = true;
                    } else {
                        utils.printSrcLineError("too many numbers in operand", self.program.file_name, self.program.content, token.line);
                        return ParserError.ParsingFailed;
                    }
                }
                if (op == .numaster or op == .regaster) {
                    utils.printSrcLineError("incomplete scaled index", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                } else if (op == .none) {
                    utils.printSrcLineError("empty memory operand", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                consumed.* = i;
                try self.checkMemOperand(&addr, token.line);
                const oper: CodeOperand = .{ .mem = .{ .addr = addr, .size = ptr_size } };
                return oper;
            } else if (t == .Plus or t == .Minus) {
                signs += 1;
            } else if (t.isReg()) {
                if (op == .regaster) {
                    utils.printSrcLineError("invalid scaled index", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                } else if (signs == 0 and op != .none and op != .numaster) {
                    utils.printSrcLineError("expected + before register", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                const new_reg = try self.parseRegister(tokens[i - signs ..]);
                if (op == .numaster) {
                    addr.scale = try self.checkScale(imm.?, token.line);
                    used.s = true;
                    addr.index = new_reg;
                    used.i = true;
                    imm = null;
                } else if (!used.b and !used.i) {
                    if (reg) |_| {
                        addr.base = reg;
                        addr.index = new_reg;
                        reg = new_reg;
                        used.b = true;
                        used.i = true;
                    } else {
                        reg = new_reg;
                    }
                } else if (used.i) {
                    addr.base = new_reg;
                    used.b = true;
                } else {
                    utils.printSrcLineError("unexpected register", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                op = .reg;
                signs = 0;
            } else if (t == .NumberLiteral) {
                if (op == .numaster) {
                    utils.printSrcLineError("invalid scaled index", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                } else if (signs == 0 and op != .none and op != .regaster) {
                    utils.printSrcLineError("expected sign before number", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                } else if (used.s and used.d) {
                    utils.printSrcLineError("too many numbers in operand", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                var parsed: usize = 0;
                const value = try self.parseNumber(tokens[i - signs ..], &parsed);
                const imm1 = try self.dispFromImm(value, token.line);

                if (op == .regaster) {
                    addr.scale = try self.checkScale(imm1, token.line);
                    used.s = true;
                    addr.index = reg;
                    used.i = true;
                    reg = null;
                    if (!used.d and imm != null) {
                        addr.disp = imm.?;
                        used.d = true;
                        imm = null;
                    }
                } else if (used.s and !used.d) {
                    addr.disp = imm1;
                    used.d = true;
                    imm = null;
                } else if (op == .num and !used.d) {
                    addr.disp = imm.?;
                    used.d = true;
                    imm = imm1;
                } else if (imm == null and !used.d) {
                    imm = imm1;
                } else {
                    utils.printSrcLineError("too many numbers in operand", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                op = .num;
                signs = 0;
            } else if (t == .Ident) {
                if (used.l) {
                    utils.printSrcLineError("unexpected second label", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                const lbl = try self.parseLabel(tokens[i - signs ..]);
                addr.label = lbl;
                used.l = true;
                op = .lbl;
                signs = 0;
            } else if (t == .Asteriks) {
                if (used.s or (op != .num and op != .reg)) {
                    utils.printSrcLineError("unexpected *", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
                if (op == .num) {
                    op = .numaster;
                } else if (op == .reg) {
                    op = .regaster;
                }
                signs = 0;
            } else {
                utils.printSrcLineError("invalid symbol in memory operand", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
        } else {
            utils.printSrcLineError("not closed brackets", self.program.file_name, self.program.content, first.line);
            return ParserError.ParsingFailed;
        }
    } else {
        utils.printSrcLineError("expected [", self.program.file_name, self.program.content, first.line);
        return ParserError.ParsingFailed;
    }
}

fn parseCodeOperand(self: *const Parser, tokens: []Token) ParserError!CodeOperand {
    var oper: CodeOperand = undefined;

    var signs: u2 = 0;

    const OpType = enum {
        reg,
        imm,
        lbl,
        lblimm,
        mem,
        none,
    };

    var op: OpType = .none;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        const t = token.type;

        if (t.isReg() and t != .rip) {
            if (op != .none) {
                utils.printSrcLineError("unexpected register", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
            const reg = try self.parseRegister(tokens[i - signs ..]);
            oper = .{ .reg = reg };
            signs = 0;
            op = .reg;
        } else if (t == .Plus or t == .Minus) {
            signs += 1;
        } else if (t == .Ident or t == .DotIdent) {
            const label = try self.parseLabel(tokens[i - signs ..]);
            if (op == .none) {
                oper = .{ .label = .{ .l = label, .d = .{ .u = 0 } } };
                op = .lbl;
            } else if (op == .imm) {
                oper = .{ .label = .{ .l = label, .d = oper.imm } };
                op = .lblimm;
            } else {
                utils.printSrcLineError("unexpected label", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
            signs = 0;
        } else if (t == .NumberLiteral) {
            var parsed: usize = 0;
            const value = try self.parseNumber(tokens[i - signs ..], &parsed);
            if (op == .lbl) {
                oper.label.d = value;
                op = .lblimm;
            } else if (op == .none) {
                oper = .{ .imm = value };
                op = .imm;
            } else {
                utils.printSrcLineError("unexpected number", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
            signs = 0;
        } else if (t == .StringLiteral) {
            if (token.value.len != 1) {
                utils.printSrcLineError("string literal must be 1 character long", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
            const neg: bool = switch (signs) {
                0 => false,
                1 => (tokens[i - 1].type == .Minus),
                2 => (tokens[i - 1].type == .Minus or tokens[i - 2].type == .Minus) and !(tokens[i - 1].type == .Minus and tokens[i - 2].type == .Minus),
                else => unreachable,
            };
            const value = token.value[0];
            if (op == .lbl) {
                oper.label.d = if (!neg) .{ .u = value } else .{ .i = -@as(i32, value) };
                op = .lblimm;
            } else if (op == .none) {
                oper = .{ .imm = if (!neg) .{ .u = value } else .{ .i = -@as(i32, value) } };
                op = .imm;
            } else {
                utils.printSrcLineError("unexpected string literal", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
            signs = 0;
        } else if (t.isPointerSize() or t == .OpenBracket) {
            if (op == .none) {
                var parsed: usize = 0;
                oper = try self.parseMemAddrOperand(tokens[i..], &parsed);
                i += parsed;
                signs = 0;
                op = .mem;
            } else {
                utils.printSrcLineError("unexpected memory operand", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
        } else {
            utils.printSrcLineError("invalid operand", self.program.file_name, self.program.content, token.line);
            return ParserError.ParsingFailed;
        }
    }

    return oper;
}

fn parseCodeInstr(self: *Parser, tokens: []Token) ParserError!void {
    var instr: CodeInstruction = undefined;
    if (tokens[0].type.isAnyIdent()) {
        if (tokens.len > 1 and tokens[1].type == .Colon) {
            const label = tokens[0].value;
            const is_func = if (tokens[0].type == .DotIdent) false else true;

            if (is_func) {
                const in_code = try self.program.funcs.getOrPut(label);
                if (in_code.found_existing) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in this block", .{label}, self.program.file_name, self.program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                } else if (self.program.data_vars.contains(label)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in data block", .{label}, self.program.file_name, self.program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                } else if (self.program.imports.contains(label)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in import block", .{label}, self.program.file_name, self.program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                } else {
                    self.cur_func = label;
                    in_code.value_ptr.visib = if (tokens[0].type == .HashIdent) .Export else .Local;
                    in_code.value_ptr.size = 0;
                    in_code.value_ptr.offset = 0;
                    in_code.value_ptr.local_labels = .init(utils.alloc);
                }
            } else {
                const function = self.program.funcs.getPtr(self.cur_func);
                if (function) |func| {
                    const in_func = try func.local_labels.getOrPut(label);
                    if (in_func.found_existing) {
                        utils.printSrcLineErrorFmt("local label '{s}' already defined in function '{s}'", .{ label, self.cur_func }, self.program.file_name, self.program.content, tokens[0].line);
                        return ParserError.ParsingFailed;
                    } else {
                        in_func.value_ptr.* = std.math.maxInt(usize);
                    }
                } else {
                    utils.printSrcLineErrorFmt("local label '{s}' does not belong to any function", .{label}, self.program.file_name, self.program.content, tokens[0].line);
                    return ParserError.ParsingFailed;
                }
            }

            instr = .{ .label = .{ .name = label, .line = tokens[0].line } };
            try self.program.code_block.instr.append(utils.alloc, instr);
        } else {
            utils.printSrcLineError("expected ':' after label name", self.program.file_name, self.program.content, tokens[0].line);
            return ParserError.ParsingFailed;
        }
    } else if (tokens[0].type.isMnemonic()) {
        instr = .{ .cpu = .{ .mnem = tokens[0].type, .operands = .empty, .line = tokens[0].line } };
        errdefer instr.cpu.operands.deinit(utils.alloc);

        var i: usize = 1;
        var oper_count: usize = 1;
        var oper_tokens: []Token = tokens[1..1];
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .Comma or token.type == .NewLine) {
                if (oper_tokens.len > 0) {
                    const operand = try self.parseCodeOperand(oper_tokens);
                    if (oper_count <= MAX_OPERAND_COUNT) {
                        try instr.cpu.operands.append(utils.alloc, operand);
                        oper_count += 1;
                        oper_tokens = tokens[i + 1 .. i + 1];
                    } else {
                        utils.printSrcLineError("too many operands for instruction", self.program.file_name, self.program.content, token.line);
                        return ParserError.ParsingFailed;
                    }
                } else if (tokens[i - 1].type == .Comma) {
                    utils.printSrcLineError("expected instruction operand", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
            } else {
                oper_tokens.len += 1;
            }
        }

        try self.program.code_block.instr.append(utils.alloc, instr);
    } else {
        utils.printSrcLineError("expected label or mnemonic", self.program.file_name, self.program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
}

fn parseCodeBlock(self: *Parser, tokens: []Token) ParserError!usize {
    if (tokens[0].type == .NewLine) {
        var cur_instr: []Token = tokens[1..1];
        var i: usize = 1;
        while (i < tokens.len) : (i += 1) {
            const token = tokens[i];
            if (token.type == .NewLine) {
                cur_instr.len += 1;
                try self.parseCodeInstr(cur_instr);
                cur_instr = tokens[i + 1 .. i + 1];
            } else if (token.type.isBlockDecl()) {
                return i;
            } else {
                cur_instr.len += 1;
            }
        }
    } else {
        utils.printSrcLineError("unexpected symbols on line", self.program.file_name, self.program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
    return tokens.len;
}

fn parseImportBlock(self: *const Parser, tokens: []Token) ParserError!usize {
    var import_name: ?[]const u8 = null;
    var start: usize = 1;
    if (tokens[0].type == .NewLine) {
        import_name = null;
    } else if (tokens[0].type == .StringLiteral and tokens[1].type == .NewLine) {
        import_name = tokens[0].value;
        start += 1;
    } else {
        utils.printSrcLineError("unexpected symbols on line", self.program.file_name, self.program.content, tokens[0].line);
        return ParserError.ParsingFailed;
    }
    if (import_name) |imp| {
        if (self.program.shared_libs.items.len == 0) {
            try self.program.shared_libs.append(utils.alloc, &.{});
        }
        try self.program.shared_libs.append(utils.alloc, imp);
        self.program.flags.has_shared = true;
    }
    const shared_index: u16 = if (import_name) |_| @truncate(self.program.shared_libs.items.len - 1) else 0;
    var expect_symbol = true;
    for (tokens[start..], start..) |token, i| {
        if (expect_symbol) {
            if (token.type == .Ident) {
                const in_import = try self.program.imports.getOrPut(token.value);
                if (in_import.found_existing) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in this block", .{token.value}, self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                } else if (self.program.data_vars.contains(token.value)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in data block", .{token.value}, self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                } else if (self.program.funcs.contains(token.value)) {
                    utils.printSrcLineErrorFmt("label '{s}' already defined in code block", .{token.value}, self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                } else {
                    in_import.value_ptr.* = shared_index;
                }
                expect_symbol = false;
            } else if (token.type.isBlockDecl()) {
                return i;
            } else {
                utils.printSrcLineError("expected label name", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
        } else {
            if (token.type == .Comma or token.type == .NewLine) {
                expect_symbol = true;
            } else if (token.type.isBlockDecl()) {
                return i;
            } else {
                utils.printSrcLineError("expected ','", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            }
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
                    utils.printSrcLineError("entry label already defined in this file", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
            },
            .data => {
                if (!self.program.flags.has_data) {
                    const len = try self.parseDataBlock(self.program.tokens.items[i + 1 ..]);
                    i += len;
                    if (self.program.data_block.instr.items.len > 0) {
                        self.program.flags.has_data = true;
                    }
                } else {
                    utils.printSrcLineError("data block already present in this file", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
            },
            .code => {
                if (!self.program.flags.has_code) {
                    const len = try self.parseCodeBlock(self.program.tokens.items[i + 1 ..]);
                    i += len;
                    if (self.program.code_block.instr.items.len > 0) {
                        self.program.flags.has_code = true;
                    }
                } else {
                    utils.printSrcLineError("code block already present in this file", self.program.file_name, self.program.content, token.line);
                    return ParserError.ParsingFailed;
                }
            },
            .import => {
                const len = try self.parseImportBlock(self.program.tokens.items[i + 1 ..]);
                i += len;
            },
            .NewLine => {},
            else => {
                utils.printSrcLineError("expected block declaration", self.program.file_name, self.program.content, token.line);
                return ParserError.ParsingFailed;
            },
        }
    }
}
