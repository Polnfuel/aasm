const std = @import("std");
const utils = @import("utils");
const Lexer = @import("Lexer");
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;
const Program = @import("Program");
const Immediate = Program.Immediate;
const Parser = @import("Parser");
const ParserError = Parser.ParserError;

const Eval = @This();

const TokenIndex = u16;
const NodeIndex = u16;
const LargeInt = i128;

pub const Ast = struct {
    nodes: std.ArrayList(Node) = .empty,
    root: NodeIndex = std.math.maxInt(u16),

    pub const Node = struct {
        op: NodeType,
        data: NodeData,

        const NodeType = enum(u8) {
            term,
            sizeof,
            alignof,

            add_unary,
            sub_unary,
            not,

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

            field_access,

            fn group(op: NodeType) u8 {
                if (@backingInt(op) < @backingInt(NodeType.add_unary)) return 0 else if (@backingInt(op) < @backingInt(NodeType.mult)) return 1 else return 2;
            }
        };

        const NodeData = union {
            // types: term, sizeof, alignof
            // this might be NumberLiteral, StringLiteral, Ident,
            token: TokenIndex, // 2

            // types: add_unary, sub_unary, not,
            unary: struct {
                op_token: TokenIndex,
                node: NodeIndex,
            }, // 4

            // types: mult, div, rem, add_binary, sub_binary, shift_left, shift_right, bitwise_and, bitwise_xor, bitwise_or, field_access
            binary: struct {
                op_token: TokenIndex,
                lhs: NodeIndex,
                rhs: NodeIndex,
            }, // 6
        }; // 6

    }; // 8

    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const ind: NodeIndex = @truncate(self.nodes.items.len);
        try self.nodes.append(utils.alloc, node);
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
        });
        return ind;
    }
};

fn printNode(self: *Eval, node_ind: NodeIndex, depth: usize) void {
    const node = self.ast.nodes.items[node_ind];
    for (0..depth) |_| {
        std.debug.print("  ", .{});
    }
    std.debug.print("{t} ", .{node.op});
    switch (node.op) {
        .term, .sizeof, .alignof => {
            const token = self.parser.program.tokens.items[node.data.token];
            std.debug.print("{s}\n", .{utils.stringValue(if (token.val_ind < std.math.maxInt(u16) - 5) token.val_ind else 0)});
        },
        .add_unary, .sub_unary, .not => {
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
    self.printNode(self.ast.root, 0);
}

fn evaluateNode(self: *Eval, node: Ast.Node) !LargeInt {
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
                        utils.printSrcLineColErrorFmt("value \"{s}\"s doesn't fit in 128 bit", .{string}, self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }
                },
                .Ident => {
                    if (self.parser.program.constants.get(token.val_ind)) |imm| {
                        return largeIntFromImm(imm);
                    } else {
                        utils.printSrcLineColError("expected constant name", self.parser.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }
                },
                else => unreachable,
            }
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
            }
            unreachable;
        },
        .field_access => {
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
        .add_unary, .sub_unary, .not => {
            const child = try self.evaluateNode(self.ast.nodes.items[node.data.unary.node]);
            switch (node.op) {
                .add_unary => return child,
                .sub_unary => return std.math.negate(child) catch {
                    const token = self.parser.program.tokens.items[node.data.unary.op_token];
                    utils.printSrcLineColError("negation will not fit in 128 bit", self.parser.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                },
                .not => return ~child,
                else => unreachable,
            }
        },
        else => {
            const lhs = try self.evaluateNode(self.ast.nodes.items[node.data.binary.lhs]);
            const rhs = try self.evaluateNode(self.ast.nodes.items[node.data.binary.rhs]);
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

fn evaluate(self: *Eval) !Immediate {
    const large = try self.evaluateNode(self.ast.nodes.items[self.ast.root]);
    var imm: Immediate = undefined;
    if (large < 0) {
        imm.bits = @bitCast(std.math.cast(i64, large) orelse {
            const tok_ind = switch (Ast.Node.NodeType.group(self.ast.nodes.items[self.ast.root].op)) {
                0 => self.ast.nodes.items[self.ast.root].data.token,
                1 => self.ast.nodes.items[self.ast.root].data.unary.op_token,
                2 => self.ast.nodes.items[self.ast.root].data.binary.op_token,
                else => unreachable,
            };
            const token = self.parser.program.tokens.items[tok_ind];
            utils.printSrcLineColError("result of expression doesn't fit in 64 bits", self.parser.program, token.line, token.col);
            return ParserError.ParsingFailed;
        });
        imm.sign = .i;
    } else {
        imm.bits = @bitCast(std.math.cast(u64, large) orelse {
            const tok_ind = switch (Ast.Node.NodeType.group(self.ast.nodes.items[self.ast.root].op)) {
                0 => self.ast.nodes.items[self.ast.root].data.token,
                1 => self.ast.nodes.items[self.ast.root].data.unary.op_token,
                2 => self.ast.nodes.items[self.ast.root].data.binary.op_token,
                else => unreachable,
            };
            const token = self.parser.program.tokens.items[tok_ind];
            utils.printSrcLineColError("result of expression doesn't fit in 64 bits", self.parser.program, token.line, token.col);
            return ParserError.ParsingFailed;
        });
        imm.sign = .u;
    }
    return imm;
}

ast: Ast,
parser: *Parser,

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

fn parseTerm(self: *Eval) ParserError!NodeIndex {
    var token = self.parser.consume();
    switch (token.type) {
        .NumberLiteral, .HexNumLiteral, .BinNumLiteral, .StringLiteral => {
            return try self.ast.addNode(.{ .op = .term, .data = .{ .token = @truncate(self.parser.pos - 1) } });
        },
        .Ident => {
            const left_ind: TokenIndex = @truncate(self.parser.pos - 1);
            const left_token = token;
            if (self.parser.peek().type == .Dot) {
                const dot_token: TokenIndex = @truncate(self.parser.pos);
                self.parser.consumeVoid();

                token = self.parser.peek();
                if (token.type == .Ident) {
                    const is_enum = if (self.parser.program.types.get(left_token.val_ind)) |ty| ty == .@"enum" else false;
                    if (!is_enum) {
                        utils.printSrcLineColError("only enum type fields can be accessed in constant expression", self.parser.program, left_token.line, left_token.col);
                        return ParserError.ParsingFailed;
                    }
                    const right_ind: TokenIndex = @truncate(self.parser.pos);
                    self.parser.consumeVoid();
                    return try self.ast.addNode(.{ .op = .field_access, .data = .{ .binary = .{
                        .op_token = dot_token,
                        .lhs = try self.ast.addNode(.{ .op = .term, .data = .{ .token = left_ind } }),
                        .rhs = try self.ast.addNode(.{ .op = .term, .data = .{ .token = right_ind } }),
                    } } });
                } else {
                    utils.printSrcLineColError("expected identifier", self.parser.program, token.line, token.col);
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
            return expr;
        },
        else => {
            utils.printSrcLineColError("unexpected token in constant expression", self.parser.program, token.line, token.col);
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
            .Tilde => .not,
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
    return try self.parseBitwiseOr();
}

pub fn parse(parser: *Parser) ParserError!Immediate {
    var eval = Eval{ .ast = Ast{}, .parser = parser };
    defer eval.ast.nodes.deinit(utils.alloc);

    const root = try eval.parseConstExpr();
    eval.ast.root = root;
    // eval.printAst();
    const result = try eval.evaluate();
    return result;
}
