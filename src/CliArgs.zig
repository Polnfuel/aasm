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

input_files: std.ArrayList([]const u8),
output_file: []const u8,
h: bool,
v: bool,
o: bool,
f: bool,
s: bool,
g: bool,
pic: bool,
w: bool,
q: bool,
format: OutputFormat,

pub fn parse(args: []const [:0]const u8, allocator: std.mem.Allocator) CliError!CliArgs {
    var cli_args: CliArgs = .{
        .input_files = .empty,
        .output_file = &.{},
        .h = false,
        .v = false,
        .o = false,
        .f = false,
        .s = false,
        .g = false,
        .pic = false,
        .w = false,
        .q = false,
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
                    if (arg.len == 2 and args.len == 2) {
                        cli_args.v = true;
                    } else {
                        errprint.printError("-v flag with unexpected parameters");
                        return CliError.CliParseFailed;
                    }
                },
                'h' => {
                    if (arg.len == 2 and args.len == 2) {
                        cli_args.h = true;
                    } else {
                        errprint.printError("-h flag with unexpected parameters");
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
                    cli_args.f = true;
                },
                's' => {
                    cli_args.s = true;
                },
                'g' => {
                    cli_args.g = true;
                },
                'p' => {
                    if (std.mem.eql(u8, arg[1..], "pic")) {
                        cli_args.pic = true;
                    } else {
                        errprint.printErrorFmt("unknown option: {s}", .{arg});
                        return CliError.CliParseFailed;
                    }
                },
                'w' => {
                    cli_args.w = true;
                },
                'q' => {
                    cli_args.q = true;
                },
                else => {
                    errprint.printErrorFmt("unknown option: -{c}", .{option});
                    return CliError.CliParseFailed;
                },
            }
        } else {
            try cli_args.input_files.append(allocator, @ptrCast(arg));
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
    if (self.input_files.items.len == 0) {
        if (self.o or self.f or self.s or self.g) {
            errprint.printError("expected at least one input file");
            return CliError.CliParseFailed;
        }
    } else {
        if (self.o) {
            if (self.output_file.len == 0) {
                errprint.printError("output file name must be specified");
                return CliError.CliParseFailed;
            } else if (self.input_files.items.len > 1 and self.format == .Object) {
                errprint.printError("cannot assemble multiple sources into one object file");
                return CliError.CliParseFailed;
            }
        } else if (self.f) {
            if (self.format == .Executable) {
                errprint.printError("output file name must be specified");
                return CliError.CliParseFailed;
            }
        }
        if (self.s) {
            if (self.g) {
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
    for (self.input_files.items) |input| {
        std.debug.print("{s} ", .{input});
    }
    if (self.o) {
        std.debug.print("=> ({s})", .{self.output_file});
    }
    std.debug.print("| f - {t} |", .{self.format});
    if (self.s) {
        std.debug.print("| strip |", .{});
    }
    if (self.g) {
        std.debug.print("| with debug info |", .{});
    }
    std.debug.print("\n", .{});
}

pub fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
    self.input_files.deinit(allocator);
}
