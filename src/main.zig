const std = @import("std");
const utils = @import("utils");
const CliArgs = @import("CliArgs");
const Assembler = @import("Assembler");

fn startAASM(init: std.process.Init) !void {
    try utils.init(init.gpa, init.io);
    defer utils.deinit();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cli_args = try CliArgs.parse(args);
    defer cli_args.deinit();

    var aasm = Assembler{};
    defer aasm.deinit();

    try aasm.run(cli_args);
}

pub fn main(init: std.process.Init) u8 {
    startAASM(init) catch |err| {
        utils.handleError(err);
        return 1;
    };
    return 0;
}
