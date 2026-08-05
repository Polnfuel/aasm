const std = @import("std");
const errprint = @import("errprint");
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

alloc: std.mem.Allocator,
io: std.Io,
comp_dir: []const u8 = &.{},
flags: AasmFlags,
comp_units: std.ArrayList(CompUnit) = .empty,

pub fn init(io: std.Io, alloc: std.mem.Allocator) AssemblerError!Assembler {
    const cwd_sentinel = try std.process.currentPathAlloc(io, alloc);
    const cwd = try alloc.dupe(u8, @ptrCast(cwd_sentinel));
    alloc.free(cwd_sentinel);

    const aasm = Assembler{
        .alloc = alloc,
        .io = io,
        .comp_dir = cwd,
        .flags = AasmFlags{},
    };

    return aasm;
}

fn loadFileContent(self: *Assembler, abs_path: []const u8) LoadFileError![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(self.io, abs_path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            std.Io.File.OpenError.FileNotFound => {
                errprint.printErrorFmt("file '{s}' not found", .{abs_path});
            },
            else => {},
        }
        return err;
    };
    defer file.close(self.io);

    const file_stat = try file.stat(self.io);
    const file_size = file_stat.size;

    if (file_size > std.math.pow(u64, 2, 20)) {
        errprint.printErrorFmt("file '{s}' with size {d} B exceeds 1 MiB file size limit", .{ abs_path, file_size });
        return LoadFileError.SourceFileTooBig;
    }

    var content = try self.alloc.alloc(u8, file_size + 1);
    errdefer self.alloc.free(content);

    var file_reader = file.reader(self.io, content);
    var reader = &file_reader.interface;
    try reader.readSliceAll(content[0..file_size]);
    content[file_size] = '\n';

    return content;
}

pub fn run(self: *Assembler, cli_args: CliArgs) AssemblerError!void {
    if (cli_args.version) {
        errprint.printMessage("AASM v0.1.0 for Linux systems, x86-64 (AMD64) architecture");
        return;
    } else if (cli_args.help) {
        errprint.printMessage("Help");
        return;
    } else {
        self.flags.strip = cli_args.strip;
        self.flags.debug = cli_args.debug;
        self.flags.pic = cli_args.pic;
        self.flags.warnings = !cli_args.no_warnings;
        self.flags.quiet = cli_args.quiet;
    }
    for (cli_args.input_paths.items) |input_rel_path| {
        const inp_rel_path_copy = try self.alloc.dupe(u8, input_rel_path);

        const abs_path = try std.fs.path.resolve(self.alloc, &.{ self.comp_dir, input_rel_path });
        defer self.alloc.free(abs_path);

        // std.debug.print("aasm.abs_path: {s}\n", .{abs_path});
        // std.debug.print("aasm.rel_path: {s}\n", .{inp_rel_path_copy});

        const basename = std.fs.path.basename(inp_rel_path_copy);

        // std.debug.print("aasm.basename: {s}\n", .{basename});

        const program = try self.alloc.create(Program);
        errdefer self.alloc.destroy(program);

        const content = try self.loadFileContent(abs_path);

        program.init(content, basename, self.alloc, self.flags.debug, self.flags.pic, self.flags.warnings, self.flags.quiet);
        errdefer program.deinit();

        try program.lexicalAnalyzis();
        // lexer.printTokens(program.tokens);

        try program.syntaxAnalyzis();
        // program.printProgram();

        if (!program.flags.has_code and !program.flags.has_data) {
            errprint.printSrcFileError("source file doesn't contain any data or code block", program.file_name);
            return AssemblerError.AssemblyError;
        } else if (!program.flags.has_code and program.flags.debug) {
            program.flags.debug = false;
            if (program.flags.warnings) {
                errprint.printSrcFileWarning("source file doesn't contain code block to debug (debug info will not be generated)", program.file_name);
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

        const object_file = try self.alloc.create(ObjFileElf);
        errdefer self.alloc.destroy(object_file);

        try object_file.init(self.alloc, cli_args.output_name);
        errdefer object_file.deinit(self.alloc);

        try object_file.compileProgram(program, self.comp_dir, inp_rel_path_copy);

        try self.comp_units.append(self.alloc, .{ .rel_path = inp_rel_path_copy, .program = program, .objfile = object_file });
    }

    if (cli_args.format == .Object) {
        for (self.comp_units.items) |unit| {
            try unit.objfile.writeObjFile(self.io, unit.program);
        }
    } else if (cli_args.format == .Executable) {
        const linker = try self.alloc.create(Linker);
        try linker.init(cli_args.output_name, self.alloc, self.io, self.comp_units.items, .{ .debug = self.flags.debug, .strip = self.flags.strip, .quiet = self.flags.quiet }, cli_args.search_paths);
        defer linker.deinit();

        try linker.linkObjects();
    } else {
        errprint.printError("unsupported output format");
        return AssemblerError.AssemblyError;
    }
}

pub fn deinit(self: *Assembler) void {
    for (self.comp_units.items) |unit| {
        unit.objfile.deinit(unit.program.alloc);
        unit.program.alloc.destroy(unit.objfile);

        unit.program.deinit();
        self.alloc.destroy(unit.program);

        self.alloc.free(unit.rel_path);
    }
    self.alloc.free(self.comp_dir);
}
