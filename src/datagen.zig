const std = @import("std");
const parser = @import("parser");
const Program = @import("program").Program;
const stdbuffers = @import("stdbuffers");

fn tillNextAlignedAddress(current: u64, alignment: u8) u64 {
    const aligned = (current + alignment - 1) & ~(alignment - 1);
    return aligned - current;
}

pub const DatagenError = error{DataGenFailed} || std.mem.Allocator.Error;

pub fn addImmediate(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, imm: parser.Immediate, bytes: u8) std.mem.Allocator.Error!void {
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

pub fn bufferizeDataSection(program: *Program) DatagenError!void {
    var section = &program.data_section.?;
    for (section.instr.items) |instruction| {
        const name = instruction.label;
        const data_size = instruction.size;

        const padding = tillNextAlignedAddress(section.buffer.items.len, data_size);
        for (0..padding) |_| {
            try section.buffer.append(program.allocator, undefined);
        }

        const opt_symbol = program.symbols.getPtr(name);
        if (opt_symbol) |symbol| {
            symbol.offset = section.buffer.items.len;
        } else {
            // unreachable;
            stdbuffers.printSourceErrorFormatted(program.file_name, "label '{s}' is not defined", .{name}, program.content, instruction.line);
            return DatagenError.DataGenFailed;
        }

        for (instruction.data.items) |data| {
            switch (data) {
                .str => {
                    if (data_size == 1) {
                        try section.buffer.appendSlice(program.allocator, data.str);
                    } else {
                        stdbuffers.printSourceError(program.file_name, "string literal must have data size d8", program.content, instruction.line);
                        return DatagenError.DataGenFailed;
                    }
                },
                .num => {
                    try addImmediate(&section.buffer, program.allocator, data.num, data_size);
                },
                .repeat => {
                    const count = data.repeat.count.u;
                    switch (data.repeat.item) {
                        .str => {
                            if (data_size == 1) {
                                const chars = data.repeat.item.str;
                                for (0..count) |_| {
                                    try section.buffer.appendSlice(program.allocator, chars);
                                }
                            } else {
                                stdbuffers.printSourceError(program.file_name, "string literal must have data size d8", program.content, instruction.line);
                                return DatagenError.DataGenFailed;
                            }
                        },
                        .num => {
                            for (0..count) |_| {
                                try addImmediate(&section.buffer, program.allocator, data.repeat.item.num, data_size);
                            }
                        },
                    }
                },
            }
        }
    }
}
