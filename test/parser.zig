const std = @import("std");
const utils = @import("utils");
const CliArgs = @import("CliArgs");
const Program = @import("Program");
const Lexer = @import("Lexer");
const Parser = @import("Parser");

fn parseContent(content: []const u8) ![]const u8 {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try utils.init(alloc, io);
    defer utils.deinit();
    defer utils.deinitStrings();

    utils.setFlags(.{ .quiet = true, .no_warnings = true });

    const program = try utils.alloc.create(Program);
    defer utils.alloc.destroy(program);

    const cont_alloc = try alloc.dupe(u8, content);
    try program.init(cont_alloc, "test.asm");
    defer program.deinit();

    var lexer = Lexer.init(program);
    try lexer.tokenizeContent();

    var parser = Parser.init(program);
    try parser.parseTokens();

    return utils.alloc.dupe(u8, program.data_block.buffer.items);
}

test "types" {
    const content: []const u8 =
        \\@types
        \\enum Key d8 {
        \\    up,
        \\    down,
        \\    left,
        \\    right,
        \\    
        \\    undef: 0xFF,
        \\}
        \\struct Point {
        \\    fld1: d16,
        \\     @align 1
        \\    fld2: d32[2],
        \\     @align 4
        \\    fld3: d8,
        \\    fld4: Key,
        \\}
        \\
        \\@data
        \\reps: Point[4] {
        \\    repeat(3, Point {
        \\        fld1: 66,
        \\        fld3: 90,
        \\        fld4: Key.down,
        \\    }),
        \\    Point {
        \\        fld1: 70,
        \\        fld3: 91,
        \\        fld4: Key.down,
        \\    },
        \\}
        \\ @align 16
        \\key: Key Key.right
        \\st2: d8 19
        \\sr3: d16[3] {11, 12, 16,}
        \\
    ;

    const actual = parseContent(content) catch |err| {
        utils.handleError(err);
        return;
    };
    defer utils.alloc.free(actual);

    const expected: []const u8 = &.{
        0x42, 0,    0,    0, 0,    0,    0,    0,
        0,    0,    0,    0, 0x5A, 0x01, 0,    0,
        0x42, 0,    0,    0, 0,    0,    0,    0,
        0,    0,    0,    0, 0x5A, 0x01, 0,    0,
        0x42, 0,    0,    0, 0,    0,    0,    0,
        0,    0,    0,    0, 0x5A, 0x01, 0,    0,
        0x46, 0,    0,    0, 0,    0,    0,    0,
        0,    0,    0,    0, 0x5B, 0x01, 0,    0,
        0x03, 0x13, 0x0B, 0, 0x0C, 0,    0x10, 0,
    };

    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "arrays" {
    const content: []const u8 =
        \\@data
        \\cls: d8[] {27, "[H", 27, "[J", 27, "[0m"}
        \\targ: d64 1111
        \\
    ;

    const actual = parseContent(content) catch |err| {
        utils.handleError(err);
        return;
    };
    defer utils.alloc.free(actual);

    const expected: []const u8 = &.{
        27,   '[',  'H', 27, '[', 'J', 27, '[',
        '0',  'm',  0,   0,  0,   0,   0,  0,
        0x57, 0x04, 0,   0,  0,   0,   0,  0,
    };

    try std.testing.expectEqualSlices(u8, expected, actual);
}
