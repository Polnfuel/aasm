const std = @import("std");
const lexer = @import("lexer");
const parser = @import("parser");
const datagen = @import("datagen");
const codegen = @import("codegen");
const compositor = @import("compositor");

fn loadFile(file_name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
    defer file.close();

    const file_stat = try file.stat();
    const file_size = file_stat.size;
    std.debug.print("Loaded {d} bytes from {s}\n", .{ file_size, file_name });

    const content = try allocator.alloc(u8, file_size + 1);

    var file_reader = file.reader(content);
    var reader = &file_reader.interface;
    try reader.readSliceAll(content[0..file_size]);
    content[file_size] = '\n';

    return content;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    // defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const file_name = args[1];

    const content = try loadFile(@ptrCast(file_name), allocator);
    defer allocator.free(content);

    try lexer.tokenizeContent(content, allocator);
    defer lexer.tokens.deinit(allocator);

    // lexer.printTokens();

    try parser.parseTokensToAST(allocator);
    defer parser.cl_table.deinit();
    defer parser.dl_table.deinit();
    defer parser.program.sections.deinit(allocator);

    // parser.printAST();

    for (parser.program.sections.items) |*section| {
        if (section.type == .Data) {
            try datagen.bufferizeDataSection(&section.section.data, allocator);
        }
    }
    for (parser.program.sections.items) |*section| {
        if (section.type == .Code) {
            try codegen.bufferizeCodeSection(&section.section.code, allocator, 0x401000);
        }
    }
    defer datagen.data_buffer.deinit(allocator);
    defer codegen.code_buffer.deinit(allocator);
    defer codegen.rellocations.deinit();

    std.debug.print("Code buffer length = {d}\n", .{codegen.code_buffer.items.len});
    std.debug.print("Data buffer length = {d}\n", .{datagen.data_buffer.items.len});

    try compositor.genELF(allocator, "long");
}
