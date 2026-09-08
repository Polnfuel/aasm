const std = @import("std");
const utils = @import("utils");
const CliArgs = @import("CliArgs");
const Program = @import("Program");
const Lexer = @import("Lexer");
const Parser = @import("Parser");
const Codegen = @import("Codegen");
const ObjFileElf = @import("ObjFileElf");
const Linker = @import("Linker");

pub const Assembler = @This();

pub const AssemblerError = error{AssemblyError} || utils.LoadFileError || Lexer.LexerError || Parser.ParserError || Codegen.CodegenError || ObjFileElf.ObjectError || Linker.LinkerError;

pub const CompUnit = struct {
    rel_path: []const u8,
    program: *Program,
    objfile: *ObjFileElf,
};

comp_units: std.ArrayList(CompUnit) = .empty,

/// First stage of Assembler job
fn createProgramsAndObjfiles(self: *Assembler, cli_inputs: [][]const u8, cli_output: []const u8) AssemblerError!void {
    self.comp_units = try .initCapacity(utils.alloc, cli_inputs.len);
    for (cli_inputs) |path| {
        const rel_path = try utils.alloc.dupe(u8, path);
        errdefer utils.alloc.free(rel_path);
        const abs_path = try std.fs.path.resolve(utils.alloc, &.{ utils.comp_dir, path });
        defer utils.alloc.free(abs_path);

        const content = try utils.loadFileContent(abs_path);
        const basename = std.fs.path.basename(rel_path);

        const program = try utils.alloc.create(Program);
        errdefer utils.alloc.destroy(program);

        program.init(content, basename);
        errdefer program.deinit();

        const object_file = try utils.alloc.create(ObjFileElf);
        errdefer utils.alloc.destroy(object_file);

        try object_file.init(cli_output);
        errdefer object_file.deinit();

        self.comp_units.appendAssumeCapacity(.{ .rel_path = rel_path, .program = program, .objfile = object_file });
    }
}

/// Second stage of Assembler job
fn lexicalAnalyzis(self: *Assembler) AssemblerError!void {
    for (self.comp_units.items) |unit| {
        var lexer = Lexer.init(unit.program);
        try lexer.tokenizeContent();

        // Lexer.printTokens(unit.program);
    }
    utils.deinitStrings();
}

/// Third stage of Assembler job
fn syntaxAnalyzis(self: *Assembler) AssemblerError!void {
    for (self.comp_units.items) |unit| {
        var parser = Parser.init(unit.program);
        try parser.parseTokens();

        if (!unit.program.flags.has_code and !unit.program.flags.has_data and !unit.program.flags.has_bss) {
            utils.printSrcFileError("source file doesn't contain any data or code block", unit.program);
            return AssemblerError.AssemblyError;
        } else if (!unit.program.flags.has_code and utils.flags.debug) {
            // TODO: Still generate debug info about compilation unit
            if (utils.flags.warnings) {
                utils.printSrcFileWarning("source file doesn't contain code block to debug (debug info will not be generated)", unit.program);
            }
        }

        // unit.program.printProgram();
    }
}

/// Fourth stage of Assembler job
fn codegenPrograms(self: *Assembler) AssemblerError!void {
    for (self.comp_units.items) |unit| {
        if (unit.program.flags.has_code) {
            var codegen = Codegen.init(unit.program);
            defer codegen.deinit();
            try codegen.generateCode();

            // unit.program.printSymbolTable();
        }
    }
}

/// Fifth stage of Assembler job
fn resolveObjfiles(self: *Assembler) AssemblerError!void {
    for (self.comp_units.items) |unit| {
        try unit.objfile.compileProgram(unit.program, unit.rel_path);
    }
}

fn writeObjfiles(self: *Assembler) AssemblerError!void {
    for (self.comp_units.items) |unit| {
        try unit.objfile.writeObjFile(unit.program);
    }
}

fn linkObjfiles(self: *Assembler, cli_output: []const u8, cli_search_paths: [][]const u8) AssemblerError!void {
    const linker = try utils.alloc.create(Linker);
    defer utils.alloc.destroy(linker);
    try linker.init(cli_output, self.comp_units.items, cli_search_paths);
    defer linker.deinit();

    try linker.linkObjects();
}

pub fn run(self: *Assembler, cli_args: CliArgs) AssemblerError!void {
    if (cli_args.version) {
        utils.printMessage("AASM v0.1.0 for Linux systems, x86-64 (AMD64) architecture");
        return;
    } else if (cli_args.help) {
        utils.printMessage("Help");
        return;
    } else {
        utils.setFlags(cli_args);
    }

    try self.createProgramsAndObjfiles(cli_args.input_paths.items, cli_args.output_name);
    try self.lexicalAnalyzis();
    try self.syntaxAnalyzis();
    try self.codegenPrograms();
    try self.resolveObjfiles();

    if (cli_args.format == .Object) {
        try self.writeObjfiles();
    } else if (cli_args.format == .Executable) {
        try self.linkObjfiles(cli_args.output_name, cli_args.search_paths.items);
    } else {
        utils.printError("unsupported output format");
        return AssemblerError.AssemblyError;
    }
}

pub fn deinit(self: *Assembler) void {
    for (self.comp_units.items) |unit| {
        unit.objfile.deinit();
        utils.alloc.destroy(unit.objfile);

        unit.program.deinit();
        utils.alloc.destroy(unit.program);

        utils.alloc.free(unit.rel_path);
    }
    self.comp_units.deinit(utils.alloc);
}
