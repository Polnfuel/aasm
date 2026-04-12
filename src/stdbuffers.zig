const std = @import("std");

var stdout_buffer: []u8 = undefined;
var stderr_buffer: []u8 = undefined;
var stdout_writer: std.fs.File.Writer = undefined;
var stderr_writer: std.fs.File.Writer = undefined;
var stdout: *std.Io.Writer = undefined;
var stderr: *std.Io.Writer = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    stdout_buffer = try allocator.alloc(u8, 1024);
    stderr_buffer = try allocator.alloc(u8, 1024);
    stdout_writer = std.fs.File.stdout().writer(stdout_buffer);
    stderr_writer = std.fs.File.stderr().writer(stderr_buffer);
    stdout = &stdout_writer.interface;
    stderr = &stderr_writer.interface;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    allocator.free(stdout_buffer);
    allocator.free(stderr_buffer);
}

pub fn printMessage(comptime message: []const u8) void {
    stdout.print("{s}\n", .{message}) catch |err| panicInternalError(err);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printError(comptime err_message: []const u8) void {
    stderr.print("\x1b[38;2;224;32;32m\x1b[1merror:\x1b[0m {s}\n", .{err_message}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printErrorFormatted(comptime err_message: []const u8, args: anytype) void {
    stderr.print("\x1b[38;2;224;32;32m\x1b[1merror:\x1b[0m ", .{}) catch |err| panicInternalError(err);
    stderr.print(err_message, args) catch |err| panicInternalError(err);
    stderr.print("\n", .{}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printSourceError(file_name: []const u8, comptime err_message: []const u8, file_content: []const u8, line: u16) void {
    const slice = getLine(file_content, line);
    stderr.print("\x1b[4m{s}:{d}\x1b[0m: ", .{ file_name, line }) catch |err| panicInternalError(err);
    printError(err_message);
    stderr.print("{s}\n", .{slice}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printSourceErrorFormatted(file_name: []const u8, comptime err_message: []const u8, args: anytype, file_content: []const u8, line: u16) void {
    const slice = getLine(file_content, line);
    stderr.print("\x1b[4m{s}:{d}\x1b[0m: ", .{ file_name, line }) catch |err| panicInternalError(err);
    printErrorFormatted(err_message, args);
    stderr.print("{s}\n", .{slice}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

fn getLine(file_content: []const u8, line: u16) []const u8 {
    var cur_line: usize = 1;
    var start: usize = 0;
    var end: usize = 0;
    for (file_content, 0..) |byte, i| {
        if (byte == '\n') {
            cur_line += 1;
            if (cur_line == line) {
                start = i + 1;
            } else if (cur_line == line + 1) {
                end = i;
            }
        }
    }
    return file_content[start..end];
}

fn panicInternalError(err: anyerror) void {
    std.debug.print("\x1b[38;2;224;32;32m\x1b[1merror:\x1b[0m internal assembler crash ({t})\n", .{err});
    std.process.exit(1);
}

pub fn handleError(err: anyerror) void {
    switch (err) {
        error.CliParseFailed, error.LexerAnalyzisFailed, error.ParsingFailed, error.DataGenFailed, error.CodeGenFailed, error.ProgramFailed, error.ObjectError, error.LinkingFailed => {
            std.process.exit(1);
        },
        else => {
            panicInternalError(err);
        },
    }
}
