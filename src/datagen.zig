const std = @import("std");
const parser = @import("parser");

pub var data_buffer: std.ArrayList(u8) = .empty;

fn convertNumberLiteral(comptime T: type, slice: []const u8) !T {
    return try std.fmt.parseInt(T, slice, 10);
}

fn tillNextAlignedAddress(current: u64, alignment: u8) u64 {
    const aligned = (current + alignment - 1) & ~(alignment - 1);
    return aligned - current;
}

pub fn bufferizeDataSection(section: *parser.DataSection, allocator: std.mem.Allocator) !void {
    for (section.instr.items) |instruction| {
        const name = instruction.label.name;
        const dtype = instruction.type;

        const alignment: u8 = switch (dtype) {
            .D8 => 1,
            .D16 => 2,
            .D32 => 4,
            .D64 => 8,
            else => 1,
        };

        const padding = tillNextAlignedAddress(data_buffer.items.len, alignment);
        for (0..padding) |_| {
            try data_buffer.append(allocator, undefined);
        }

        const result = try parser.dl_table.getOrPut(name);
        if (result.found_existing) {
            // error - label previously defined
        } else {
            result.value_ptr.defined = true;
            result.value_ptr.offset = data_buffer.items.len;
        }

        for (instruction.data.items) |data| {
            switch (data) {
                .str_lit => {
                    if (dtype == .D8) {
                        try data_buffer.appendSlice(allocator, data.str_lit);
                    } else {
                        // error - string literal must have type d8
                    }
                },
                .num_lit => {
                    switch (dtype) {
                        .D8 => {
                            // const padding = tillNextAlignedAddress(data_buffer.items.len, 1);
                            // for (0..padding) |_| {
                            //     try data_buffer.append(allocator, undefined);
                            // }
                            const num = try convertNumberLiteral(u8, data.num_lit);
                            try data_buffer.append(allocator, num);
                        },
                        .D16 => {
                            // const padding = tillNextAlignedAddress(data_buffer.items.len, 1);
                            // for (0..padding) |_| {
                            //     try data_buffer.append(allocator, undefined);
                            // }
                            const num = try convertNumberLiteral(u16, data.num_lit);
                            const lit_end: [2]u8 = .{ @truncate(num), @truncate(num >> 8) };
                            try data_buffer.appendSlice(allocator, lit_end[0..2]);
                        },
                        .D32 => {
                            // const padding = tillNextAlignedAddress(data_buffer.items.len, 1);
                            // for (0..padding) |_| {
                            //     try data_buffer.append(allocator, undefined);
                            // }
                            const num = try convertNumberLiteral(u32, data.num_lit);
                            const lit_end: [4]u8 = .{ @truncate(num), @truncate(num >> 8), @truncate(num >> 16), @truncate(num >> 24) };
                            try data_buffer.appendSlice(allocator, lit_end[0..4]);
                        },
                        .D64 => {
                            // const padding = tillNextAlignedAddress(data_buffer.items.len, 1);
                            // for (0..padding) |_| {
                            //     try data_buffer.append(allocator, undefined);
                            // }
                            const num = try convertNumberLiteral(u64, data.num_lit);
                            const lit_end: [8]u8 = .{ @truncate(num), @truncate(num >> 8), @truncate(num >> 16), @truncate(num >> 24), @truncate(num >> 32), @truncate(num >> 40), @truncate(num >> 48), @truncate(num >> 56) };
                            try data_buffer.appendSlice(allocator, lit_end[0..8]);
                        },
                        else => {
                            // error but should be unreachable
                        },
                    }
                },
                .repeat => {
                    const count = try convertNumberLiteral(usize, data.repeat.count);
                    switch (data.repeat.item) {
                        .str_lit => {
                            if (dtype == .D8) {
                                const chars = data.repeat.item.str_lit;
                                for (0..count) |_| {
                                    try data_buffer.appendSlice(allocator, chars);
                                }
                            } else {
                                // error - string literal must have type d8
                            }
                        },
                        .num_lit => {
                            switch (dtype) {
                                .D8 => {
                                    const num = try convertNumberLiteral(u8, data.repeat.item.num_lit);
                                    for (0..count) |_| {
                                        try data_buffer.append(allocator, num);
                                    }
                                },
                                .D16 => {
                                    // const padding = tillNextAlignedAddress(data_buffer.items.len, 1);
                                    // for (0..padding) |_| {
                                    //     try data_buffer.append(allocator, undefined);
                                    // }
                                    const num = try convertNumberLiteral(u16, data.repeat.item.num_lit);
                                    const lit_end: [2]u8 = .{ @truncate(num), @truncate(num >> 8) };
                                    for (0..count) |_| {
                                        try data_buffer.appendSlice(allocator, lit_end[0..2]);
                                    }
                                },
                                .D32 => {
                                    // const padding = tillNextAlignedAddress(data_buffer.items.len, 1);
                                    // for (0..padding) |_| {
                                    //     try data_buffer.append(allocator, undefined);
                                    // }
                                    const num = try convertNumberLiteral(u32, data.repeat.item.num_lit);
                                    const lit_end: [4]u8 = .{ @truncate(num), @truncate(num >> 8), @truncate(num >> 16), @truncate(num >> 24) };
                                    for (0..count) |_| {
                                        try data_buffer.appendSlice(allocator, lit_end[0..4]);
                                    }
                                },
                                .D64 => {
                                    // const padding = tillNextAlignedAddress(data_buffer.items.len, 1);
                                    // for (0..padding) |_| {
                                    //     try data_buffer.append(allocator, undefined);
                                    // }
                                    const num = try convertNumberLiteral(u64, data.repeat.item.num_lit);
                                    const lit_end: [8]u8 = .{ @truncate(num), @truncate(num >> 8), @truncate(num >> 16), @truncate(num >> 24), @truncate(num >> 32), @truncate(num >> 40), @truncate(num >> 48), @truncate(num >> 56) };
                                    for (0..count) |_| {
                                        try data_buffer.appendSlice(allocator, lit_end[0..8]);
                                    }
                                },
                                else => {
                                    // error but should be unreachable
                                },
                            }
                        },
                    }
                },
            }
        }
    }

    std.debug.print("Data buffer:\n", .{});
    for (data_buffer.items) |byte| {
        std.debug.print("{x:02}", .{byte});
    }
    std.debug.print("\n", .{});

    // std.debug.print("\n", .{});
    // var iter = parser.dl_table.iterator();
    // while (iter.next()) |entry| {
    //     std.debug.print("{s}, {d}\n", .{ entry.key_ptr.*, entry.value_ptr.offset });
    // }
    // std.debug.print("\n", .{});
}
