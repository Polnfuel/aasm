const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const assembler = @import("assembler");
const stdbuffers = @import("stdbuffers");

const Assembler = assembler.Assembler;

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
        stdbuffers.printMessage("AASM v0.0.3");
        return;
    } else if (cli_args.h) {
        // TODO: print command line help
        stdbuffers.printMessage("Help");
        return;
    } else if (cli_args.o) {
        // Generate object files for each input file
        for (cli_args.input_files.items) |input| {
            const abs_input = try cwd.realpathAlloc(allocator, input);
            defer allocator.free(abs_input);
            const input_name = std.fs.path.stem(abs_input);
            if (cli_args.output_file.len == 0) {
                var source = try Assembler.new(abs_input, input_name, allocator);
                defer source.deinit();

                try source.genObj();
            }
        }
        switch (cli_args.format) {
            .Object => {
                // Object files generated already, nothing to do next
            },
            .StaticArchive => {
                // Archive object files with ar
            },
            .SharedObject => {
                // Link object files with ld
            },
            .Executable => {
                // Link object files with ld specifying entry symbol
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
