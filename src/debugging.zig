const std = @import("std");

const dwarf = std.dwarf;

pub const DebugEntry = struct {
    offset: usize,
    line: usize,
};

pub const DebugInfo = struct {
    entries: std.ArrayList(DebugEntry),
    debug_line_ind: usize,
    debug_line_str_ind: usize,
    debug_info_ind: usize,
    debug_abbrev_ind: usize,
    debug_str_ind: usize,
    text_symbol_ind: usize,
    debug_line_buffer: std.ArrayList(u8),
    debug_line_str_buffer: std.ArrayList(u8),
    debug_line_rela_buffer: std.ArrayList(std.elf.Elf64_Rela),
    debug_str_buffer: std.ArrayList(u8),
    debug_abbrev_buffer: std.ArrayList(u8),
    debug_info_buffer: std.ArrayList(u8),
    debug_info_rela_buffer: std.ArrayList(std.elf.Elf64_Rela),
    dbline_section: std.elf.Elf64_Shdr,
    dblinestr_section: std.elf.Elf64_Shdr,
    dblinerela_section: std.elf.Elf64_Shdr,
    dbabbrev_section: std.elf.Elf64_Shdr,
    dbinfo_section: std.elf.Elf64_Shdr,
    dbstr_section: std.elf.Elf64_Shdr,
    dbinforela_section: std.elf.Elf64_Shdr,
    cwd_path: []const u8,
    dir_path: ?[]const u8,

    pub fn init() DebugInfo {
        return DebugInfo{
            .entries = .empty,
            .debug_line_ind = undefined,
            .debug_line_str_ind = undefined,
            .debug_info_ind = undefined,
            .debug_abbrev_ind = undefined,
            .debug_str_ind = undefined,
            .text_symbol_ind = undefined,
            .debug_line_buffer = .empty,
            .debug_line_str_buffer = .empty,
            .debug_line_rela_buffer = .empty,
            .debug_str_buffer = .empty,
            .debug_abbrev_buffer = .empty,
            .debug_info_buffer = .empty,
            .debug_info_rela_buffer = .empty,
            .dbline_section = undefined,
            .dblinestr_section = undefined,
            .dblinerela_section = undefined,
            .dbabbrev_section = undefined,
            .dbinfo_section = undefined,
            .dbstr_section = undefined,
            .dbinforela_section = undefined,
            .cwd_path = undefined,
            .dir_path = null,
        };
    }

    pub fn createLineNumberProgram(self: *DebugInfo, alloc: std.mem.Allocator) std.mem.Allocator.Error!usize {
        // Set Address to first byte of .text section
        try self.debug_line_buffer.appendSlice(alloc, &.{
            dwarf.LNS.extended_op, 0x09, dwarf.LNE.set_address,
            0,                     0,    0,
            0,                     0,    0,
            0,                     0,
        });
        const text_reloc = self.debug_line_buffer.items.len - 8;

        const max_line_inc = 8;
        var line: usize = 1;
        var address: usize = 0;
        for (self.entries.items[0 .. self.entries.items.len - 1]) |entry| {
            const line_increment: u8 = @truncate(entry.line - line);
            const address_increment: u8 = @truncate(entry.offset - address);
            if (line_increment <= max_line_inc) {
                const opcode: u8 = (line_increment + 5) + (0x0e * address_increment) + 0x0d;
                try self.debug_line_buffer.append(alloc, opcode);
            } else {
                try self.debug_line_buffer.appendSlice(alloc, &.{
                    dwarf.LNS.advance_pc, address_increment,
                });
                try self.debug_line_buffer.appendSlice(alloc, &.{
                    dwarf.LNS.advance_line, line_increment,
                });
                try self.debug_line_buffer.append(alloc, dwarf.LNS.copy);
            }

            line += line_increment;
            address += address_increment;
        }

        const last_addr_inc: u8 = @truncate(self.entries.items[self.entries.items.len - 1].offset - address);
        try self.debug_line_buffer.appendSlice(alloc, &.{
            dwarf.LNS.advance_pc,  last_addr_inc,
            dwarf.LNS.extended_op, dwarf.LNE.end_sequence,
            dwarf.LNS.copy,
        });

        return text_reloc;
    }

    pub fn print(self: *DebugInfo) void {
        std.debug.print("Debug: \n", .{});
        std.debug.print("dir0: {s}\n", .{self.cwd_path});
        std.debug.print("dir1: {?s}\n", .{self.dir_path});
        std.debug.print("text symbol: {d}\n", .{self.text_symbol_ind});
        std.debug.print("debug line symbol: {d}\n", .{self.debug_line_ind});
        std.debug.print("debug line str symbol: {d}\n", .{self.debug_line_str_ind});
        std.debug.print("debug line str buffer: \n", .{});
        for (self.debug_line_str_buffer.items) |byte| {
            std.debug.print("{c}", .{if (byte == 0) ' ' else byte});
        }
        std.debug.print("\n", .{});
        std.debug.print("debug info symbol: {d}\n", .{self.debug_info_ind});
        std.debug.print("debug abbrev symbol: {d}\n", .{self.debug_abbrev_ind});
        std.debug.print("debug str symbol: {d}\n", .{self.debug_str_ind});
        std.debug.print("debug str buffer: \n", .{});
        for (self.debug_str_buffer.items) |byte| {
            std.debug.print("{c}", .{if (byte == 0) ' ' else byte});
        }
        std.debug.print("\n", .{});
    }

    pub fn deinit(self: *DebugInfo, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.debug_line_buffer.deinit(alloc);
        self.debug_line_str_buffer.deinit(alloc);
        self.debug_line_rela_buffer.deinit(alloc);
        self.debug_abbrev_buffer.deinit(alloc);
        self.debug_info_buffer.deinit(alloc);
        self.debug_str_buffer.deinit(alloc);
        self.debug_info_rela_buffer.deinit(alloc);
        alloc.free(self.cwd_path);
    }
};
