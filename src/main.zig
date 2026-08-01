const std = @import("std");
const errprint = @import("errprint");
const CliArgs = @import("CliArgs");
const Assembler = @import("Assembler");

fn startAASM(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    try errprint.init(allocator, io);
    defer errprint.deinit(allocator);

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cli_args = try CliArgs.parse(args, allocator);
    defer cli_args.deinit(allocator);

    var aasm = try Assembler.init(io, allocator);
    defer aasm.deinit();

    try aasm.run(cli_args);
}

pub fn main(init: std.process.Init) void {
    startAASM(init) catch |err| {
        errprint.handleError(err);
    };
    std.process.exit(0);
}
