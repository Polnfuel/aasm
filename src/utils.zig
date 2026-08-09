const std = @import("std");

pub var alloc: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
pub var comp_dir: []const u8 = undefined;
var stdout_buffer: []u8 = undefined;
var stderr_buffer: []u8 = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var stderr_writer: std.Io.File.Writer = undefined;
var stdout: *std.Io.Writer = undefined;
var stderr: *std.Io.Writer = undefined;

pub fn init(allocator: std.mem.Allocator, inout: std.Io) (std.mem.Allocator.Error || std.process.CurrentPathAllocError)!void {
    alloc = allocator;
    io = inout;
    stdout_buffer = try alloc.alloc(u8, 1024);
    stderr_buffer = try alloc.alloc(u8, 1024);
    stdout_writer = std.Io.File.stdout().writer(io, stdout_buffer);
    stderr_writer = std.Io.File.stderr().writer(io, stderr_buffer);
    stdout = &stdout_writer.interface;
    stderr = &stderr_writer.interface;
    const cwd_sentinel = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd_sentinel);
    comp_dir = try alloc.dupe(u8, @ptrCast(cwd_sentinel));
}

pub fn deinit() void {
    alloc.free(stdout_buffer);
    alloc.free(stderr_buffer);
    alloc.free(comp_dir);
}

pub fn printMessage(comptime message: []const u8) void {
    stdout.print("{s}\n\n", .{message}) catch |err| panicInternalError(err);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printMessageFmt(comptime message: []const u8, args: anytype) void {
    stdout.print(message, args) catch |err| panicInternalError(err);
    stdout.print("\n\n", .{}) catch |err| panicInternalError(err);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printError(comptime err_message: []const u8) void {
    stderr.print("\x1b[38;2;224;32;32m\x1b[1merror:\x1b[0m {s}\n", .{err_message}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printErrorFmt(comptime err_message: []const u8, args: anytype) void {
    stderr.print("\x1b[38;2;224;32;32m\x1b[1merror:\x1b[0m ", .{}) catch |err| panicInternalError(err);
    stderr.print(err_message, args) catch |err| panicInternalError(err);
    stderr.print("\n", .{}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printSrcFileError(comptime err_message: []const u8, file_name: []const u8) void {
    stderr.print("\x1b[4m{s}\x1b[0m: ", .{file_name}) catch |err| panicInternalError(err);
    printError(err_message);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printSrcFileErrorFmt(comptime err_message: []const u8, args: anytype, file_name: []const u8) void {
    stderr.print("\x1b[4m{s}\x1b[0m: ", .{file_name}) catch |err| panicInternalError(err);
    printErrorFmt(err_message, args);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printSrcLineError(comptime err_message: []const u8, file_name: []const u8, file_content: []const u8, line: u16) void {
    const slice = getLine(file_content, line);
    stderr.print("\x1b[4m{s}:{d}\x1b[0m: ", .{ file_name, line }) catch |err| panicInternalError(err);
    printError(err_message);
    stderr.print("{s}\n\n", .{slice}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printSrcLineErrorFmt(comptime err_message: []const u8, args: anytype, file_name: []const u8, file_content: []const u8, line: u16) void {
    const slice = getLine(file_content, line);
    stderr.print("\x1b[4m{s}:{d}\x1b[0m: ", .{ file_name, line }) catch |err| panicInternalError(err);
    printErrorFmt(err_message, args);
    stderr.print("{s}\n\n", .{slice}) catch |err| panicInternalError(err);
    stderr.flush() catch |err| panicInternalError(err);
}

pub fn printWarning(comptime warning: []const u8) void {
    stdout.print("\x1b[38;2;44;174;224m\x1b[1mwarning:\x1b[0m {s}\n", .{warning}) catch |err| panicInternalError(err);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printWarningFmt(comptime warning: []const u8, args: anytype) void {
    stdout.print("\x1b[38;2;44;174;224m\x1b[1mwarning:\x1b[0m ", .{}) catch |err| panicInternalError(err);
    stdout.print(warning, args) catch |err| panicInternalError(err);
    stdout.print("\n", .{}) catch |err| panicInternalError(err);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printSrcLineWarning(comptime warn_message: []const u8, file_name: []const u8, file_content: []const u8, line: u16) void {
    const slice = getLine(file_content, line);
    stdout.print("\x1b[4m{s}:{d}\x1b[0m: ", .{ file_name, line }) catch |err| panicInternalError(err);
    printWarning(warn_message);
    stdout.print("{s}\n\n", .{slice}) catch |err| panicInternalError(err);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printSrcLineWarningFmt(comptime warn_message: []const u8, args: anytype, file_name: []const u8, file_content: []const u8, line: u16) void {
    const slice = getLine(file_content, line);
    stdout.print("\x1b[4m{s}:{d}\x1b[0m: ", .{ file_name, line }) catch |err| panicInternalError(err);
    printWarningFmt(warn_message, args);
    stdout.print("{s}\n\n", .{slice}) catch |err| panicInternalError(err);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printSrcFileWarning(comptime warn_message: []const u8, file_name: []const u8) void {
    stdout.print("\x1b[4m{s}\x1b[0m: ", .{file_name}) catch |err| panicInternalError(err);
    printWarning(warn_message);
    stdout.flush() catch |err| panicInternalError(err);
}

pub fn printSrcFileWarningFmt(comptime warn_message: []const u8, args: anytype, file_name: []const u8) void {
    stdout.print("\x1b[4m{s}\x1b[0m: ", .{file_name}) catch |err| panicInternalError(err);
    printWarning(warn_message, args);
    stdout.flush() catch |err| panicInternalError(err);
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
        error.CliParseFailed,
        error.FileNotFound,
        error.SourceFileTooBig,
        error.AssemblyError,
        error.LexerAnalyzisFailed,
        error.ParsingFailed,
        error.CodeGenFailed,
        error.ProgramFailed,
        error.LinkingFailed,
        => {
            std.process.exit(1);
        },
        else => {
            panicInternalError(err);
        },
    }
}
