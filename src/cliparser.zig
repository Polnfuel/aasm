const std = @import("std");
const stdbuffers = @import("stdbuffers");

pub const CliError = error{CliParseFailed} || std.mem.Allocator.Error;

const OutputFormat = enum {
    Object,
    StaticArchive,
    SharedObject,
    Executable,
};

pub const CliArgs = struct {
    input_files: std.ArrayList([]const u8),
    output_file: []const u8,
    h: bool,
    v: bool,
    o: bool,
    f: bool,
    format: OutputFormat,

    pub fn parseArgs(args: [][:0]u8, allocator: std.mem.Allocator) CliError!CliArgs {
        var cli_args: CliArgs = .{
            .input_files = .empty,
            .output_file = undefined,
            .h = false,
            .v = false,
            .o = false,
            .f = false,
            .format = .Object,
        };
        errdefer cli_args.deinit(allocator);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (arg[0] == '-' and arg.len > 1) {
                const option = arg[1];
                switch (option) {
                    'o' => {
                        var output: []const u8 = &.{};
                        if (arg.len == 2) {
                            // -o <filename>
                            if (i + 1 < args.len and args[i + 1][0] != '-') {
                                output = @ptrCast(args[i + 1]);
                                i += 1;
                            }
                        } else {
                            // -o<filename>
                            output = @ptrCast(arg[2..]);
                        }
                        cli_args.o = true;
                        cli_args.output_file = output;
                    },
                    'v' => {
                        if (arg.len == 2) {
                            cli_args.v = true;
                        } else {
                            stdbuffers.printError("-v flag with unexpected parameters");
                            return CliError.CliParseFailed;
                        }
                    },
                    'h' => {
                        if (arg.len == 2) {
                            cli_args.h = true;
                        } else {
                            stdbuffers.printError("-h flag with unexpected parameters");
                            return CliError.CliParseFailed;
                        }
                    },
                    'f' => {
                        var format: []const u8 = undefined;
                        if (arg.len == 2) {
                            // -f <format>
                            if (i + 1 < args.len and args[i + 1][0] != '-') {
                                format = @ptrCast(args[i + 1]);
                                i += 1;
                            } else {
                                stdbuffers.printError("expected format parameter following -f flag");
                                return CliError.CliParseFailed;
                            }
                        } else {
                            // -f<format>
                            format = @ptrCast(arg[2..]);
                        }
                        if (std.mem.eql(u8, format, "obj")) {
                            cli_args.format = .Object;
                        } else if (std.mem.eql(u8, format, "lib")) {
                            cli_args.format = .StaticArchive;
                        } else if (std.mem.eql(u8, format, "exe")) {
                            cli_args.format = .Executable;
                        } else if (std.mem.eql(u8, format, "dyn")) {
                            cli_args.format = .SharedObject;
                        } else {
                            stdbuffers.printError("unknown parameter after -f flag");
                            return CliError.CliParseFailed;
                        }
                        cli_args.f = true;
                    },
                    else => {
                        stdbuffers.printErrorFormatted("unknown option: -{c}", .{option});
                        return CliError.CliParseFailed;
                    },
                }
            } else {
                try cli_args.input_files.append(allocator, @ptrCast(arg));
            }
        }
        if (i == 1) {
            stdbuffers.printError("at least one option must be provided to aasm (use -h option to list all available options)");
            return CliError.CliParseFailed;
        }
        try cli_args.checkArgs();
        return cli_args;
    }

    pub fn checkArgs(self: CliArgs) CliError!void {
        if (self.h) {
            if (self.v or self.o or self.f or self.input_files.items.len > 0) {
                stdbuffers.printError("-h flag with unexpected parameters");
                return CliError.CliParseFailed;
            }
        }
        if (self.v) {
            if (self.h or self.o or self.f or self.input_files.items.len > 0) {
                stdbuffers.printError("-v flag with unexpected parameters");
                return CliError.CliParseFailed;
            }
        }
        if (self.o) {
            if (self.input_files.items.len == 0) {
                stdbuffers.printError("expected at least one input file");
                return CliError.CliParseFailed;
            } else if (self.input_files.items.len > 1 and self.output_file.len > 0) {
                if (self.format == .Object) {
                    stdbuffers.printError("cannot combine multiple sources into one object file");
                    return CliError.CliParseFailed;
                }
            }
        }
    }

    pub fn printArgs(self: CliArgs) void {
        if (self.o) {
            for (self.input_files.items) |input| {
                std.debug.print("{s} ", .{input});
            }
            std.debug.print("=> {s} ", .{self.output_file});
        }
        if (self.f) {
            std.debug.print("| f - {t} |", .{self.format});
        }
        std.debug.print("\n", .{});
    }

    pub fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        self.input_files.deinit(allocator);
    }
};

// aasm -h
// aasm -v
// aasm file1.asm -o  (generates object file with the name file1.o)
// aasm file1.asm -o -f exe  (generates executable file with the name file1)
// aasm file1.asm -o file  (generates object file with the name file)
// aasm file1.asm -f lib  (generates static archive containing file1.o with the name file1.a)
// aasm file1.asm file2.asm -o  (generates object files with the names file1.o and file2.o)
// aasm file1.asm file2.asm -o

// f unspecified or obj, o specified - several input files produce several object files, each for one input
// -- output must be empty, else - error
// f lib, o specified - several input files produce one static archive with the output name and .a extension
// f exe, o specified - several input to one exec
//
