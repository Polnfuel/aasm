const std = @import("std");
const errprint = @import("errprint");

pub const CliArgs = @This();

pub const CliError = error{CliParseFailed} || std.mem.Allocator.Error;

const OutputFormat = enum {
    Object,
    StaticArchive,
    SharedObject,
    Executable,
};

input_paths: std.ArrayList([]const u8) = .empty,
search_paths: std.ArrayList([]const u8) = .empty,
output_name: []const u8 = &.{},
help: bool = false,
version: bool = false,
strip: bool = false,
debug: bool = false,
pic: bool = false,
no_warnings: bool = false,
quiet: bool = false,
format: OutputFormat = .Object,

pub fn parse(args: []const [:0]const u8, alloc: std.mem.Allocator) CliError!CliArgs {
    var cli_args = CliArgs{};
    errdefer cli_args.deinit(alloc);

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
                        } else {
                            errprint.printError("expected output filename following -o flag");
                            return CliError.CliParseFailed;
                        }
                    } else {
                        // -o<filename>
                        output = @ptrCast(arg[2..]);
                    }
                    cli_args.output_name = output;
                },
                'f' => {
                    var format: []const u8 = &.{};
                    if (arg.len == 2) {
                        // -f <format>
                        if (i + 1 < args.len and args[i + 1][0] != '-') {
                            format = @ptrCast(args[i + 1]);
                            i += 1;
                        } else {
                            errprint.printError("expected format parameter following -f flag");
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
                        errprint.printError("unknown parameter after -f flag");
                        return CliError.CliParseFailed;
                    }
                },
                'L' => {
                    var lib_path: []const u8 = &.{};
                    if (arg.len == 2) {
                        // -L <path>
                        if (i + 1 < args.len and args[i + 1][0] != '-') {
                            lib_path = @ptrCast(args[i + 1]);
                            i += 1;
                        } else {
                            errprint.printError("expected library search path following -L flag");
                            return CliError.CliParseFailed;
                        }
                    } else {
                        // -L<path>
                        lib_path = @ptrCast(arg[2..]);
                    }
                    try cli_args.search_paths.append(alloc, lib_path);
                },
                'p' => {
                    if (std.mem.eql(u8, arg[1..], "pic")) {
                        cli_args.pic = true;
                    } else {
                        errprint.printErrorFmt("unknown option: {s}", .{arg});
                        return CliError.CliParseFailed;
                    }
                },
                'v' => {
                    if (arg.len == 2 and args.len == 2) {
                        cli_args.version = true;
                    } else {
                        errprint.printError("-v flag with unexpected parameters");
                        return CliError.CliParseFailed;
                    }
                },
                'h' => {
                    if (arg.len == 2 and args.len == 2) {
                        cli_args.help = true;
                    } else {
                        errprint.printError("-h flag with unexpected parameters");
                        return CliError.CliParseFailed;
                    }
                },
                'w' => {
                    cli_args.no_warnings = true;
                },
                'q' => {
                    cli_args.quiet = true;
                },
                's' => {
                    cli_args.strip = true;
                },
                'g' => {
                    cli_args.debug = true;
                },
                else => {
                    errprint.printErrorFmt("unknown option: -{c}", .{option});
                    return CliError.CliParseFailed;
                },
            }
        } else {
            try cli_args.input_paths.append(alloc, @ptrCast(arg));
        }
    }
    if (i == 1) {
        errprint.printError("at least one source file or option must be provided to aasm (use -h option to list all available options)");
        return CliError.CliParseFailed;
    }
    try cli_args.check();
    return cli_args;
}

fn check(self: *CliArgs) CliError!void {
    if (self.input_paths.items.len == 0) {
        if (!self.help and !self.version) {
            errprint.printError("expected at least one input file");
            return CliError.CliParseFailed;
        }
    } else {
        if (self.output_name.len > 0) {
            if (self.input_paths.items.len > 1 and self.format == .Object) {
                errprint.printError("cannot assemble multiple sources into one object file");
                return CliError.CliParseFailed;
            }
        } else if (self.format != .Object) {
            errprint.printError("output file name must be specified");
            return CliError.CliParseFailed;
        }
        if (self.strip) {
            if (self.debug) {
                errprint.printError("cannot add debug info and strip at the same time");
                return CliError.CliParseFailed;
            } else if (self.format == .Object or self.format == .StaticArchive) {
                errprint.printError("cannot strip from object file(s) or archive");
                return CliError.CliParseFailed;
            }
        }
    }
}

pub fn print(self: CliArgs) void {
    for (self.input_paths.items) |input| {
        std.debug.print("{s} ", .{input});
    }
    if (self.output_name.len > 0) {
        std.debug.print("=> ({s})", .{self.output_name});
    }
    std.debug.print("| f - {t} |", .{self.format});
    if (self.strip) {
        std.debug.print("| strip |", .{});
    }
    if (self.debug) {
        std.debug.print("| with debug info |", .{});
    }
    if (self.quiet) {
        std.debug.print("| quiet |", .{});
    }
    if (self.no_warnings) {
        std.debug.print("| no-warning |", .{});
    }
    for (self.search_paths.items) |path| {
        std.debug.print("{s} ", .{path});
    }
    std.debug.print("\n", .{});
}

pub fn deinit(self: *CliArgs, alloc: std.mem.Allocator) void {
    self.input_paths.deinit(alloc);
    self.search_paths.deinit(alloc);
}
