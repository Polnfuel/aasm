const std = @import("std");
const parser = @import("parser");

fn tillNextAlignedAddress(current: u64, alignment: u8) u64 {
    const aligned = (current + alignment - 1) & ~(alignment - 1);
    return aligned - current;
}

const DatagenError = error{
    LabelIsNotDefined,
    StringLiteralNotD8,
};

pub fn addImmediate(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, imm: parser.Immediate, bytes: u8) !void {
    const value: u64 = switch (imm) {
        .i => @bitCast(imm.i),
        .u => imm.u,
    };
    try buffer.append(allocator, @as(u8, @truncate(value)));
    if (bytes > 1) {
        try buffer.append(allocator, @as(u8, @truncate(value >> 8)));
    }
    if (bytes > 2) {
        try buffer.append(allocator, @as(u8, @truncate(value >> 16)));
        try buffer.append(allocator, @as(u8, @truncate(value >> 24)));
    }
    if (bytes > 4) {
        try buffer.append(allocator, @as(u8, @truncate(value >> 32)));
        try buffer.append(allocator, @as(u8, @truncate(value >> 40)));
        try buffer.append(allocator, @as(u8, @truncate(value >> 48)));
        try buffer.append(allocator, @as(u8, @truncate(value >> 56)));
    }
}

pub fn bufferizeDataSection(section: *parser.DataSection, allocator: std.mem.Allocator) !void {
    for (section.instr.items) |instruction| {
        const name = instruction.label;
        const data_size = instruction.size;

        const padding = tillNextAlignedAddress(section.buffer.items.len, data_size);
        for (0..padding) |_| {
            try section.buffer.append(allocator, undefined);
        }

        const opt_symbol = section.symbols.getPtr(name);
        if (opt_symbol) |symbol| {
            symbol.offset = section.buffer.items.len;
            // TODO: add global keyword for globally visible symbols
            symbol.binding = .Local;
        } else {
            return DatagenError.LabelIsNotDefined;
        }

        for (instruction.data.items) |data| {
            switch (data) {
                .str => {
                    if (data_size == 1) {
                        try section.buffer.appendSlice(allocator, data.str);
                    } else {
                        return DatagenError.StringLiteralNotD8;
                    }
                },
                .num => {
                    try addImmediate(&section.buffer, allocator, data.num, data_size);
                },
                .repeat => {
                    const count = data.repeat.count.u;
                    switch (data.repeat.item) {
                        .str => {
                            if (data_size == 1) {
                                const chars = data.repeat.item.str;
                                for (0..count) |_| {
                                    try section.buffer.appendSlice(allocator, chars);
                                }
                            } else {
                                return DatagenError.StringLiteralNotD8;
                            }
                        },
                        .num => {
                            for (0..count) |_| {
                                try addImmediate(&section.buffer, allocator, data.repeat.item.num, data_size);
                            }
                        },
                    }
                },
            }
        }
    }
}
