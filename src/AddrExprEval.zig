const std = @import("std");
const utils = @import("utils");
const Lexer = @import("Lexer");
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;
const Program = @import("Program");
const Label = Program.Label;
const MemSize = Program.MemSize;
const Register = Program.Register;
const Immediate = Program.Immediate;
const MemOperand = Program.MemOperand;
const Displacement = Program.Displacement;
const Parser = @import("Parser");

const ParserError = Parser.ParserError;
const ExtendedError = ParserError || error{RegEncountered};

const Eval = @This();

const TokenIndex = u16;
const NodeIndex = u16;
const LargeInt = i128;

const Ast = struct {
    nodes: std.ArrayList(Node) = .empty,
    root: NodeIndex = std.math.maxInt(u16),
    cur_depth: i16 = -1,

    pub const Node = struct {
        op: NodeType,
        data: NodeData,
        depth: i16 = 0,

        const NodeType = enum(u8) {
            term,
            reg,
            sizeof,
            alignof,

            add_unary,
            sub_unary,
            bitwise_not,

            mult,
            div,
            rem,
            add_binary,
            sub_binary,
            shift_left,
            shift_right,
            bitwise_and,
            bitwise_xor,
            bitwise_or,

            enum_access,
            field,

            fn group(op: NodeType) u8 {
                if (@backingInt(op) < @backingInt(NodeType.add_unary)) return 0 else if (@backingInt(op) < @backingInt(NodeType.mult)) return 1 else return 2;
            }
        };

        const NodeData = union {
            // types: term, reg, sizeof, alignof
            // this might be NumberLiteral, StringLiteral, Ident,
            token: TokenIndex, // 2

            // types: add_unary, sub_unary, bitwise_not,
            unary: struct {
                op_token: TokenIndex,
                node: NodeIndex,
            }, // 4

            // types: mult, div, rem, add_binary, sub_binary, shift_left, shift_right, bitwise_and, bitwise_xor, bitwise_or, enum_access
            binary: struct {
                op_token: TokenIndex,
                lhs: NodeIndex,
                rhs: NodeIndex,
            }, // 6
        }; // 6

    }; // 8

    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const ind: NodeIndex = @truncate(self.nodes.items.len);
        try self.nodes.append(utils.alloc, .{ .op = node.op, .data = node.data, .depth = self.cur_depth });
        return ind;
    }

    pub fn addBinary(self: *Ast, op: TokenType, op_token: TokenIndex, left: NodeIndex, right: NodeIndex) !NodeIndex {
        const ind: NodeIndex = @truncate(self.nodes.items.len);
        try self.nodes.append(utils.alloc, .{
            .op = switch (op) {
                .Plus => .add_binary,
                .Minus => .sub_binary,
                .Asteriks => .mult,
                .Slash => .div,
                .Percent => .rem,
                .LessThan2 => .shift_left,
                .MoreThan2 => .shift_right,
                .Ampersand => .bitwise_and,
                .Hat => .bitwise_xor,
                .Pipe => .bitwise_or,
                else => unreachable,
            },
            .data = .{
                .binary = .{ .op_token = op_token, .lhs = left, .rhs = right },
            },
            .depth = self.cur_depth,
        });
        return ind;
    }
};

const Sign = enum {
    plus,
    minus,

    fn invert(self: Sign) Sign {
        return if (self == .minus) .plus else .minus;
    }
};

ast: Ast,
parser: *Parser,
line: u16 = 0,
comps: std.ArrayList(LargeInt) = .empty,
memop: *MemOperand,

// Printing

fn printNode(self: *Eval, node_ind: NodeIndex, depth: usize) void {
    const node = self.ast.nodes.items[node_ind];
    for (0..depth) |_| {
        std.debug.print("  ", .{});
    }
    std.debug.print("{t} ", .{node.op});
    switch (node.op) {
        .term, .sizeof, .alignof => {
            const token = self.parser.program.tokens.items[node.data.token];
            std.debug.print("{s} {d}\n", .{ utils.stringValue(if (token.val_ind < std.math.maxInt(u16) - 5) token.val_ind else 0), node.depth });
        },
        .reg => {
            const token = self.parser.program.tokens.items[node.data.token];
            std.debug.print("{t} {d}\n", .{ token.type, node.depth });
        },
        .add_unary, .sub_unary, .bitwise_not => {
            std.debug.print("\n", .{});
            self.printNode(node.data.unary.node, depth + 1);
        },
        else => {
            std.debug.print("\n", .{});
            self.printNode(node.data.binary.lhs, depth + 1);
            self.printNode(node.data.binary.rhs, depth + 1);
        },
    }
}

fn printAst(self: *Eval) void {
    std.debug.print("\n", .{});
    self.printNode(self.ast.root, 0);
}

// Checking

fn checkScale(self: *const Parser, scale: LargeInt, token: Token) ParserError!u8 {
    switch (scale) {
        1, 2, 4, 8 => {
            return @truncate(@abs(scale));
        },
        else => {
            utils.printSrcLineColError("invalid scale", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        },
    }
}

fn mergeDisplacement(self: *Eval) ParserError!void {
    var offset: LargeInt = 0;

    for (self.comps.items) |comp| {
        offset = std.math.add(LargeInt, offset, comp) catch {
            utils.printSrcLineError("displacement value overflowed 128 bit", self.parser.program, self.line);
            return ParserError.ParsingFailed;
        };
    }

    self.memop.disp = std.math.cast(i32, offset) orelse @bitCast(std.math.cast(u32, offset) orelse {
        utils.printSrcLineErrorFmt("displacement value {d} doesn't fit in 32 bits", .{offset}, self.parser.program, self.line);
        return ParserError.ParsingFailed;
    });
}

// Evaluation

/// Evaluates offset of label field access relative to the start of label.
fn evaluateLabelAccess(self: *Eval, node: Ast.Node) ParserError!u64 {
    var offset: u64 = 0;
    var parent_node: Ast.Node = node; // op: field, lhs = term name2, rhs = term fld4
    const label_node = self.ast.nodes.items[parent_node.data.binary.lhs]; // term name2
    const label_token = self.parser.program.tokens.items[label_node.data.token]; // name2
    const label = label_token.val_ind; // name2
    var parent_type: Program.Type = self.parser.program.types.get(self.parser.program.data_vars.get(label).?.type).?;
    while (parent_node.op == .field) {
        const child_node: Ast.Node = self.ast.nodes.items[parent_node.data.binary.rhs];
        const child_token = switch (child_node.op) {
            .term => self.parser.program.tokens.items[child_node.data.token],
            .field => self.parser.program.tokens.items[self.ast.nodes.items[child_node.data.binary.lhs].data.token],
            else => unreachable,
        };
        switch (child_token.type) {
            .Ident => {
                switch (parent_type) {
                    .@"struct" => |s| {
                        const child_label = child_token.val_ind;
                        const fields = self.parser.program.types.structs_fields.items[s.fields].items;
                        const field = self.parser.program.types.getStructField(fields, child_label) orelse {
                            utils.printSrcLineColError("struct '{s}' doesn't contain '{s}' field", self.parser.program, child_token.line, child_token.col);
                            return ParserError.ParsingFailed;
                        };
                        offset += field.offset;
                        parent_type = self.parser.program.types.get(field.type).?;
                        parent_node = child_node;
                    },
                    else => {
                        // TODO: print type name
                        utils.printSrcLineColError("type '{s}' doesn't contain '{s}' field", self.parser.program, child_token.line, child_token.col);
                        return ParserError.ParsingFailed;
                    },
                }
            },
            .NumberLiteral => {
                switch (parent_type) {
                    .array => |a| {
                        const len = a.len;
                        const len_label = utils.stringValue(child_token.val_ind);
                        const index = std.fmt.parseInt(u64, len_label, 0) catch {
                            utils.printSrcLineColErrorFmt("value {s} doesn't fit in 64 bit", .{len_label}, self.parser.program, child_token.line, child_token.col);
                            return ParserError.ParsingFailed;
                        };
                        if (index >= len) {
                            utils.printSrcLineColErrorFmt("index {d} outside of the array bounds [0..{d}]", .{ index, len }, self.parser.program, child_token.line, child_token.col);
                            return ParserError.ParsingFailed;
                        }
                        parent_type = self.parser.program.types.get(a.type).?;
                        offset += parent_type.size(self.parser.program) * index;
                        parent_node = child_node;
                    },
                    else => {
                        // TODO: print type name
                        utils.printSrcLineColError("type '{s}' is not indexible", self.parser.program, child_token.line, child_token.col);
                        return ParserError.ParsingFailed;
                    },
                }
            },
            else => unreachable,
        }
    }
    return offset;
}

fn addLabelComponent(self: *Eval, node: Ast.Node) ParserError!void {
    switch (node.op) {
        .term => {
            const label_token = self.parser.program.tokens.items[node.data.token];
            const label = label_token.val_ind;
            if (self.memop.label > 0) {
                utils.printSrcLineColError("cannot have two labels in address expression", self.parser.program, label_token.line, label_token.col);
                return ParserError.ParsingFailed;
            }
            self.memop.label = label;
        },
        .field => {
            const label_node = self.ast.nodes.items[node.data.binary.lhs];
            const label_token = self.parser.program.tokens.items[label_node.data.token];
            const label = label_token.val_ind;
            const offset = try self.evaluateLabelAccess(node);
            if (self.memop.label > 0) {
                utils.printSrcLineColError("cannot have two labels in address expression", self.parser.program, label_token.line, label_token.col);
                return ParserError.ParsingFailed;
            }
            self.memop.label = label;
            try self.comps.append(utils.alloc, offset);
        },
        else => unreachable,
    }
}

/// Evaluates node value if it's a constant expression or returns null
/// if it contains registers or label.
fn evaluateConstNode(self: *Eval, node: Ast.Node) ParserError!?LargeInt {
    switch (node.op) {
        .term => {
            const token = self.parser.program.tokens.items[node.data.token];
            switch (token.type) {
                .NumberLiteral, .HexNumLiteral, .BinNumLiteral => {
                    const value: LargeInt = try largeIntFromToken(self.parser.program, token);
                    return value;
                },
                .StringLiteral => {
                    const string = utils.stringValue(token.val_ind);
                    var value: [16]u8 = @splat(0);
                    if (string.len <= 16) {
                        @memcpy(@as([*]u8, @ptrCast(&value)), string);
                        return @bitCast(value);
                    } else {
                        utils.printSrcLineColErrorFmt("value {s} doesn't fit in 128 bit", .{string}, self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }
                },
                .Ident => {
                    if (self.parser.program.constants.get(token.val_ind)) |imm| {
                        return largeIntFromImm(imm);
                    } else {
                        if (node.depth > 0) {
                            utils.printSrcLineColError("nested label in expression", self.parser.program, token.line, token.col);
                            return ParserError.ParsingFailed;
                        }
                        return null;
                    }
                },
                else => unreachable,
            }
        },
        .reg => {
            if (node.depth > 0) {
                const token = self.parser.program.tokens.items[node.data.token];
                utils.printSrcLineColError("nested register in expression", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            return null;
        },
        .field => {
            if (node.depth > 0) {
                const token = self.parser.program.tokens.items[node.data.token];
                utils.printSrcLineColError("nested label in expression", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            return null;
        },
        .sizeof, .alignof => {
            const token = self.parser.program.tokens.items[node.data.token];
            if (token.type.isDataDirective()) {
                return Parser.dataSize(token.type);
            } else if (token.type == .Ident) {
                const user_type = self.parser.program.types.get(token.val_ind).?;
                switch (user_type) {
                    .@"enum" => |en| {
                        return en.data_size;
                    },
                    .@"struct" => |str| {
                        if (node.op == .sizeof) return str.size;
                        return Program.bytesFromAlignment(str.alignment);
                    },
                    else => unreachable,
                }
            } else unreachable;
        },
        .enum_access => {
            const lhs_ind = self.ast.nodes.items[node.data.binary.lhs].data.token;
            const rhs_ind = self.ast.nodes.items[node.data.binary.rhs].data.token;
            const lhs_token = self.parser.program.tokens.items[lhs_ind];
            const rhs_token = self.parser.program.tokens.items[rhs_ind];
            const ty = self.parser.program.types.get(lhs_token.val_ind).?;
            std.debug.assert(ty == .@"enum");
            const fields = self.parser.program.types.enums_fields.items[ty.@"enum".fields_start..ty.@"enum".fields_end];
            const field = self.parser.program.types.getEnumField(fields, rhs_token.val_ind) orelse {
                utils.printSrcLineColErrorFmt("enum '{s}' doesn't contain '{s}' field", .{ utils.stringValue(lhs_token.val_ind), utils.stringValue(rhs_token.val_ind) }, self.parser.program, rhs_token.line, rhs_token.col);
                return ParserError.ParsingFailed;
            };
            return field.value;
        },
        .add_unary, .sub_unary, .bitwise_not => {
            const child = try self.evaluateConstNode(self.ast.nodes.items[node.data.unary.node]) orelse return null;
            switch (node.op) {
                .add_unary => return child,
                .sub_unary => return std.math.negate(child) catch {
                    const token = self.parser.program.tokens.items[node.data.unary.op_token];
                    utils.printSrcLineColError("negation will not fit in 128 bit", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                },
                .bitwise_not => return ~child,
                else => unreachable,
            }
        },
        else => {
            const lhs = try self.evaluateConstNode(self.ast.nodes.items[node.data.binary.lhs]) orelse return null;
            const rhs = try self.evaluateConstNode(self.ast.nodes.items[node.data.binary.rhs]) orelse return null;
            switch (node.op) {
                .add_binary => return std.math.add(i128, lhs, rhs) catch {
                    const token = self.parser.program.tokens.items[node.data.binary.op_token];
                    utils.printSrcLineColError("addition will not fit in 128 bit", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                },
                .sub_binary => return std.math.sub(i128, lhs, rhs) catch {
                    const token = self.parser.program.tokens.items[node.data.binary.op_token];
                    utils.printSrcLineColError("subtraction will not fit in 128 bit", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                },
                .mult => return std.math.mul(i128, lhs, rhs) catch {
                    const token = self.parser.program.tokens.items[node.data.binary.op_token];
                    utils.printSrcLineColError("multiplication will not fit in 128 bit", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                },
                .div => return std.math.divFloor(i128, lhs, rhs) catch |err| switch (err) {
                    error.DivisionByZero => {
                        const token = self.parser.program.tokens.items[node.data.binary.op_token];
                        utils.printSrcLineColError("division by zero", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                    else => {
                        const token = self.parser.program.tokens.items[node.data.binary.op_token];
                        utils.printSrcLineColError("division will not fit in 128 bit", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                },
                .rem => return std.math.rem(i128, lhs, rhs) catch |err| switch (err) {
                    error.DivisionByZero => {
                        const token = self.parser.program.tokens.items[node.data.binary.op_token];
                        utils.printSrcLineColError("division by zero", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                    else => {
                        const token = self.parser.program.tokens.items[node.data.binary.op_token];
                        utils.printSrcLineColError("negative denominator", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                },
                .shift_left => return std.math.shl(i128, lhs, rhs),
                .shift_right => return std.math.shr(i128, lhs, rhs),
                .bitwise_and => return lhs & rhs,
                .bitwise_xor => return lhs ^ rhs,
                .bitwise_or => return lhs | rhs,
                else => unreachable,
            }
        },
    }
    unreachable;
}

fn evaluateNode(self: *Eval, node: Ast.Node, sign: Sign) ParserError!void {
    switch (node.op) {
        .term => {
            if (try self.evaluateConstNode(node)) |value| {
                try self.comps.append(utils.alloc, value * @as(i128, if (sign == .minus) -1 else 1));
            } else {
                if (sign == .minus) {
                    const token = self.parser.program.tokens.items[node.data.token];
                    utils.printSrcLineColError("label cannot follow minus sign", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
                try self.addLabelComponent(node);
            }
        },
        .field => {
            if (sign == .minus) {
                const token = self.parser.program.tokens.items[node.data.token];
                utils.printSrcLineColError("label cannot follow minus sign", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            try self.addLabelComponent(node);
        },
        .reg => {
            const token = self.parser.program.tokens.items[node.data.token];
            if (sign == .minus) {
                utils.printSrcLineColError("register cannot follow minus sign", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            if (self.memop.base.name == .reg0) {
                self.memop.base = Register.init(token.type);
            } else if (self.memop.index.name == .reg0) {
                self.memop.index = Register.init(token.type);
            } else {
                utils.printSrcLineColError("unexpected register", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        },
        .sizeof, .alignof, .enum_access => {
            const value = (try self.evaluateConstNode(node)).?;
            try self.comps.append(utils.alloc, value);
        },
        .add_unary, .sub_unary, .bitwise_not => {
            const child_node = self.ast.nodes.items[node.data.unary.node];
            if (try self.evaluateConstNode(child_node)) |child| {
                switch (node.op) {
                    .add_unary => try self.comps.append(utils.alloc, child),
                    .sub_unary => try self.comps.append(utils.alloc, std.math.negate(child) catch {
                        const token = self.parser.program.tokens.items[node.data.unary.op_token];
                        utils.printSrcLineColError("negation will not fit in 128 bit", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }),
                    .bitwise_not => try self.comps.append(utils.alloc, ~child),
                    else => unreachable,
                }
            } else {
                if (node.op == .bitwise_not) {
                    const token = self.parser.program.tokens.items[node.data.unary.op_token];
                    utils.printSrcLineColError("bitwise_not operation on non-constant expression", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
                try self.evaluateNode(child_node, if (node.op == .sub_unary) sign.invert() else sign);
            }
        },
        .add_binary => {
            try self.evaluateNode(self.ast.nodes.items[node.data.binary.lhs], sign);
            try self.evaluateNode(self.ast.nodes.items[node.data.binary.rhs], sign);
        },
        .sub_binary => {
            try self.evaluateNode(self.ast.nodes.items[node.data.binary.lhs], sign);
            try self.evaluateNode(self.ast.nodes.items[node.data.binary.rhs], sign.invert());
        },
        .mult => {
            const left = self.ast.nodes.items[node.data.binary.lhs];
            const right = self.ast.nodes.items[node.data.binary.rhs];
            const token = self.parser.program.tokens.items[node.data.binary.op_token];
            if (try self.evaluateConstNode(left)) |lhs| {
                if (try self.evaluateConstNode(right)) |rhs| {
                    // const * const
                    try self.comps.append(utils.alloc, std.math.mul(i128, lhs, rhs) catch {
                        utils.printSrcLineColError("multiplication will not fit in 128 bit", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    });
                } else if (right.op == .reg) {
                    // const * reg
                    const reg_token = self.parser.program.tokens.items[right.data.token];
                    if (self.memop.index.name != .reg0) {
                        utils.printSrcLineColError("unexpected scaled register", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }
                    self.memop.index = Register.init(reg_token.type);
                    self.memop.scale = try checkScale(self.parser, if (sign == .minus) lhs * -1 else lhs, token);
                } else {
                    // const * label
                    utils.printSrcLineColError("multiplication with label is forbidden", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            } else if (left.op == .reg) {
                if (try self.evaluateConstNode(right)) |rhs| {
                    // reg * const
                    const reg_token = self.parser.program.tokens.items[left.data.token];
                    if (sign == .minus) {
                        utils.printSrcLineColError("register cannot follow minus sign", self.parser.program, reg_token.line, reg_token.col);
                        return ParserError.ParsingFailed;
                    } else if (self.memop.index.name != .reg0) {
                        utils.printSrcLineColError("unexpected scaled register", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }
                    self.memop.index = Register.init(reg_token.type);
                    self.memop.scale = try checkScale(self.parser, rhs, token);
                } else if (right.op == .reg) {
                    // reg * reg
                    utils.printSrcLineColError("registers multiplication is forbidden", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                } else {
                    // reg * label
                    utils.printSrcLineColError("multiplication with label is forbidden", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            } else {
                // label * any
                utils.printSrcLineColError("multiplication with label is forbidden", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        },
        else => {
            const token = self.parser.program.tokens.items[node.data.binary.op_token];
            const lhs = (try self.evaluateConstNode(self.ast.nodes.items[node.data.binary.lhs])) orelse {
                utils.printSrcLineColError("expected constant expression as lhs", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            };
            const rhs = (try self.evaluateConstNode(self.ast.nodes.items[node.data.binary.rhs])) orelse {
                utils.printSrcLineColError("expected constant expression as rhs", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            };
            const result: LargeInt = switch (node.op) {
                .div => std.math.divFloor(LargeInt, lhs, rhs) catch |err| switch (err) {
                    error.DivisionByZero => {
                        utils.printSrcLineColError("division by zero", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                    else => {
                        utils.printSrcLineColError("division will not fit in 128 bit", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                },
                .rem => std.math.rem(LargeInt, lhs, rhs) catch |err| switch (err) {
                    error.DivisionByZero => {
                        utils.printSrcLineColError("division by zero", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                    else => {
                        utils.printSrcLineColError("negative denominator", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    },
                },
                .shift_left => std.math.shl(i128, lhs, rhs),
                .shift_right => std.math.shr(i128, lhs, rhs),
                .bitwise_and => lhs & rhs,
                .bitwise_xor => lhs ^ rhs,
                .bitwise_or => lhs | rhs,
                else => unreachable,
            };
            try self.comps.append(utils.alloc, result);
        },
    }
}

fn split(self: *Eval) ParserError!void {
    try self.evaluateNode(self.ast.nodes.items[self.ast.root], .plus);
}

fn largeIntFromToken(program: *const Program, token: Token) ParserError!LargeInt {
    const label = utils.stringValue(token.val_ind);
    const value = std.fmt.parseInt(LargeInt, label, 0) catch {
        utils.printSrcLineColErrorFmt("value {s} doesn't fit in 128 bit", .{label}, program, token.line, token.col);
        return ParserError.ParsingFailed;
    };
    return value;
}

fn largeIntFromImm(imm: Immediate) LargeInt {
    switch (imm.sign) {
        .u => return imm.bits,
        .i => return -@as(i128, imm.bits),
    }
}

// Parsing

fn parseFieldAccess(self: *Eval, parent: NodeIndex, dot_token: TokenIndex) ParserError!NodeIndex {
    var token = self.parser.peek();
    if (token.type == .Ident or token.type == .NumberLiteral) {
        var child: NodeIndex = try self.ast.addNode(.{ .op = .term, .data = .{ .token = @truncate(self.parser.getPos()) } });
        self.parser.consumeVoid();
        token = self.parser.peek();
        if (token.type == .Dot) {
            const dot: TokenIndex = @truncate(self.parser.getPos());
            self.parser.consumeVoid();
            child = try self.parseFieldAccess(child, dot);
        }
        const field = try self.ast.addNode(.{ .op = .field, .data = .{ .binary = .{
            .op_token = dot_token,
            .lhs = parent,
            .rhs = child,
        } } });
        return field;
    } else {
        utils.printSrcLineColError("expected field name or index", self.parser.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
}

fn parseTerm(self: *Eval) ParserError!NodeIndex {
    var token = self.parser.consume();
    if (token.type.isReg()) {
        return try self.ast.addNode(.{ .op = .reg, .data = .{ .token = @truncate(self.parser.pos - 1) } });
    }
    switch (token.type) {
        .NumberLiteral, .HexNumLiteral, .BinNumLiteral, .StringLiteral => {
            return try self.ast.addNode(.{ .op = .term, .data = .{ .token = @truncate(self.parser.pos - 1) } });
        },
        .Ident => {
            const left_ind: TokenIndex = @truncate(self.parser.pos - 1);
            const left_token = token;
            const label = left_token.val_ind;
            if (self.parser.peek().type == .Dot) {
                const dot_token: TokenIndex = @truncate(self.parser.pos);
                token = self.parser.consume(); // .
                if (self.parser.program.data_vars.contains(label)) {
                    const variable_node = try self.ast.addNode(.{ .op = .term, .data = .{ .token = left_ind } });
                    return try self.parseFieldAccess(variable_node, dot_token);
                } else if (if (self.parser.program.types.get(left_token.val_ind)) |ty| ty == .@"enum" else false) {
                    token = self.parser.peek();
                    if (token.type == .Ident) {
                        const right_ind: TokenIndex = @truncate(self.parser.pos);
                        self.parser.consumeVoid();
                        return try self.ast.addNode(.{ .op = .enum_access, .data = .{ .binary = .{
                            .op_token = dot_token,
                            .lhs = try self.ast.addNode(.{ .op = .term, .data = .{ .token = left_ind } }),
                            .rhs = try self.ast.addNode(.{ .op = .term, .data = .{ .token = right_ind } }),
                        } } });
                    } else {
                        utils.printSrcLineColError("expected enum field", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }
                } else {
                    utils.printSrcLineColError("only enum type or data variable fields can be accessed in address expression", self.parser.program, left_token.line, left_token.col);
                    return ParserError.ParsingFailed;
                }
            } else {
                return try self.ast.addNode(.{ .op = .term, .data = .{ .token = left_ind } });
            }
        },
        .sizeof, .alignof => {
            const op = token.type;
            token = self.parser.consume();
            try self.parser.expectToken(token, .OpenParen);
            token = self.parser.consume();
            if (token.type == .Ident and self.parser.program.types.contains(token.val_ind) or token.type.isDataDirective()) {
                token = self.parser.consume();
                try self.parser.expectToken(token, .CloseParen);
                return try self.ast.addNode(.{ .op = if (op == .sizeof) .sizeof else .alignof, .data = .{ .token = @truncate(self.parser.pos - 2) } });
            } else {
                utils.printSrcLineColError("expected type name", self.parser.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        },
        .OpenParen => {
            const expr = try self.parseConstExpr();
            token = self.parser.consume();
            try self.parser.expectToken(token, .CloseParen);
            self.ast.cur_depth -= 1;
            return expr;
        },
        else => {
            utils.printSrcLineColError("unexpected token in address expression", self.parser.program, token.line, token.col);
            return ParserError.ParsingFailed;
        },
    }
}

fn parseUnary(self: *Eval) ParserError!NodeIndex {
    const op_type = self.parser.peekType();
    if (op_type == .Plus or op_type == .Minus or op_type == .Tilde) {
        const op_token: TokenIndex = @truncate(self.parser.pos);
        self.parser.consumeVoid();
        const new = try self.parseUnary();
        return try self.ast.addNode(.{ .op = switch (op_type) {
            .Plus => .add_unary,
            .Minus => .sub_unary,
            .Tilde => .bitwise_not,
            else => unreachable,
        }, .data = .{ .unary = .{ .op_token = op_token, .node = new } } });
    } else {
        return try self.parseTerm();
    }
}

fn parseMultiplicative(self: *Eval) ParserError!NodeIndex {
    var left = try self.parseUnary();
    while (self.parser.peekType() == .Asteriks or self.parser.peekType() == .Slash or self.parser.peekType() == .Percent) {
        const op_token: TokenIndex = @truncate(self.parser.pos);
        const op_type = self.parser.peekType();
        self.parser.consumeVoid();
        const right = try self.parseUnary();
        left = try self.ast.addBinary(op_type, op_token, left, right);
    }
    return left;
}

fn parseAdditive(self: *Eval) ParserError!NodeIndex {
    var left = try self.parseMultiplicative();
    while (self.parser.peekType() == .Plus or self.parser.peekType() == .Minus) {
        const op_token: TokenIndex = @truncate(self.parser.pos);
        const op_type = self.parser.peekType();
        self.parser.consumeVoid();
        const right = try self.parseMultiplicative();
        left = try self.ast.addBinary(op_type, op_token, left, right);
    }
    return left;
}

fn parseShift(self: *Eval) ParserError!NodeIndex {
    var left = try self.parseAdditive();
    while (self.parser.peekType() == .LessThan2 or self.parser.peekType() == .MoreThan2) {
        const op_token: TokenIndex = @truncate(self.parser.pos);
        const op_type = self.parser.peekType();
        self.parser.consumeVoid();
        const right = try self.parseAdditive();
        left = try self.ast.addBinary(op_type, op_token, left, right);
    }
    return left;
}

fn parseBitwiseAnd(self: *Eval) ParserError!NodeIndex {
    var left = try self.parseShift();
    while (self.parser.peekType() == .Ampersand) {
        const op_token: TokenIndex = @truncate(self.parser.pos);
        self.parser.consumeVoid();
        const right = try self.parseShift();
        left = try self.ast.addBinary(.Ampersand, op_token, left, right);
    }
    return left;
}

fn parseBitwiseXor(self: *Eval) ParserError!NodeIndex {
    var left = try self.parseBitwiseAnd();
    while (self.parser.peekType() == .Hat) {
        const op_token: TokenIndex = @truncate(self.parser.pos);
        self.parser.consumeVoid();
        const right = try self.parseBitwiseAnd();
        left = try self.ast.addBinary(.Hat, op_token, left, right);
    }
    return left;
}

fn parseBitwiseOr(self: *Eval) ParserError!NodeIndex {
    var left = try self.parseBitwiseXor();
    while (self.parser.peekType() == .Pipe) {
        const op_token: TokenIndex = @truncate(self.parser.pos);
        self.parser.consumeVoid();
        const right = try self.parseBitwiseXor();
        left = try self.ast.addBinary(.Pipe, op_token, left, right);
    }
    return left;
}

fn parseConstExpr(self: *Eval) ParserError!NodeIndex {
    self.ast.cur_depth += 1;
    return try self.parseBitwiseOr();
}

pub fn parse(parser: *Parser, memop: *MemOperand) ParserError!void {
    var eval = Eval{ .ast = Ast{}, .parser = parser, .memop = memop };
    eval.line = eval.parser.peek().line;
    defer eval.ast.nodes.deinit(utils.alloc);
    defer eval.comps.deinit(utils.alloc);

    const root = try eval.parseConstExpr();
    eval.ast.root = root;
    // eval.printAst();

    try eval.split();
    try eval.mergeDisplacement();
}
