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

allocator: std.mem.Allocator,
io: std.Io,
comp_dir: []const u8 = &.{},
strip: bool = false,
debug: bool = false,
pic: bool = false,
warnings: bool = true,
quiet: bool = false,
comp_units: std.ArrayList(CompUnit) = .empty,

pub fn init(io: std.Io, alloc: std.mem.Allocator) AssemblerError!Assembler {
    const cwd_sentinel = try std.process.currentPathAlloc(io, alloc);
    const cwd = try alloc.dupe(u8, @ptrCast(cwd_sentinel));
    alloc.free(cwd_sentinel);

    const aasm = Assembler{
        .allocator = alloc,
        .io = io,
        .comp_dir = cwd,
    };

    return aasm;
}

fn loadFileContent(self: *Assembler, abs_path: []const u8) LoadFileError![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(self.io, abs_path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            std.Io.File.OpenError.FileNotFound => {
                errprint.printErrorFmt("file {s} not found", .{abs_path});
            },
            else => {},
        }
        return err;
    };
    defer file.close(self.io);

    const file_stat = try file.stat(self.io);
    const file_size = file_stat.size;

    if (file_size > std.math.pow(u64, 2, 20)) {
        errprint.printErrorFmt("file {s} with size {d} B exceeds 1 MiB file size limit", .{ abs_path, file_size });
        return LoadFileError.SourceFileTooBig;
    }

    var content = try self.allocator.alloc(u8, file_size + 1);
    errdefer self.allocator.free(content);

    var file_reader = file.reader(self.io, content);
    var reader = &file_reader.interface;
    try reader.readSliceAll(content[0..file_size]);
    content[file_size] = '\n';

    return content;
}

pub fn run(self: *Assembler, cli_args: CliArgs) AssemblerError!void {
    if (cli_args.v) {
        errprint.printMessage("AASM v0.1.0 for Linux systems, x86-64 (AMD64) architecture");
        return;
    } else if (cli_args.h) {
        errprint.printMessage("Help");
        return;
    } else {
        self.strip = cli_args.s;
        self.debug = cli_args.g;
        self.pic = cli_args.pic;
        self.warnings = !cli_args.w;
        self.quiet = cli_args.q;
    }
    for (cli_args.input_files.items) |input_rel_path| {
        const inp_rel_path_copy = try self.allocator.dupe(u8, input_rel_path);

        const abs_path = try std.fs.path.resolve(self.allocator, &.{ self.comp_dir, input_rel_path });
        defer self.allocator.free(abs_path);

        // std.debug.print("aasm.abs_path: {s}\n", .{abs_path});
        // std.debug.print("aasm.rel_path: {s}\n", .{input_rel_path});

        const basename = std.fs.path.basename(inp_rel_path_copy);

        const program = try self.allocator.create(Program);
        errdefer self.allocator.destroy(program);

        const content = try self.loadFileContent(abs_path);

        program.init(content, basename, self.allocator, self.debug, self.pic, self.warnings, self.quiet);
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

        if (!self.quiet) {
            program.printSymbolTable();
        }

        const object_file = try self.allocator.create(ObjFileElf);
        errdefer self.allocator.destroy(object_file);

        try object_file.init(self.allocator);
        errdefer object_file.deinit(self.allocator);

        try object_file.compileProgram(program, self.comp_dir, inp_rel_path_copy);

        try self.comp_units.append(self.allocator, .{ .rel_path = inp_rel_path_copy, .program = program, .objfile = object_file });
    }

    if (cli_args.format == .Object) {
        for (self.comp_units.items) |unit| {
            try unit.objfile.writeObjFile(self.io, unit.program);
        }
    } else if (cli_args.format == .Executable) {
        const linker = try self.allocator.create(Linker);
        try linker.init(cli_args.output_file, self.allocator, self.io, self.comp_units.items, .{ .debug = cli_args.g, .strip = cli_args.s, .quiet = cli_args.q });
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
        self.allocator.destroy(unit.program);

        self.allocator.free(unit.rel_path);
    }
    self.allocator.free(self.comp_dir);
}
