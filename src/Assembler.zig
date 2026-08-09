const std = @import("std");
const utils = @import("utils");
const CliArgs = @import("CliArgs");
const Program = @import("Program");
const lexer = @import("lexer");
const Parser = @import("Parser");
const datagen = @import("datagen");
const Codegen = @import("Codegen");
const ObjFileElf = @import("ObjFileElf");
const Linker = @import("Linker");

pub const Assembler = @This();

const LoadFileError = error{SourceFileTooBig} || std.process.CurrentPathAllocError || std.Io.File.OpenError || std.Io.File.StatError || std.mem.Allocator.Error || std.Io.Reader.Error;
pub const AssemblerError = error{AssemblyError} || LoadFileError || lexer.LexerError || Parser.ParserError || datagen.DatagenError || Codegen.CodegenError || ObjFileElf.ObjectError || Linker.LinkerError;

pub const CompUnit = struct {
    rel_path: []const u8,
    program: *Program,
    objfile: *ObjFileElf,
};

pub const AasmFlags = struct {
    strip: bool = false,
    debug: bool = false,
    pic: bool = false,
    warnings: bool = true,
    quiet: bool = false,
};

comp_dir: []const u8 = &.{},
flags: AasmFlags,
comp_units: std.ArrayList(CompUnit) = .empty,

pub fn init() AssemblerError!Assembler {
    const cwd_sentinel = try std.process.currentPathAlloc(utils.io, utils.alloc);
    const cwd = try utils.alloc.dupe(u8, @ptrCast(cwd_sentinel));
    utils.alloc.free(cwd_sentinel);

    const aasm = Assembler{
        .comp_dir = cwd,
        .flags = AasmFlags{},
    };

    return aasm;
}

fn loadFileContent(abs_path: []const u8) LoadFileError![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(utils.io, abs_path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            std.Io.File.OpenError.FileNotFound => {
                utils.printErrorFmt("file '{s}' not found", .{abs_path});
            },
            else => {},
        }
        return err;
    };
    defer file.close(utils.io);

    const file_stat = try file.stat(utils.io);
    const file_size = file_stat.size;

    if (file_size > std.math.pow(u64, 2, 20)) {
        utils.printErrorFmt("file '{s}' with size {d} B exceeds 1 MiB file size limit", .{ abs_path, file_size });
        return LoadFileError.SourceFileTooBig;
    }

    var content = try utils.alloc.alloc(u8, file_size + 1);
    errdefer utils.alloc.free(content);

    var file_reader = file.reader(utils.io, content);
    var reader = &file_reader.interface;
    try reader.readSliceAll(content[0..file_size]);
    content[file_size] = '\n';

    return content;
}

pub fn run(self: *Assembler, cli_args: CliArgs) AssemblerError!void {
    if (cli_args.version) {
        utils.printMessage("AASM v0.1.0 for Linux systems, x86-64 (AMD64) architecture");
        return;
    } else if (cli_args.help) {
        utils.printMessage("Help");
        return;
    } else {
        self.flags.strip = cli_args.strip;
        self.flags.debug = cli_args.debug;
        self.flags.pic = cli_args.pic;
        self.flags.warnings = !cli_args.no_warnings;
        self.flags.quiet = cli_args.quiet;
    }
    for (cli_args.input_paths.items) |input_rel_path| {
        const inp_rel_path_copy = try utils.alloc.dupe(u8, input_rel_path);

        const abs_path = try std.fs.path.resolve(utils.alloc, &.{ self.comp_dir, input_rel_path });
        defer utils.alloc.free(abs_path);

        // std.debug.print("aasm.abs_path: {s}\n", .{abs_path});
        // std.debug.print("aasm.rel_path: {s}\n", .{inp_rel_path_copy});

        const basename = std.fs.path.basename(inp_rel_path_copy);

        // std.debug.print("aasm.basename: {s}\n", .{basename});

        const program = try utils.alloc.create(Program);
        errdefer utils.alloc.destroy(program);

        const content = try loadFileContent(abs_path);

        program.init(content, basename, self.flags.debug, self.flags.pic, self.flags.warnings, self.flags.quiet);
        errdefer program.deinit();

        try program.lexicalAnalyzis();
        // lexer.printTokens(program.tokens);

        try program.syntaxAnalyzis();
        // program.printProgram();

        if (!program.flags.has_code and !program.flags.has_data) {
            utils.printSrcFileError("source file doesn't contain any data or code block", program.file_name);
            return AssemblerError.AssemblyError;
        } else if (!program.flags.has_code and program.flags.debug) {
            program.flags.debug = false;
            if (program.flags.warnings) {
                utils.printSrcFileWarning("source file doesn't contain code block to debug (debug info will not be generated)", program.file_name);
            }
        }

        if (program.flags.has_data) {
            try program.dataGen();
        }
        if (program.flags.has_code) {
            try program.codeGen();
        }

        if (!self.flags.quiet) {
            program.printSymbolTable();
        }

        const object_file = try utils.alloc.create(ObjFileElf);
        errdefer utils.alloc.destroy(object_file);

        try object_file.init(cli_args.output_name);
        errdefer object_file.deinit();

        try object_file.compileProgram(program, self.comp_dir, inp_rel_path_copy);

        try self.comp_units.append(utils.alloc, .{ .rel_path = inp_rel_path_copy, .program = program, .objfile = object_file });
    }

    if (cli_args.format == .Object) {
        for (self.comp_units.items) |unit| {
            try unit.objfile.writeObjFile(unit.program);
        }
    } else if (cli_args.format == .Executable) {
        const linker = try utils.alloc.create(Linker);
        defer utils.alloc.destroy(linker);
        try linker.init(cli_args.output_name, self.comp_units.items, .{ .debug = self.flags.debug, .strip = self.flags.strip, .quiet = self.flags.quiet }, cli_args.search_paths);
        defer linker.deinit();

        try linker.linkObjects();
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
    utils.alloc.free(self.comp_dir);
}
