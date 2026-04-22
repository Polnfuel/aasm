const std = @import("std");
const parser = @import("parser");
const lexer = @import("lexer");
const datagen = @import("datagen");
const codegen = @import("codegen");
const stdbuffers = @import("stdbuffers");
const DebugInfo = @import("debug_info").DebugInfo;

pub const BufferGenError = datagen.DatagenError || codegen.CodegenError;
pub const AllocError = std.mem.Allocator.Error || std.fs.Dir.RealPathAllocError;
pub const ProgramError = error{ProgramFailed} || BufferGenError || std.fs.Dir.RealPathAllocError;

pub const Program = struct {
    file_name: []const u8,
    content: []const u8,
    tokens: std.ArrayList(lexer.Token),
    entry: ?[]u8,
    data_block: ?parser.DataBlock,
    code_block: ?parser.CodeBlock,
    symbols: std.StringHashMap(parser.Symbol),
    allocator: std.mem.Allocator,

    debug_info: DebugInfo,
    g: bool,

    pub fn new(file_name: []const u8, content: []const u8, allocator: std.mem.Allocator, collect_debug: bool) AllocError!Program {
        var program = Program{
            .file_name = undefined,
            .content = content,
            .tokens = .empty,
            .entry = null,
            .data_block = null,
            .code_block = null,
            .symbols = std.StringHashMap(parser.Symbol).init(allocator),
            .allocator = allocator,
            .debug_info = DebugInfo.init(),
            .g = collect_debug,
        };
        if (program.g) {
            program.debug_info.cwd_path = try std.fs.cwd().realpathAlloc(program.allocator, ".");
        }
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

    pub fn printDebugInfo(self: *Program) void {
        std.debug.print("  Debug Info\n", .{});
        if (self.g) {
            for (self.debug_info.entries.items) |entry| {
                std.debug.print(" offset: {x:04} line: {d}\n", .{ entry.offset, entry.line });
            }
        }
        std.debug.print("\n", .{});
    }

    pub fn checkEntry(self: *Program) ProgramError!void {
        if (self.entry) |entry| {
            var exist = false;
            var iter = self.symbols.keyIterator();
            while (iter.next()) |sym| {
                if (std.mem.eql(u8, sym.*, entry)) {
                    exist = true;
                }
            }
            if (!exist) {
                stdbuffers.printErrorFormatted("entry symbol '{s}' not defined in this file", .{entry});
                return ProgramError.ProgramFailed;
            }
        }
    }

    pub fn genDataCodeBuffers(self: *Program) ProgramError!void {
        var any_block = false;
        if (self.data_block) |_| {
            // bufferize data block
            try datagen.bufferizeDataBlock(self);
            any_block = true;
        }
        if (self.code_block) |_| {
            // bufferize code block
            try codegen.bufferizeCodeBlock(self);
            any_block = true;
        }
        if (!any_block) {
            stdbuffers.printSourceError(self.file_name, "source file doesn't contain any data or code block", self.content, 1);
            return ProgramError.ProgramFailed;
        }
    }

    pub fn printBuffer(buffer: std.ArrayList(u8)) void {
        for (buffer.items) |byte| {
            std.debug.print("{x:02}", .{byte});
        }
        std.debug.print("\n", .{});
    }

    pub fn printStrBuffer(buffer: std.ArrayList(u8)) void {
        for (buffer.items) |char| {
            std.debug.print("{c}", .{if (char == 0) ' ' else char});
        }
        std.debug.print("\n", .{});
    }

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.file_name);
        self.allocator.free(self.content);
        self.tokens.deinit(self.allocator);
        if (self.data_block) |*data_block| {
            data_block.buffer.deinit(self.allocator);
            for (data_block.instr.items) |*instr| {
                instr.data.deinit(self.allocator);
            }
            data_block.instr.deinit(self.allocator);
        }
        if (self.code_block) |*code_block| {
            code_block.buffer.deinit(self.allocator);
            for (code_block.instr.items) |*instr| {
                switch (instr.*) {
                    .cpu => {
                        instr.cpu.operands.deinit(self.allocator);
                    },
                    .label => {},
                }
            }
            code_block.instr.deinit(self.allocator);
            code_block.relocations.deinit(self.allocator);
        }
        self.symbols.deinit();
        if (self.g) {
            self.debug_info.deinit(self.allocator);
        }
    }
};
