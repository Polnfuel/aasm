const std = @import("std");
const utils = @import("utils");

const Lexer = @import("Lexer");
const Token = Lexer.Token;
const TokenType = Lexer.TokenType;

const Program = @import("Program");
const MemSize = Program.MemSize;
const Label = Program.Label;
const Register = Program.Register;
const Immediate = Program.Immediate;
const MemOperand = Program.MemOperand;
const CodeOperand = Program.CodeOperand;
const CodeInstruction = Program.CodeInstruction;
const Alignment = Program.Alignment;
const TypeName = Program.TypeName;

const ConstExprEval = @import("ConstExprEval");
const AddrExprEval = @import("AddrExprEval");

const Parser = @This();

const BlockType = enum {
    import,
    @"const",
    types,
    bss,
    data,
    code,
};

program: *Program,
cur_func: Label,
tokens: []Token,
pos: usize,

pub const ParserError = error{ParsingFailed} || std.mem.Allocator.Error;

pub fn init(program: *Program) Parser {
    return Parser{
        .program = program,
        .cur_func = 0,
        .tokens = program.tokens.items,
        .pos = 0,
    };
}

pub fn peek(self: *Parser) Token {
    return self.tokens[self.pos];
}

pub fn peekType(self: *Parser) TokenType {
    return self.tokens[self.pos].type;
}

pub fn consumeVoid(self: *Parser) void {
    self.pos += 1;
}

pub fn revert(self: *Parser) void {
    self.pos -= 1;
}

pub fn getPos(self: *Parser) usize {
    return self.pos;
}

pub fn revertToPos(self: *Parser, pos: usize) void {
    self.pos = pos;
}

pub fn consume(self: *Parser) Token {
    const t = self.tokens[self.pos];
    self.pos += 1;
    return t;
}

pub fn consumeNewline(self: *Parser) void {
    if (self.peekType() == .NewLine) self.consumeVoid();
}

fn end(self: *Parser) bool {
    return self.pos == self.tokens.len or self.tokens[self.pos].type == .Eof;
}

pub fn dataSize(data_directive: TokenType) MemSize {
    return switch (data_directive) {
        .d8 => 1,
        .d16 => 2,
        .d32 => 4,
        .d64 => 8,
        .d128 => 16,
        else => unreachable,
    };
}

fn checkUniqueLabel(self: *const Parser, token: Token, block: BlockType) ParserError!void {
    const label = token.val_ind;
    const label_name = utils.stringValue(label);
    if (self.program.imports.contains(label)) {
        const block_name = if (block == .import) "this" else "@import";
        utils.printSrcLineColErrorFmt("label '{s}' already defined in {s} block", .{ label_name, block_name }, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    } else if (self.program.constants.contains(label)) {
        const block_name = if (block == .@"const") "this" else "@const";
        utils.printSrcLineColErrorFmt("label '{s}' already defined in {s} block", .{ label_name, block_name }, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    } else if (self.program.types.contains(label)) {
        const block_name = if (block == .types) "this" else "@types";
        utils.printSrcLineColErrorFmt("label '{s}' already defined in {s} block", .{ label_name, block_name }, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    } else if (self.program.data_vars.contains(label)) {
        const block_name = if (block == .bss or block == .data) "this" else "any data";
        utils.printSrcLineColErrorFmt("label '{s}' already defined in {s} block", .{ label_name, block_name }, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    } else if (self.program.funcs.contains(label)) {
        const block_name = if (block == .code) "this" else "@code";
        utils.printSrcLineColErrorFmt("label '{s}' already defined in {s} block", .{ label_name, block_name }, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
}

fn appendImmediateBytes(self: *const Parser, imm: Immediate, bytes: u8) std.mem.Allocator.Error!void {
    const array = std.mem.toBytes(imm.bits);
    try self.program.data_block.buffer.appendSlice(utils.alloc, array[0..bytes]);
}

fn insertImmediateBytes(self: *const Parser, imm: Immediate, bytes: u8, pos: u32) void {
    const array = std.mem.toBytes(imm.bits);
    @memcpy(self.program.data_block.buffer.items[pos .. pos + bytes], array[0..bytes]);
}

fn reserveTopDataBlock(self: *const Parser, size: usize) std.mem.Allocator.Error!void {
    try self.program.data_block.buffer.appendNTimes(utils.alloc, 0, size);
}

pub fn expectToken(self: *const Parser, token: Token, expected: TokenType) ParserError!void {
    if (token.type != expected) {
        const message = switch (expected) {
            .NewLine => "end of line",
            .Comma => ",",
            .OpenBrace => "{",
            .CloseBrace => "}",
            .Colon => ":",
            .OpenBracket => "[",
            .CloseBracket => "]",
            .Dot => ".",
            .OpenParen => "(",
            .CloseParen => ")",
            else => unreachable,
        };
        utils.printSrcLineColErrorFmt("expected {s}", .{message}, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
}

fn parseEntry(self: *Parser) ParserError!void {
    var token = self.consume();
    if (token.type == .Ident) {
        self.program.entry = token.val_ind;
    } else {
        utils.printSrcLineColError("expected label name", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    token = self.consume();
    try self.expectToken(token, .NewLine);
}

fn parseImportBlock(self: *Parser) ParserError!void {
    var import_name: ?Label = null;
    var token = self.peek();
    if (token.type == .StringLiteral) {
        import_name = token.val_ind;
        self.consumeVoid();
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
    while (!self.end()) {
        token = self.consume();
        if (expect_symbol) {
            if (token.type == .Ident) {
                try self.checkUniqueLabel(token, .import);
                const in_import = try self.program.imports.getOrPut(utils.alloc, token.val_ind);
                in_import.value_ptr.* = shared_index;
                expect_symbol = false;
            } else if (token.type.isBlockDecl()) {
                self.revert();
                return;
            } else if (token.type != .NewLine) {
                utils.printSrcLineColError("expected label name", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        } else {
            if (token.type == .Comma or token.type == .NewLine) {
                expect_symbol = true;
            } else if (token.type.isBlockDecl()) {
                self.revert();
                return;
            } else {
                utils.printSrcLineColError("expected ,", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        }
    }
}

fn parseConstBlock(self: *Parser) ParserError!void {
    var token = self.consume();
    try self.expectToken(token, .NewLine);
    while (!self.end()) {
        token = self.consume();
        if (token.type.isBlockDecl()) {
            self.revert();
            return;
        } else if (token.type != .Ident) {
            utils.printSrcLineColError("expected constant name", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        const name = token;
        try self.checkUniqueLabel(name, .@"const");
        token = self.consume();
        try self.expectToken(token, .Colon);
        const res = try self.program.constants.getOrPut(utils.alloc, name.val_ind);
        res.value_ptr.* = try ConstExprEval.parse(self);
        token = self.consume();
        try self.expectToken(token, .NewLine);
    }
}

/// Parses enum type declaration starting with its name, ending with }.
/// Stores type in program types.
fn parseEnumDeclaration(self: *Parser) ParserError!void {
    var token = self.consume();
    if (token.type != .Ident) {
        utils.printSrcLineColError("expected enum name", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    const enum_name_token = token;
    const enum_name = enum_name_token.val_ind;
    try self.checkUniqueLabel(token, .types);
    token = self.consume();
    if (token.type == .d128 or !token.type.isDataDirective()) {
        utils.printSrcLineColError("expected enum backing int type (d8, d16, d32 or d64)", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    const data_size = dataSize(token.type);
    token = self.consume();
    try self.expectToken(token, .OpenBrace);
    const fields_start: u16 = @truncate(self.program.types.enums_fields.items.len);
    var fields_count: u16 = 0;
    var cur_value: u64 = 0;
    self.consumeNewline();
    token = self.peek();
    while (token.type != .CloseBrace) {
        token = self.consume();
        if (token.type != .Ident) {
            utils.printSrcLineColError("expected enum field name", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        const field_name = token.val_ind;
        if (!self.program.types.isUniqueEnumField(field_name, fields_start)) {
            utils.printSrcLineColErrorFmt("field with name '{s}' already defined in this enum", .{utils.stringValue(field_name)}, self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        token = self.consume();
        if (token.type == .Colon) {
            const expr_token = token;
            const num = try ConstExprEval.parse(self);
            if (num.sign == .i) {
                utils.printSrcLineColError("expected non-negative number", self.program, expr_token.line, expr_token.col);
                return ParserError.ParsingFailed;
            } else if (num.fitsInBytes() > data_size) {
                utils.printSrcLineColError("value doesn't fit in specified data size", self.program, expr_token.line, expr_token.col);
                return ParserError.ParsingFailed;
            }
            cur_value = num.bits;
            token = self.consume();
        }
        if (token.type != .Comma) {
            utils.printSrcLineColError("expected , or :", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        self.consumeNewline();
        if ((Immediate{ .bits = cur_value, .sign = .u }).fitsInBytes() > data_size) {
            utils.printSrcLineErrorFmt("value {d} doesn't fit in specified data size", .{cur_value}, self.program, token.line);
            return ParserError.ParsingFailed;
        }
        try self.program.types.enums_fields.append(utils.alloc, .{ .name = field_name, .value = cur_value });
        fields_count += 1;
        token = self.peek();
        cur_value += 1;
    }
    self.consumeVoid(); // Because hitting } only as peeked
    self.consumeNewline();
    if (fields_count == 0) {
        utils.printSrcLineColWarning("empty enum", self.program, enum_name_token.line, enum_name_token.col);
    }
    const in_types = try self.program.types.getOrPut(enum_name);
    in_types.value_ptr.* = .{ .@"enum" = .{ .data_size = data_size, .fields_start = fields_start, .fields_end = fields_start + fields_count } };
}

/// Tries to parse next tokens as @align n instruction,
/// but if they are not then returns null.
fn parseAlignInstr(self: *Parser) ParserError!?Alignment {
    const token = self.peek();
    if (token.type != .@"align") {
        return null;
    }
    self.consumeVoid();
    const alignment = try ConstExprEval.parse(self);
    if (std.math.isPowerOfTwo(alignment.bits)) {
        if (alignment.bits <= 4096) {
            return Program.alignmentFromBytes(alignment.bits);
        } else {
            utils.printSrcLineColError("alignment is too big (max 4096)", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
    } else {
        utils.printSrcLineColError("alignment must be power of two", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
}

/// Parses struct body starting with { or packed keyword, ending with }
/// Returns type, storing which is the caller job
fn parseStructBody(self: *Parser) ParserError!Program.Type {
    var token = self.peek();
    var pack = false;
    if (token.type == .@"packed") {
        pack = true;
        self.consumeVoid();
    }
    token = self.consume();
    try self.expectToken(token, .OpenBrace);
    var fields: std.ArrayList(Program.Type.StructField) = .empty;
    errdefer fields.deinit(utils.alloc);
    var struct_alignment: Alignment = 0;
    var field_offset: u32 = 0;
    self.consumeNewline();
    token = self.peek();
    while (token.type != .CloseBrace) {
        const align_token = self.peek();
        var alignment: ?Alignment = try self.parseAlignInstr();
        if (alignment != null and pack) {
            utils.printSrcLineColError("cannot use alignment in packed struct", self.program, align_token.line, align_token.col);
            return ParserError.ParsingFailed;
        }
        self.consumeNewline();
        token = self.consume();
        if (token.type != .Ident) {
            utils.printSrcLineColError("expected struct field name", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        const field_name = token.val_ind;
        if (!self.program.types.isUniqueStructField(fields.items, field_name)) {
            utils.printSrcLineColErrorFmt("field with name '{s}' already defined in this struct", .{utils.stringValue(field_name)}, self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        token = self.consume();
        try self.expectToken(token, .Colon);
        const field_type_name = try self.parseType();
        const field_type = self.program.types.get(field_type_name).?;
        const field_size = field_type.size(self.program);
        const field_alignment = field_type.alignment(self.program);
        if (alignment == null) {
            alignment = if (pack) 0 else field_alignment;
        }
        field_offset = Program.alignOffset(field_offset, alignment.?);
        struct_alignment = @max(struct_alignment, alignment.?);
        token = self.consume();
        try self.expectToken(token, .Comma);
        self.consumeNewline();
        token = self.peek();
        try fields.append(utils.alloc, .{
            .name = field_name,
            .type = field_type_name,
            .alignment = alignment.?,
            .offset = field_offset,
        });
        // std.debug.print("{any}\n", .{fields.last().?});
        field_offset += field_size;
    }
    self.consumeVoid(); // Because hitting } only as peeked
    const struct_type: Program.Type = .{
        .@"struct" = .{
            .fields = try self.program.types.putStructFields(fields),
            .alignment = struct_alignment,
            .size = Program.alignOffset(field_offset, struct_alignment),
        },
    };
    return struct_type;
}

/// Parses next tokens as type, stores it in program types and returns its index.
fn parseType(self: *Parser) ParserError!TypeName {
    var token = self.consume();
    var type_name = token.val_ind;
    if (token.type == .Ident or token.type.isDataDirective()) {
        if (!self.program.types.contains(type_name)) {
            utils.printSrcLineColError("expected field type", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
    } else if (token.type == .OpenBrace or token.type == .@"packed") {
        self.revert();
        const anon_struct = try self.parseStructBody();
        type_name = try self.program.types.putAnonStruct(anon_struct);
    } else {
        utils.printSrcLineColError("expected field type", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    token = self.peek();
    if (token.type == .OpenBracket) {
        // array type
        self.consumeVoid();
        token = self.peek();
        const len = try ConstExprEval.parse(self);
        if (len.sign == .u and len.fitsInBytes() <= 4 and len.bits > 0) {
            type_name = try self.program.types.putArrayType(.{ .len = @intCast(len.bits), .type = type_name });
        } else {
            utils.printSrcLineColError("invalid array len value", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        token = self.consume();
        try self.expectToken(token, .CloseBracket);
    }
    return type_name;
}

/// Parses struct type declaration starting with its name, ending with }.
/// Stores type in program types.
fn parseStructDeclaration(self: *Parser) ParserError!void {
    const token = self.consume();
    if (token.type != .Ident) {
        utils.printSrcLineColError("expected struct name", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    const struct_name_token = token;
    const struct_name = struct_name_token.val_ind;
    try self.checkUniqueLabel(token, .types);
    const struct_body = try self.parseStructBody();
    if (struct_body.@"struct".size == 0) {
        utils.printSrcLineColWarning("empty struct", self.program, struct_name_token.line, struct_name_token.col);
    }
    const res = try self.program.types.getOrPut(struct_name);
    res.value_ptr.* = struct_body;
}

fn parseTypesBlock(self: *Parser) ParserError!void {
    var token = self.consume();
    try self.expectToken(token, .NewLine);
    while (!self.end()) {
        token = self.consume();
        if (token.type.isBlockDecl()) {
            self.revert();
            return;
        } else if (token.type == .@"enum") {
            try self.parseEnumDeclaration();
        } else if (token.type == .@"struct") {
            try self.parseStructDeclaration();
        } else if (token.type != .NewLine) {
            utils.printSrcLineColError("expected enum or struct declaration", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
    }
}

/// Checks if provided alignment does not narrow expected alignment.
/// If so, error generated, otherwise returns new alignment
fn checkProperAlignment(self: *Parser, align_token: Token, expected: Alignment, provided: ?Alignment) ParserError!Alignment {
    var instr_align = expected;
    if (provided) |al| {
        if (al < expected) {
            utils.printSrcLineColError("alignment is less than type natural alignment", self.program, align_token.line, align_token.col);
            return ParserError.ParsingFailed;
        }
        instr_align = al;
    }
    return instr_align;
}

fn parseBssInstr(self: *Parser) ParserError!void {
    const align_token = self.peek();
    const alignment = try self.parseAlignInstr();
    self.consumeNewline();
    var token = self.consume();
    if (token.type != .Ident and token.type != .HashIdent) {
        utils.printSrcLineColError("expected label name", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    const label = token.val_ind;
    try self.checkUniqueLabel(token, .bss);
    const name_token = token;
    token = self.consume();
    try self.expectToken(token, .Colon);
    const type_name = try self.parseType();
    const instr_type = self.program.types.get(type_name).?;
    const instr_align = try self.checkProperAlignment(align_token, instr_type.alignment(self.program), alignment);
    token = self.consume();
    try self.expectToken(token, .NewLine);

    // Datagen

    self.program.bss_block.alignBuffer(instr_align);

    const offset = self.program.bss_block.len;
    const size = instr_type.size(self.program);
    self.program.bss_block.len += size;

    if (!std.mem.eql(u8, utils.stringValue(label), "_")) {
        const in_data = try self.program.data_vars.getOrPut(utils.alloc, label);
        in_data.value_ptr.visib = if (name_token.type == .HashIdent) .Export else .Local;
        in_data.value_ptr.block = .Bss;
        in_data.value_ptr.offset = offset;
        in_data.value_ptr.size = size;
        in_data.value_ptr.type = type_name;
    }
}

fn parseBssBlock(self: *Parser) ParserError!void {
    var token = self.consume();
    try self.expectToken(token, .NewLine);
    while (!self.end()) {
        token = self.peek();
        if (token.type.isBlockDecl()) {
            return;
        }
        try self.parseBssInstr();
    }
}

/// Parses repeat statement in array initialization.
/// Starts from ( after repeat, ends on ). Returns count value.
fn parseRepeatWithDatagen(self: *Parser, backed_type: TypeName, pos: u32, infer_len: bool) ParserError!u32 {
    var token = self.consume();
    try self.expectToken(token, .OpenParen);
    token = self.peek();
    const count_token = token;
    const count = try ConstExprEval.parse(self);
    const count_value: u32 = switch (count.sign) {
        .u => @truncate(count.bits),
        .i => {
            utils.printSrcLineColError("expected non-negative number as repeat count", self.program, count_token.line, count_token.col);
            return ParserError.ParsingFailed;
        },
    };
    token = self.consume();
    try self.expectToken(token, .Comma);
    token = self.peek();
    const backed = self.program.types.get(backed_type).?;
    if (infer_len) {
        const reserve_size = count_value * backed.size(self.program);
        if (self.program.data_block.buffer.items.len + reserve_size > 50_000_000) {
            @branchHint(.unlikely);
            utils.printSrcLineColError("repeat statement will exceed total limit of 50MB for data block", self.program, count_token.line, count_token.col);
            return ParserError.ParsingFailed;
        }
        try self.reserveTopDataBlock(reserve_size);
    }
    if (token.type == .Ident) {
        self.consumeVoid();
        if (token.val_ind != backed_type) {
            utils.printSrcLineColErrorFmt("expected '{s}' type", .{utils.stringValue(backed_type)}, self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        const ret_pos = self.getPos();
        var i: u32 = 0;
        while (i < count_value) : (i += 1) {
            self.revertToPos(ret_pos);
            if (backed == .@"struct") {
                try self.parseStructWithDatagen(backed_type, pos + i * backed.@"struct".size);
            } else if (backed == .@"enum") {
                try self.parseEnumValueWithDatagen(backed_type, pos + i * backed.@"enum".data_size);
            }
        }
    } else {
        const prim_size: u8 = @truncate(backed.size(self.program));
        const imm = try ConstExprEval.parse(self);
        for (0..count_value) |i| {
            self.insertImmediateBytes(imm, prim_size, @truncate(pos + i * prim_size));
        }
    }
    token = self.consume();
    try self.expectToken(token, .CloseParen);

    return count_value;
}

/// Parses next tokens as array initialization, starting with {, ending with }.
/// Generates data bytes at given buffer position.
/// Returns array len
fn parseArrayWithDatagen(self: *Parser, len: u32, backed_type: TypeName, pos: u32) ParserError!u32 {
    var token = self.consume();
    try self.expectToken(token, .OpenBrace);
    var cur_len: u32 = 0;
    self.consumeNewline();
    token = self.peek();
    const backed = self.program.types.get(backed_type).?;
    const data_size = backed.size(self.program);
    while (token.type != .CloseBrace) {
        if (len > 0 and cur_len >= len) {
            // utils.printSrcLineColError("unexpected value in array initialization", self.program, token.line, token.col);
            // return ParserError.ParsingFailed;
            try self.expectToken(token, .CloseBrace);
        }
        token = self.consume();
        if (token.type == .repeat) {
            const added = try self.parseRepeatWithDatagen(backed_type, pos + data_size * cur_len, len == 0);
            cur_len += added;
        } else if (token.type == .StringLiteral) {
            if (backed == .d8) {
                // TODO: Add support for escape sequences
                const literal = utils.stringValue(token.val_ind);
                const lit_len = literal.len;
                if (len == 0) try self.reserveTopDataBlock(lit_len);
                for (literal, 0..) |byte, i| {
                    self.program.data_block.buffer.items[pos + (cur_len + i) * data_size] = byte;
                }
                cur_len += @truncate(lit_len);
            } else {
                utils.printSrcLineColError("string literal allowed only for d8 type", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        } else if (token.type == .Ident) {
            if (token.val_ind != backed_type) {
                utils.printSrcLineColErrorFmt("expected '{s}' type", .{utils.stringValue(backed_type)}, self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            if (len == 0) try self.reserveTopDataBlock(backed.size(self.program));
            if (backed == .@"struct") {
                try self.parseStructWithDatagen(backed_type, pos + data_size * cur_len);
            } else if (backed == .@"enum") {
                self.revert();
                try self.parseEnumValueWithDatagen(backed_type, pos + data_size * cur_len);
            }
            cur_len += 1;
        } else {
            // Primitive number value
            self.revert();
            const expr_token = self.peek();
            const value = try ConstExprEval.parse(self);
            if (value.fitsInBytes() <= data_size) {
                if (len == 0) try self.reserveTopDataBlock(data_size);
                self.insertImmediateBytes(value, @truncate(data_size), pos + data_size * cur_len);
            } else {
                utils.printSrcLineColError("value doesn't fit in array data size", self.program, expr_token.line, expr_token.col);
                return ParserError.ParsingFailed;
            }
            cur_len += 1;
        }
        token = self.consume();
        if (token.type == .CloseBrace) {
            self.revert();
            break;
        }
        try self.expectToken(token, .Comma);
        self.consumeNewline();
        token = self.peek();
    }
    self.consumeVoid();
    return @max(len, cur_len);
}

/// Parses enum value in  enum_name.field_name  format.
/// Generates data bytes at given buffer position.
fn parseEnumValueWithDatagen(self: *Parser, type_name: TypeName, pos: u32) ParserError!void {
    var token = self.consume();
    if (token.type != .Ident or token.val_ind != type_name) {
        utils.printSrcLineColErrorFmt("expected enum '{s}' value", .{utils.stringValue(type_name)}, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    const enum_type = self.program.types.get(type_name).?;
    std.debug.assert(enum_type == .@"enum");
    const fields_start = enum_type.@"enum".fields_start;
    const fields_end = enum_type.@"enum".fields_end;
    const fields = self.program.types.enums_fields.items[fields_start..fields_end];
    token = self.consume();
    try self.expectToken(token, .Dot);
    token = self.consume();
    if (token.type == .Ident) {
        const field_name = token.val_ind;
        const field = self.program.types.getEnumField(fields, field_name) orelse {
            utils.printSrcLineColErrorFmt("enum '{s}' doesn't contain '{s}' field", .{ utils.stringValue(type_name), utils.stringValue(field_name) }, self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        };
        // datagen
        if (pos == self.program.data_block.buffer.items.len) {
            // This is top level enum value, so reserve bytes for it
            try self.reserveTopDataBlock(enum_type.@"enum".data_size);
        }
        self.insertImmediateBytes(.{ .bits = field.value, .sign = .u }, enum_type.@"enum".data_size, pos);
    } else {
        utils.printSrcLineColErrorFmt("expected enum '{s}' value", .{utils.stringValue(type_name)}, self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
}

/// Parses struct body value. Generates data bytes at given buffer position.
fn parseStructWithDatagen(self: *Parser, type_name: TypeName, pos: u32) ParserError!void {
    const struct_type = self.program.types.get(type_name).?;
    std.debug.assert(struct_type == .@"struct");
    var token = self.consume();
    try self.expectToken(token, .OpenBrace);
    token = self.consume();
    const fields = self.program.types.structs_fields.items[struct_type.@"struct".fields].items;
    const struct_size = struct_type.@"struct".size;
    if (pos == self.program.data_block.buffer.items.len) {
        // This is top level struct, so reserve all bytes for it
        try self.reserveTopDataBlock(struct_size);
    }
    self.consumeNewline();
    token = self.peek();
    while (token.type != .CloseBrace) {
        token = self.consume();
        if (token.type != .Ident) {
            utils.printSrcLineColError("expected struct field name", self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        }
        const field_name = token.val_ind;
        const field = self.program.types.getStructField(fields, field_name) orelse {
            utils.printSrcLineColErrorFmt("struct '{s}' doesn't contain '{s}' field", .{ utils.stringValue(type_name), utils.stringValue(field_name) }, self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        };
        token = self.consume();
        try self.expectToken(token, .Colon);
        const field_type = self.program.types.get(field.type).?;
        const field_offset = field.offset;
        const field_size = field_type.size(self.program);
        switch (field_type) {
            .d8, .d16, .d32, .d64, .d128 => {
                const expr_token = self.peek();
                const value = try ConstExprEval.parse(self);
                if (value.fitsInBytes() <= field_size) {
                    self.insertImmediateBytes(value, @truncate(field_size), pos + field_offset);
                } else {
                    utils.printSrcLineColError("value doesn't fit in field data size", self.program, expr_token.line, expr_token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .array => |arr| {
                _ = try self.parseArrayWithDatagen(arr.len, arr.type, pos + field_offset);
            },
            .@"enum" => {
                try self.parseEnumValueWithDatagen(field.type, pos + field_offset);
            },
            .@"struct" => {
                try self.parseStructWithDatagen(field.type, pos + field_offset);
            },
        }

        token = self.consume();
        try self.expectToken(token, .Comma);
        self.consumeNewline();
        token = self.peek();
    }
    self.consumeVoid(); // Because hitting } only as peeked
}

fn parseDataInstr(self: *Parser) ParserError!void {
    const align_token = self.peek();
    const alignment = try self.parseAlignInstr();
    self.consumeNewline();
    var token = self.consume();
    if (token.type != .Ident and token.type != .HashIdent) {
        utils.printSrcLineColError("expected label name", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
    const label = token.val_ind;
    try self.checkUniqueLabel(token, .data);
    // std.debug.print("parsing {s} variable\n", .{utils.stringValue(label)});
    const name_token = token;
    token = self.consume();
    try self.expectToken(token, .Colon);
    token = self.consume();
    var offset: u32 = @truncate(self.program.data_block.buffer.items.len);
    const basic_type_token = token;
    var type_name: TypeName = basic_type_token.val_ind;
    if (token.type == .Ident or token.type.isDataDirective()) {
        const basic_type = self.program.types.get(type_name) orelse {
            utils.printSrcLineColErrorFmt("type '{s}' is not defined", .{utils.stringValue(token.val_ind)}, self.program, token.line, token.col);
            return ParserError.ParsingFailed;
        };
        token = self.peek();
        if (token.type == .OpenBracket) {
            // array type
            self.consumeVoid();
            token = self.peek();
            var len: Immediate = .{ .bits = 0, .sign = .u };
            const arr_alignment = basic_type.alignment(self.program);
            if (token.type == .CloseBracket) {
                // array len not specified
                token = self.consume();
                const instr_align = try self.checkProperAlignment(align_token, arr_alignment, alignment);
                offset = try self.program.data_block.alignBuffer(instr_align);
                len.bits = try self.parseArrayWithDatagen(@truncate(len.bits), type_name, @truncate(self.program.data_block.buffer.items.len));
            } else {
                len = try ConstExprEval.parse(self);
                if (len.sign == .u and len.fitsInBytes() <= 4 and len.bits > 0) {
                    token = self.consume();
                    try self.expectToken(token, .CloseBracket);
                    // array with explicit len initialization
                    const instr_align = try self.checkProperAlignment(align_token, arr_alignment, alignment);
                    offset = try self.program.data_block.alignBuffer(instr_align);
                    const pos: u32 = @truncate(self.program.data_block.buffer.items.len);
                    try self.reserveTopDataBlock(len.bits * basic_type.size(self.program));
                    _ = try self.parseArrayWithDatagen(@truncate(len.bits), type_name, pos);
                } else {
                    utils.printSrcLineColError("invalid array len value", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            }
            type_name = try self.program.types.putArrayType(Program.Type.Array{ .len = @truncate(len.bits), .type = type_name });
        } else {
            // non array type
            if (basic_type_token.type == .Ident) {
                if (basic_type == .@"struct") {
                    // struct initialization
                    const instr_align = try self.checkProperAlignment(align_token, basic_type.@"struct".alignment, alignment);
                    offset = try self.program.data_block.alignBuffer(instr_align);
                    try self.parseStructWithDatagen(type_name, @truncate(self.program.data_block.buffer.items.len));
                } else if (basic_type == .@"enum") {
                    // enum initialization
                    const instr_align = try self.checkProperAlignment(align_token, basic_type.@"enum".data_size, alignment);
                    offset = try self.program.data_block.alignBuffer(instr_align);
                    try self.parseEnumValueWithDatagen(type_name, @truncate(self.program.data_block.buffer.items.len));
                } else unreachable;
            } else if (basic_type_token.type.isDataDirective()) {
                // primitive type initialization
                const instr_align = try self.checkProperAlignment(align_token, basic_type.alignment(self.program), alignment);
                offset = try self.program.data_block.alignBuffer(instr_align);
                const imm = try ConstExprEval.parse(self);
                try self.appendImmediateBytes(imm, @truncate(basic_type.size(self.program)));
            } else unreachable;
        }
    } else if (token.type == .OpenBrace or token.type == .@"packed") {
        self.revert();
        // TODO: anon struct initialization
    } else {
        utils.printSrcLineColError("expected field type", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }

    token = self.consume();
    try self.expectToken(token, .NewLine);

    const new_offset: u32 = @truncate(self.program.data_block.buffer.items.len);
    const size = new_offset - offset;

    if (!std.mem.eql(u8, utils.stringValue(label), "_")) {
        const in_data = try self.program.data_vars.getOrPut(utils.alloc, label);
        in_data.value_ptr.visib = if (name_token.type == .HashIdent) .Export else .Local;
        in_data.value_ptr.block = .Data;
        in_data.value_ptr.offset = offset;
        in_data.value_ptr.size = size;
        in_data.value_ptr.type = type_name;
    }
}

fn parseDataBlock(self: *Parser) ParserError!void {
    var token = self.consume();
    try self.expectToken(token, .NewLine);
    while (!self.end()) {
        token = self.peek();
        if (token.type.isBlockDecl()) return;
        try self.parseDataInstr();
    }
}

fn maxInstrOperandCount(mnem: TokenType) usize {
    const opcount = @backingInt(mnem) & 0x700;
    if (opcount == 0x200) return 2;
    if (opcount == 0x100 or opcount == 0x400) return 1;
    if (opcount == 0x0) return 0;
    if (opcount == 0x300 or opcount == 0x500) return 3;
    unreachable;
}

fn checkInstrOpLen(mnem: TokenType, oplen: usize) []const u8 {
    const expected = @backingInt(mnem) & 0x700;

    return if (expected == 0x200 and oplen != 2)
        "2"
    else if (expected == 0x100 and oplen != 1)
        "1"
    else if (expected == 0x0 and oplen != 0)
        "0"
    else if (expected == 0x400 and oplen > 1)
        "0 or 1"
    else if (expected == 0x500 and (oplen < 1 or oplen > 3))
        "1, 2 or 3"
    else if (expected == 0x300 and (oplen != 3))
        "3"
    else
        &.{};
}

fn addImmediates(lhs: Immediate, rhs: Immediate) std.fmt.ParseIntError!Immediate {
    const left: i128 = switch (lhs.sign) {
        .u => lhs.bits,
        .i => lhs.negative(),
    };
    const right: i128 = switch (rhs.sign) {
        .u => rhs.bits,
        .i => rhs.negative(),
    };
    const added: i128 = left + right;
    if (std.math.cast(u64, added)) |imm| {
        return .{ .bits = imm, .sign = .u };
    } else if (std.math.cast(i64, added)) |imm| {
        return .{ .bits = @bitCast(imm), .sign = .i };
    } else {
        return std.fmt.ParseIntError.Overflow;
    }
}

fn checkMemOperand(self: *const Parser, oper: *MemOperand, line: u16) ParserError!void {
    var b_size: ?u8 = null;
    var i_size: ?u8 = null;
    if (oper.base.size() > 0) {
        b_size = oper.base.size();
        if (oper.base.name == .rip and oper.index.size() != 0) {
            utils.printSrcLineError("rip-relative addressing with index is not allowed", self.program, line);
            return ParserError.ParsingFailed;
        }
    }
    if (oper.index.size() > 0) {
        i_size = oper.index.size();
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

/// Parses variable field access syntax starting after first dot.
/// Returns offset relative to variable start.
fn parseFieldAccess(self: *Parser, variable_type: Program.Type, variable_name: Label) ParserError!u64 {
    var offset: u64 = 0;
    var expect_field = true;
    var parent_type = variable_type;
    var parent_name = variable_name;
    var token = self.peek();
    while (!self.end()) {
        token = self.consume();
        if (token.type == .Dot) {
            if (expect_field) {
                utils.printSrcLineColError("expected field name", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            expect_field = true;
        } else if (token.type == .Ident) {
            if (!expect_field) {
                utils.printSrcLineColError("unexpected token", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            const child_label = utils.stringValue(token.val_ind);
            switch (parent_type) {
                .@"struct" => |s| {
                    const label = token.val_ind;
                    const fields = self.program.types.structs_fields.items[s.fields].items;
                    const field = self.program.types.getStructField(fields, label) orelse {
                        utils.printSrcLineColErrorFmt("field '{s}' doesn't contain '{s}' field", .{ utils.stringValue(parent_name), child_label }, self.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    };
                    parent_type = self.program.types.get(field.type).?;
                    parent_name = field.name;
                    offset += field.offset;
                },
                else => {
                    utils.printSrcLineColErrorFmt("field '{s}' doesn't contain '{s}' field", .{ utils.stringValue(parent_name), child_label }, self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                },
            }
            expect_field = false;
        } else if (token.type == .NumberLiteral) {
            if (!expect_field) {
                utils.printSrcLineColError("unexpected token", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            switch (parent_type) {
                .array => |a| {
                    const len = a.len;
                    const len_label = utils.stringValue(token.val_ind);
                    const index = std.fmt.parseInt(u64, len_label, 0) catch {
                        utils.printSrcLineColErrorFmt("value {s} doesn't fit in 64 bit", .{len_label}, self.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    };
                    if (index >= len) {
                        utils.printSrcLineColErrorFmt("index {d} outside of the array bounds [0..{d}]", .{ index, len }, self.program, token.line, token.col);
                        return ParserError.ParsingFailed;
                    }
                    parent_type = self.program.types.get(a.type).?;
                    parent_name = token.val_ind;
                    offset += parent_type.size(self.program) * index;
                },
                else => {
                    utils.printSrcLineColErrorFmt("field '{s}' is not indexible", .{utils.stringValue(parent_name)}, self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                },
            }
            expect_field = false;
        } else {
            if (expect_field) {
                utils.printSrcLineColError("expected field name", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            self.revert();
            break;
        }
    }
    return offset;
}

/// Parses memory operand in form  [...] or p8 [...].
fn parseMemAddrOperand(self: *Parser) ParserError!MemOperand {
    var memop: MemOperand = .{
        .disp = 0,
        .base = .{ .name = .reg0 },
        .index = .{ .name = .reg0 },
        .label = 0,
        .scale = 0,
        .size = 0,
    };
    var token = self.peek();
    if (token.type.isPointerSize()) {
        memop.size = switch (token.type) {
            .p8 => 1,
            .p16 => 2,
            .p32 => 4,
            .p64 => 8,
            .p128 => 16,
            else => unreachable,
        };
        self.consumeVoid();
    }
    token = self.consume();
    try self.expectToken(token, .OpenBracket);

    try AddrExprEval.parse(self, &memop);

    token = self.consume();
    try self.expectToken(token, .CloseBracket);
    try self.checkMemOperand(&memop, token.line);
    return memop;
}

fn parseCodeOperand(self: *Parser) ParserError!CodeOperand {
    var oper: CodeOperand = undefined;

    const OpType = enum { reg, imm, lbl, lblimm, mem, none };
    var op: OpType = .none;

    var token = self.peek();
    while (!self.end() and token.type != .Comma and token.type != .NewLine) {
        token = self.peek();
        const t = token.type;

        if (t.isReg()) {
            if (op != .none) {
                utils.printSrcLineColError("unexpected register", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            } else if (t == .rip) {
                utils.printSrcLineColError("rip register cannot be operand", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            const reg = Register.init(t);
            oper = .initReg(reg);
            op = .reg;
            self.consumeVoid();
        } else if (t.isPointerSize() or t == .OpenBracket) {
            if (op != .none) {
                utils.printSrcLineColError("unexpected memory operand", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            oper = .initMem(try self.parseMemAddrOperand());
            op = .mem;
        } else if (t == .Ident or t == .DotIdent) {
            if (op != .none) {
                utils.printSrcLineColError("unexpected identifier", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            const label = token.val_ind;
            const is_constant = self.program.constants.contains(label);
            if (is_constant) {
                const value = try ConstExprEval.parse(self);
                oper = .initImm(value);
                op = .imm;
            } else {
                const label_token = token;
                self.consumeVoid();
                if (self.peek().type == .Dot) {
                    token = self.consume(); // .
                    // field access
                    // Can access field only if:
                    //   1. Data variable, with struct or array type -> offset of last field relative to variable -> Label, Imm
                    //   2. Enum type -> field value -> Imm
                    if (self.program.data_vars.get(label)) |variable| {
                        const var_type = self.program.types.get(variable.type).?;
                        const field_offset = try self.parseFieldAccess(var_type, label);
                        oper = .initLbl(label, .{ .bits = field_offset, .sign = .u });
                        op = .lblimm;
                    } else if (self.program.types.get(label)) |ty| {
                        if (ty == .@"enum") {
                            self.revert();
                            self.revert();
                            const value = try ConstExprEval.parse(self);
                            oper = .initImm(value);
                            op = .imm;
                        } else {
                            utils.printSrcLineColErrorFmt("type '{s}' fields are not accessible", .{utils.stringValue(label)}, self.program, label_token.line, label_token.col);
                            return ParserError.ParsingFailed;
                        }
                    } else {
                        utils.printSrcLineColErrorFmt("undefined variable '{s}'", .{utils.stringValue(label)}, self.program, label_token.line, label_token.col);
                        return ParserError.ParsingFailed;
                    }
                } else {
                    oper = .initLbl(label, null);
                    op = .lbl;
                }
            }
        } else {
            const value = try ConstExprEval.parse(self);
            if (op == .none) {
                oper = .initImm(value);
                op = .imm;
            } else if (op == .imm) {
                const added = addImmediates(oper.op.imm.i, value) catch {
                    utils.printSrcLineColError("value doesn't fit in 64 bit", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                };
                oper.op.imm.i = added;
            } else if (op == .lblimm) {
                const added = addImmediates(oper.op.label.d, value) catch {
                    utils.printSrcLineColError("value doesn't fit in 64 bit", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                };
                oper.op.label.d = added;
            } else if (op == .lbl) {
                oper.op.label.d = value;
                op = .lblimm;
            } else {
                utils.printSrcLineColError("unexpected value", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        }

        token = self.peek();
    }

    return oper;
}

fn parseCodeInstr(self: *Parser) ParserError!void {
    var token = self.consume();
    var instr: CodeInstruction = undefined;
    if (token.type.isAnyIdent()) {
        const label_token = token;
        token = self.consume();
        try self.expectToken(token, .Colon);
        const label = label_token.val_ind;
        const is_func = label_token.type != .DotIdent;

        if (is_func) {
            try self.checkUniqueLabel(label_token, .code);
            const res = try self.program.funcs.getOrPut(utils.alloc, label);
            res.value_ptr.local_labels = .empty;
            self.cur_func = label;
            res.value_ptr.visib = if (label_token.type == .HashIdent) .Export else .Local;
            res.value_ptr.size = 0;
            res.value_ptr.offset = 0;
        } else {
            const label_name = utils.stringValue(label);
            const function = self.program.funcs.getPtr(self.cur_func);
            if (function) |func| {
                const in_func = try func.local_labels.getOrPut(utils.alloc, label);
                if (in_func.found_existing) {
                    utils.printSrcLineColErrorFmt("local label '{s}' already defined in function '{s}'", .{ label_name, utils.stringValue(self.cur_func) }, self.program, label_token.line, label_token.col);
                    return ParserError.ParsingFailed;
                }
            } else {
                utils.printSrcLineColErrorFmt("local label '{s}' does not belong to any function", .{label_name}, self.program, label_token.line, label_token.col);
                return ParserError.ParsingFailed;
            }
        }
        self.consumeNewline();
        instr = .{ .label = .{ .name = label, .line = label_token.line } };
        try self.program.code_block.instr.append(utils.alloc, instr);
    } else if (token.type.isMnemonic()) {
        instr = .{ .cpu = .{ .mnem = token.type, .operands = .{ .index = @truncate(self.program.code_block.operands.items.len), .len = 0 }, .line = token.line } };

        const max_oper_count = maxInstrOperandCount(instr.cpu.mnem);
        var oper_count: usize = 0;
        token = self.peek();
        while (token.type != .NewLine) {
            token = self.peek();
            const operand = try self.parseCodeOperand();
            oper_count += 1;
            if (oper_count > max_oper_count) {
                utils.printSrcLineColError("unexpected operand", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
            try self.program.code_block.operands.append(utils.alloc, operand);
            instr.cpu.operands.len += 1;
            token = self.consume();
            if (token.type != .Comma and token.type != .NewLine) {
                utils.printSrcLineColError("expected , or end of line", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            }
        }
        if (oper_count == 0) token = self.consume();
        try self.expectToken(token, .NewLine);

        const message = checkInstrOpLen(instr.cpu.mnem, instr.cpu.operands.len);
        if (message.len > 0) {
            utils.printSrcLineErrorFmt("wrong number of operands for '{t}' instruction, expected {s}", .{ instr.cpu.mnem, message }, self.program, token.line);
            return ParserError.ParsingFailed;
        }
        try self.program.code_block.instr.append(utils.alloc, instr);
    } else {
        utils.printSrcLineColError("expected label or mnemonic", self.program, token.line, token.col);
        return ParserError.ParsingFailed;
    }
}

fn parseCodeBlock(self: *Parser) ParserError!void {
    var token = self.consume();
    try self.expectToken(token, .NewLine);
    token = self.peek();
    while (!self.end()) {
        token = self.peek();
        if (token.type.isBlockDecl()) return;
        try self.parseCodeInstr();
    }
}

pub fn parseTokens(self: *Parser) ParserError!void {
    while (!self.end()) {
        const token = self.consume();

        switch (token.type) {
            .entry => {
                if (!self.program.flags.has_entry) {
                    try self.parseEntry();
                    self.program.flags.has_entry = true;
                } else {
                    utils.printSrcLineColError("@entry label already defined in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .import => try self.parseImportBlock(),
            .@"const" => try self.parseConstBlock(),
            .types => try self.parseTypesBlock(),
            .bss => {
                if (!self.program.flags.has_bss) {
                    try self.parseBssBlock();
                    if (self.program.bss_block.len > 0) {
                        self.program.flags.has_bss = true;
                    }
                } else {
                    utils.printSrcLineColError("@bss block already present in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .data => {
                if (!self.program.flags.has_data) {
                    try self.parseDataBlock();
                    if (self.program.data_block.buffer.items.len > 0) {
                        self.program.flags.has_data = true;
                    }
                } else {
                    utils.printSrcLineColError("@data block already present in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .code => {
                if (!self.program.flags.has_code) {
                    try self.parseCodeBlock();
                    if (self.program.code_block.instr.items.len > 0) {
                        self.program.flags.has_code = true;
                    }
                } else {
                    utils.printSrcLineColError("code block already present in this file", self.program, token.line, token.col);
                    return ParserError.ParsingFailed;
                }
            },
            .NewLine, .Eof => {},
            else => {
                utils.printSrcLineColError("expected block declaration", self.program, token.line, token.col);
                return ParserError.ParsingFailed;
            },
        }
    }

    try self.checkProperEntry();
}

fn checkProperEntry(self: *const Parser) ParserError!void {
    if (self.program.flags.has_entry) {
        if (!self.program.funcs.contains(self.program.entry)) {
            utils.printSrcFileErrorFmt("entry label '{s}' must point to defined code block label", .{utils.stringValue(self.program.entry)}, self.program);
            return ParserError.ParsingFailed;
        }
    }
}
