const std = @import("std");
const object = @import("object");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const file_name = args[1];

    var program = try object.Program.new(@ptrCast(file_name), allocator);
    defer program.deinit();
    errdefer program.deinit();

    try program.tokenize();
    try program.parse();

    try program.genDataCodeBuffers();
    try program.genObjectFile("long.o");
}
