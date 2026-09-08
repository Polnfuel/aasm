const std = @import("std");
const CliArgs = @import("CliArgs");
const Program = @import("Program");
const Label = Program.Label;

pub const LoadFileError = error{SourceFileTooBig} || std.process.CurrentPathAllocError ||
    std.Io.File.OpenError || std.Io.File.StatError || std.mem.Allocator.Error || std.Io.Reader.Error;

pub const AasmFlags = struct {
    strip: bool = false,
    debug: bool = false,
    pic: bool = false,
    warnings: bool = true,
    quiet: bool = false,
};

pub var alloc: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;
pub var comp_dir: []const u8 = undefined;
pub var flags: AasmFlags = .{};
var unique_strings: std.ArrayList([]const u8) = .empty;
var strings_map: LabelsHashMap = undefined;

var stdout_buffer: []u8 = undefined;
var stderr_buffer: []u8 = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var stderr_writer: std.Io.File.Writer = undefined;
var stdout: *std.Io.Writer = undefined;
var stderr: *std.Io.Writer = undefined;

pub fn init(allocator: std.mem.Allocator, in_out: std.Io) (std.mem.Allocator.Error || std.process.CurrentPathAllocError)!void {
    alloc = allocator;
    io = in_out;
    stdout_buffer = try alloc.alloc(u8, 1024);
    stderr_buffer = try alloc.alloc(u8, 1024);
    stdout_writer = std.Io.File.stdout().writer(io, stdout_buffer);
    stderr_writer = std.Io.File.stderr().writer(io, stderr_buffer);
    stdout = &stdout_writer.interface;
    stderr = &stderr_writer.interface;
    const cwd_sentinel = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd_sentinel);
    comp_dir = try alloc.dupe(u8, @ptrCast(cwd_sentinel));

    unique_strings = .empty;
    try unique_strings.append(alloc, &.{});
    strings_map = try .init(0, 8);
}

pub fn deinit() void {
    alloc.free(stdout_buffer);
    alloc.free(stderr_buffer);
    alloc.free(comp_dir);
    unique_strings.deinit(alloc);
}

pub fn setFlags(cli_args: CliArgs) void {
    flags.strip = cli_args.strip;
    flags.debug = cli_args.debug;
    flags.pic = cli_args.pic;
    flags.warnings = !cli_args.no_warnings;
    flags.quiet = cli_args.quiet;
}

pub fn loadFileContent(abs_path: []const u8) LoadFileError![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            std.Io.File.OpenError.FileNotFound => {
                printErrorFmt("file '{s}' not found", .{abs_path});
            },
            else => {},
        }
        return err;
    };
    defer file.close(io);

    const file_stat = try file.stat(io);
    const file_size = file_stat.size;

    if (file_size > std.math.pow(u64, 2, 20)) {
        printErrorFmt("file '{s}' with size {d} B exceeds 1 MiB file size limit", .{ abs_path, file_size });
        return LoadFileError.SourceFileTooBig;
    }

    var content = try alloc.alloc(u8, file_size + 1);
    errdefer alloc.free(content);

    var file_reader = file.reader(io, content);
    var reader = &file_reader.interface;
    try reader.readSliceAll(content[0..file_size]);
    content[file_size] = '\n';

    return content;
}

pub fn putString(string: []const u8) std.mem.Allocator.Error!u16 {
    const result = try strings_map.getOrPut(string);
    if (!result.found_existing) {
        result.value_ptr.* = @truncate(unique_strings.items.len);
        try unique_strings.append(alloc, string);
    }
    return result.value_ptr.*;
}

pub fn stringValue(val_ind: u16) []const u8 {
    return unique_strings.items[val_ind];
}

pub fn deinitStrings() void {
    strings_map.deinit();
}

const LabelsHashMap = struct {
    size: u32,
    capacity: u32,
    entries: [*]align(@alignOf(Entry)) Entry,
    metadata: [*]Meta,

    const Self = @This();

    const Meta = packed struct(u8) {
        fingerprint: u7,
        empty: bool,
    };

    const Entry = struct {
        key: []const u8,
        value: Label,
    };

    const GetOrPutResult = struct {
        found_existing: bool,
        value_ptr: *Label,
    };

    const RapidHash = struct {
        const secret = [_]u64{
            0x2d358dccaa6c78a5,
            0x8bb84b93962eacc9,
            0x4b33a62ed433d4a3,
            0x4d5a2da51de1aa47,
            0xa0761d6478bd642f,
            0xe7037ed1a0b428db,
            0x90ed1765281c388c,
            0xaaaaaaaaaaaaaaaa,
        };

        fn rapid_mum(a: *u64, b: *u64) void {
            var r: u128 = a.*;
            r *= b.*;
            a.* = @truncate(r);
            b.* = @truncate(r >> 64);
        }

        fn rapid_mix(a: u64, b: u64) u64 {
            var a1 = a;
            var b1 = b;
            rapid_mum(&a1, &b1);
            return a1 ^ b1;
        }

        fn rapid_read64(p: [*]const u8) u64 {
            return std.mem.readVarInt(u64, p[0..8], .little);
        }

        fn rapid_read32(p: [*]const u8) u32 {
            return std.mem.readVarInt(u32, p[0..4], .little);
        }

        fn rapidhashNano(key: []const u8) u64 {
            var p = key.ptr;
            var seed: u64 = 0;
            seed ^= rapid_mix(seed ^ secret[2], secret[1]);
            var a: u64 = 0;
            var b: u64 = 0;
            const len = key.len;
            var i = len;
            if (len <= 16) {
                @branchHint(.likely);
                if (len >= 4) {
                    seed ^= len;
                    if (len >= 8) {
                        a = rapid_read64(p);
                        b = rapid_read64(p + len - 8);
                    } else {
                        a = rapid_read32(p);
                        b = rapid_read32(p + len - 4);
                    }
                } else if (len > 0) {
                    a = @as(u64, p[0]) << 45 | p[len - 1];
                    b = p[len >> 1];
                } else {
                    a = 0;
                    b = 0;
                }
            } else {
                if (i > 48) {
                    var see1 = seed;
                    var see2 = seed;
                    while (true) {
                        seed = rapid_mix(rapid_read64(p) ^ secret[0], rapid_read64(p + 8) ^ seed);
                        see1 = rapid_mix(rapid_read64(p + 16) ^ secret[1], rapid_read64(p + 24) ^ see1);
                        see2 = rapid_mix(rapid_read64(p + 32) ^ secret[2], rapid_read64(p + 40) ^ see2);
                        p += 48;
                        i -= 48;
                        if (i <= 48) break;
                    }
                    seed ^= see1;
                    seed ^= see2;
                }
                if (i > 16) {
                    seed = rapid_mix(rapid_read64(p) ^ secret[2], rapid_read64(p + 8) ^ seed);
                    if (i > 32) {
                        seed = rapid_mix(rapid_read64(p + 16) ^ secret[2], rapid_read64(p + 24) ^ seed);
                    }
                }
                a = rapid_read64(p + i - 16) ^ i;
                b = rapid_read64(p + i - 8);
            }
            a ^= secret[1];
            b ^= seed;
            rapid_mum(&a, &b);
            return rapid_mix(a ^ secret[7], b ^ secret[1] ^ i);
        }

        fn rapidhashMicro(key: []const u8) u64 {
            var p = key.ptr;
            var seed: u64 = 0;
            seed ^= rapid_mix(seed ^ secret[2], secret[1]);
            var a: u64 = 0;
            var b: u64 = 0;
            const len = key.len;
            var i = len;
            if (len <= 16) {
                @branchHint(.likely);
                if (len >= 4) {
                    seed ^= len;
                    if (len >= 8) {
                        a = rapid_read64(p);
                        b = rapid_read64(p + len - 8);
                    } else {
                        a = rapid_read32(p);
                        b = rapid_read32(p + len - 4);
                    }
                } else if (len > 0) {
                    a = @as(u64, p[0]) << 45 | p[len - 1];
                    b = p[len >> 1];
                } else {
                    a = 0;
                    b = 0;
                }
            } else {
                if (i > 80) {
                    var see1 = seed;
                    var see2 = seed;
                    var see3 = seed;
                    var see4 = seed;
                    while (true) {
                        seed = rapid_mix(rapid_read64(p) ^ secret[0], rapid_read64(p + 8) ^ seed);
                        see1 = rapid_mix(rapid_read64(p + 16) ^ secret[1], rapid_read64(p + 24) ^ see1);
                        see2 = rapid_mix(rapid_read64(p + 32) ^ secret[2], rapid_read64(p + 40) ^ see2);
                        see3 = rapid_mix(rapid_read64(p + 48) ^ secret[3], rapid_read64(p + 56) ^ see3);
                        see4 = rapid_mix(rapid_read64(p + 64) ^ secret[4], rapid_read64(p + 72) ^ see4);
                        p += 80;
                        i -= 80;
                        if (i <= 80) break;
                    }
                    seed ^= see1;
                    see2 ^= see3;
                    seed ^= see4;
                    seed ^= see2;
                }
                if (i > 16) {
                    seed = rapid_mix(rapid_read64(p) ^ secret[2], rapid_read64(p + 8) ^ seed);
                    if (i > 32) {
                        seed = rapid_mix(rapid_read64(p + 16) ^ secret[2], rapid_read64(p + 24) ^ seed);
                        if (i > 48) {
                            seed = rapid_mix(rapid_read64(p + 32) ^ secret[1], rapid_read64(p + 40) ^ seed);
                            if (i > 64) {
                                seed = rapid_mix(rapid_read64(p + 48) ^ secret[1], rapid_read64(p + 56) ^ seed);
                            }
                        }
                    }
                }
                a = rapid_read64(p + i - 16) ^ i;
                b = rapid_read64(p + i - 8);
            }
            a ^= secret[1];
            b ^= seed;
            rapid_mum(&a, &b);
            return rapid_mix(a ^ secret[7], b ^ secret[1] ^ i);
        }
    };

    fn init(size: u32, init_capacity: u32) std.mem.Allocator.Error!Self {
        const bytes = @sizeOf(Entry) * init_capacity + @sizeOf(Meta) * init_capacity;
        const memory = try alloc.alignedAlloc(u8, .of(Entry), bytes);
        const meta_ptr: [*]Meta = @ptrCast(memory.ptr + @sizeOf(Entry) * init_capacity);
        @memset(meta_ptr[0..init_capacity], Meta{ .empty = true, .fingerprint = 0 });
        const entry_ptr: [*]align(@alignOf(Entry)) Entry = @ptrCast(memory.ptr);

        return Self{
            .size = size,
            .capacity = init_capacity,
            .metadata = meta_ptr,
            .entries = entry_ptr,
        };
    }

    fn deinit(self: *Self) void {
        const bytes = @sizeOf(Entry) * self.capacity + @sizeOf(Meta) * self.capacity;
        const mem_ptr: [*]align(@alignOf(Entry)) u8 = @ptrCast(self.entries);
        const memory = mem_ptr[0..bytes];
        alloc.free(memory);
    }

    fn hashKey(key: []const u8) u64 {
        return RapidHash.rapidhashMicro(key);
    }

    fn getOrPut(self: *Self, key: []const u8) std.mem.Allocator.Error!GetOrPutResult {
        const hash = hashKey(key);
        const h2: u7 = @truncate(hash & 0x7F);
        const h1 = hash >> 7;
        var index = h1 & (self.capacity - 1);
        while (true) {
            const meta = self.metadata[index];
            if (!meta.empty and meta.fingerprint == h2) {
                // Found same fingerprint
                const entry = self.entries[index];
                if (std.mem.eql(u8, entry.key, key)) {
                    // Same key -> return as found value
                    return GetOrPutResult{ .found_existing = true, .value_ptr = &self.entries[index].value };
                }
            } else if (meta.empty) {
                const to_grow: bool = (self.size + 1) * 100 / (self.capacity) > 80;
                if (to_grow) {
                    try self.grow();
                    // Put key into rehashed
                    const value_ptr = self.putKey(key);
                    return GetOrPutResult{ .found_existing = false, .value_ptr = value_ptr };
                } else {
                    // Put key into non-rehashed
                    self.metadata[index] = .{ .empty = false, .fingerprint = h2 };
                    self.entries[index] = .{ .key = key, .value = undefined };
                    self.size += 1;
                    return GetOrPutResult{ .found_existing = false, .value_ptr = &self.entries[index].value };
                }
            }
            index = (index + 1) & (self.capacity - 1);
        }
    }

    fn putKey(self: *Self, key: []const u8) *Label {
        const hash = hashKey(key);
        const h2: u7 = @truncate(hash & 0x7F);
        const h1 = hash >> 7;
        var index = h1 & (self.capacity - 1);
        while (!self.metadata[index].empty) {
            index = (index + 1) & (self.capacity - 1);
        }
        self.metadata[index] = .{ .empty = false, .fingerprint = h2 };
        self.entries[index] = .{ .key = key, .value = undefined };
        self.size += 1;
        return &self.entries[index].value;
    }

    fn grow(self: *Self) std.mem.Allocator.Error!void {
        const new_capacity = self.capacity * 2;
        const new_map: Self = try .init(self.size, new_capacity);
        const new_metadata = new_map.metadata;
        const new_entries = new_map.entries;

        for (self.metadata, 0..self.capacity) |meta, i| {
            if (!meta.empty) {
                const entry = self.entries[i];
                const hash = hashKey(entry.key);
                const h2: u7 = @truncate(hash & 0x7F);
                const h1 = hash >> 7;
                var new_index = h1 & (new_capacity - 1);
                while (!new_metadata[new_index].empty) {
                    new_index = (new_index + 1) & (new_capacity - 1);
                }
                new_metadata[new_index] = .{ .empty = false, .fingerprint = h2 };
                new_entries[new_index] = entry;
            }
        }

        self.deinit();
        self.* = new_map;
    }
};

const WHITEBOLD = "\x1b[1m\x1b[38;5;253m";
const REDBOLD = "\x1b[1m\x1b[38;2;224;32;32m";
const BLUEBOLD = "\x1b[1m\x1b[38;2;44;174;224m";

fn printColumnPointerErr(col: u16) void {
    _ = stderr.splatByte(' ', col - 1) catch {};
    _ = stderr.write("\x1b[32m^~~\x1b[0m\n") catch {};
}

pub fn printMessage(comptime message: []const u8) void {
    stdout.print("{s}\n", .{message}) catch {};
    stdout.flush() catch {};
}

pub fn printMessageFmt(comptime message: []const u8, args: anytype) void {
    stdout.print(message, args) catch {};
    _ = stdout.write("\n") catch {};
    stdout.flush() catch {};
}

pub fn printError(comptime err_message: []const u8) void {
    stderr.print("{s}error: {s}{s}\x1b[0m\n", .{ REDBOLD, WHITEBOLD, err_message }) catch {};
    stderr.flush() catch {};
}

pub fn printErrorFmt(comptime err_message: []const u8, args: anytype) void {
    stderr.print("{s}error: {s}", .{ REDBOLD, WHITEBOLD }) catch {};
    stderr.print(err_message, args) catch {};
    _ = stderr.write("\x1b[0m\n") catch {};
    stderr.flush() catch {};
}

pub fn printSrcFileError(comptime err_message: []const u8, program: *const Program) void {
    stderr.print("{s}{s}: ", .{ WHITEBOLD, program.file_name }) catch {};
    printError(err_message);
    stderr.flush() catch {};
}

pub fn printSrcFileErrorFmt(comptime err_message: []const u8, args: anytype, program: *const Program) void {
    stderr.print("{s}{s}: ", .{ WHITEBOLD, program.file_name }) catch {};
    printErrorFmt(err_message, args);
    stderr.flush() catch {};
}

pub fn printSrcLineError(comptime err_message: []const u8, program: *const Program, line: u16) void {
    const slice = getLine(program.content, line);
    stderr.print("{s}{s}:{d}: ", .{ WHITEBOLD, program.file_name, line }) catch {};
    printError(err_message);
    stderr.print("{s}\n", .{slice}) catch {};
    stderr.flush() catch {};
}

pub fn printSrcLineErrorFmt(comptime err_message: []const u8, args: anytype, program: *const Program, line: u16) void {
    const slice = getLine(program.content, line);
    stderr.print("{s}{s}:{d}: ", .{ WHITEBOLD, program.file_name, line }) catch {};
    printErrorFmt(err_message, args);
    stderr.print("{s}\n", .{slice}) catch {};
    stderr.flush() catch {};
}

pub fn printSrcLineColError(comptime err_message: []const u8, program: *const Program, line: u16, col: u16) void {
    const slice = getLine(program.content, line);
    stderr.print("{s}{s}:{d}:{d}: ", .{ WHITEBOLD, program.file_name, line, col }) catch {};
    printError(err_message);
    stderr.print("{s}\n", .{slice}) catch {};
    printColumnPointerErr(col);
    stderr.flush() catch {};
}

pub fn printSrcLineColErrorFmt(comptime err_message: []const u8, args: anytype, program: *const Program, line: u16, col: u16) void {
    const slice = getLine(program.content, line);
    stderr.print("{s}{s}:{d}:{d}: ", .{ WHITEBOLD, program.file_name, line, col }) catch {};
    printErrorFmt(err_message, args);
    stderr.print("{s}\n", .{slice}) catch {};
    printColumnPointerErr(col);
    stderr.flush() catch {};
}

pub fn printWarning(comptime warning: []const u8) void {
    stdout.print("{s}warning: {s}{s}\x1b[0m\n", .{ BLUEBOLD, WHITEBOLD, warning }) catch {};
    stdout.flush() catch {};
}

pub fn printWarningFmt(comptime warning: []const u8, args: anytype) void {
    stdout.print("{s}warning: {s}", .{ BLUEBOLD, WHITEBOLD }) catch {};
    stdout.print(warning, args) catch {};
    stdout.print("\x1b[0m\n", .{}) catch {};
    stdout.flush() catch {};
}

pub fn printSrcLineWarning(comptime warn_message: []const u8, program: *const Program, line: u16) void {
    const slice = getLine(program.content, line);
    stdout.print("{s}{s}:{d}: ", .{ WHITEBOLD, program.file_name, line }) catch {};
    printWarning(warn_message);
    stdout.print("{s}\n", .{slice}) catch {};
    stdout.flush() catch {};
}

pub fn printSrcLineWarningFmt(comptime warn_message: []const u8, args: anytype, program: *const Program, line: u16) void {
    const slice = getLine(program.content, line);
    stdout.print("{s}{s}:{d}: ", .{ WHITEBOLD, program.file_name, line }) catch {};
    printWarningFmt(warn_message, args);
    stdout.print("{s}\n", .{slice}) catch {};
    stdout.flush() catch {};
}

pub fn printSrcFileWarning(comptime warn_message: []const u8, program: *const Program) void {
    stdout.print("{s}{s}: ", .{ WHITEBOLD, program.file_name }) catch {};
    printWarning(warn_message);
    stdout.flush() catch {};
}

pub fn printSrcFileWarningFmt(comptime warn_message: []const u8, args: anytype, program: *const Program) void {
    stdout.print("{s}{s}: ", .{ WHITEBOLD, program.file_name }) catch {};
    printWarningFmt(warn_message, args);
    stdout.flush() catch {};
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

pub fn internalCrash(err: anyerror) void {
    std.debug.print("\x1b[38;2;224;32;32m\x1b[1merror:\x1b[0m internal assembler crash ({t})\n", .{err});
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
        error.LinkingFailed,
        => {},
        else => {
            internalCrash(err);
        },
    }
}
