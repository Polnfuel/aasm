const std = @import("std");
const parser = @import("parser");
const lexer = @import("lexer");
const datagen = @import("datagen");
const codegen = @import("codegen");
const stdbuffers = @import("stdbuffers");

pub const BufferGenError = datagen.DatagenError || codegen.CodegenError;
pub const ProgramError = error{ProgramFailed} || BufferGenError;

pub const Program = struct {
    file_name: []const u8,
    content: []const u8,
    tokens: std.ArrayList(lexer.Token),
    entry: ?[]u8,
    data_section: ?parser.DataSection,
    code_section: ?parser.CodeSection,
    symbols: std.StringHashMap(parser.Symbol),
    exports: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn new(file_name: []const u8, content: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!Program {
        var program = Program{
            .file_name = undefined,
            .content = content,
            .tokens = .empty,
            .entry = null,
            .data_section = null,
            .code_section = null,
            .symbols = std.StringHashMap(parser.Symbol).init(allocator),
            .exports = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
        program.file_name = try program.allocator.dupe(u8, file_name);
        return program;
    }

    pub fn tokenize(self: *Program) lexer.LexerError!void {
        self.tokens = try lexer.tokenizeContent(self.allocator, self.content, self.file_name);
    }

    pub fn printTokens(self: *Program) void {
        lexer.printTokens(self.tokens);
    }

    pub fn parse(self: *Program) parser.ParserError!void {
        try parser.parseTokens(self);
    }

    pub fn printParse(self: *Program) void {
        parser.printAST(self);
    }

    pub fn printSymTab(self: *Program) void {
        parser.printSymbolTable(self);
    }

    pub fn defineExportLabels(self: *Program) ProgramError!void {
        var iter = self.exports.iterator();
        while (iter.next()) |*exp| {
            const exp_name = exp.key_ptr.*;
            if (self.symbols.getPtr(exp_name)) |ptr| {
                ptr.type = .Export;
            } else {
                stdbuffers.printSourceErrorFormatted(self.file_name, "export symbol '{s}' is not defined in this file", .{exp_name}, self.content, 1);
                return ProgramError.ProgramFailed;
            }
        }
    }

    pub fn genDataCodeBuffers(self: *Program) ProgramError!void {
        var any_section = false;
        if (self.data_section) |_| {
            // bufferize data section
            try datagen.bufferizeDataSection(self);
            any_section = true;
        }
        if (self.code_section) |_| {
            // bufferize code section
            try codegen.bufferizeCodeSection(self);
            any_section = true;
        }
        if (!any_section) {
            stdbuffers.printSourceError(self.file_name, "source file doesn't contain any data or code section", self.content, 1);
            return ProgramError.ProgramFailed;
        }
    }

    pub fn printBuffer(buffer: std.ArrayList(u8)) void {
        for (buffer.items) |byte| {
            std.debug.print("{x:02}", .{byte});
        }
        std.debug.print("\n", .{});
    }

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.file_name);
        self.allocator.free(self.content);
        self.tokens.deinit(self.allocator);
        if (self.data_section) |*data_section| {
            data_section.buffer.deinit(self.allocator);
            for (data_section.instr.items) |*instr| {
                instr.data.deinit(self.allocator);
            }
            data_section.instr.deinit(self.allocator);
        }
        if (self.code_section) |*code_section| {
            code_section.buffer.deinit(self.allocator);
            for (code_section.instr.items) |*instr| {
                switch (instr.*) {
                    .cpu => {
                        instr.cpu.operands.deinit(self.allocator);
                    },
                    .label => {},
                }
            }
            code_section.instr.deinit(self.allocator);
            code_section.relocations.deinit(self.allocator);
        }
        self.exports.deinit();
        self.symbols.deinit();
    }
};
