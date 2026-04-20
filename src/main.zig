const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const assembler = @import("assembler");
const stdbuffers = @import("stdbuffers");
const linker = @import("linker");

const Assembler = assembler.Assembler;
const Linker = linker.Linker;

fn startAASM() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;

    try stdbuffers.init(allocator);
    defer stdbuffers.deinit(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli_args = try cli.CliArgs.parseArgs(args, allocator);
    defer cli_args.deinit(allocator);

    const cwd = std.fs.cwd();

    if (cli_args.v) {
        stdbuffers.printMessage("AASM v0.0.5");
        return;
    } else if (cli_args.h) {
        // TODO: print command line help
        stdbuffers.printMessage("Help");
        return;
    } else if (cli_args.o) {
        // Generate object files data for each input source file
        var object_files: std.ArrayList(Assembler) = .empty;
        defer {
            for (object_files.items) |*file| {
                file.deinit();
            }
            object_files.deinit(allocator);
        }

        for (cli_args.input_files.items) |input| {
            const abs_input = try cwd.realpathAlloc(allocator, input);
            defer allocator.free(abs_input);
            const input_name = std.fs.path.stem(abs_input);

            var source = try Assembler.new(abs_input, input_name, allocator);
            errdefer source.deinit();

            try source.genObj();
            try object_files.append(allocator, source);
        }
        switch (cli_args.format) {
            .Object => {
                // Object files data generated already, can create files
                for (object_files.items) |*file| {
                    try file.writeObj();
                }
            },
            .Executable => {
                // Linking object files data into one executable
                var ld = Linker.new(allocator, object_files.items, cli_args.output_file, cli_args.s);
                defer ld.deinit();
                try ld.linkExe();
            },
            .StaticArchive => {
                // Archive object files with ar
            },
            .SharedObject => {
                // Link object files with ld
            },
        }
    } else {
        return;
    }
}

pub fn main() void {
    startAASM() catch |err| {
        stdbuffers.handleError(err);
    };
    std.process.exit(0);
}
