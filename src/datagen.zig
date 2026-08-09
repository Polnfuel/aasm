const std = @import("std");
const utils = @import("utils");
const Program = @import("Program");

pub const DatagenError = std.mem.Allocator.Error;

fn appendImmediateBytes(buffer: *std.ArrayList(u8), imm: Program.Immediate, bytes: u8) std.mem.Allocator.Error!void {
    const value: u64 = switch (imm) {
        .i => @bitCast(imm.i),
        .u => imm.u,
    };
    const array = std.mem.toBytes(value);
    try buffer.appendSlice(utils.alloc, array[0..bytes]);
}

pub fn genDataBlockBuffer(program: *Program) DatagenError!void {
    for (program.data_block.instr.items) |instruction| {
        const name = instruction.label;
        const data_size = instruction.size;

        const next_aligned = std.mem.alignForward(usize, program.data_block.buffer.items.len, data_size);
        const padding = next_aligned - program.data_block.buffer.items.len;

        _ = try program.data_block.buffer.addManyAsSlice(utils.alloc, padding);

        const offset = program.data_block.buffer.items.len;

        for (instruction.data.items) |data| {
            switch (data) {
                .str => {
                    if (data_size == 1) {
                        try program.data_block.buffer.appendSlice(utils.alloc, data.str);
                    } else unreachable;
                },
                .num => {
                    try appendImmediateBytes(&program.data_block.buffer, data.num, data_size);
                },
                .repeat => {
                    const count = data.repeat.count;
                    switch (data.repeat.item) {
                        .str => {
                            if (data_size == 1) {
                                const chars = data.repeat.item.str;
                                for (0..count) |_| {
                                    try program.data_block.buffer.appendSlice(utils.alloc, chars);
                                }
                            } else unreachable;
                        },
                        .num => {
                            for (0..count) |_| {
                                try appendImmediateBytes(&program.data_block.buffer, data.repeat.item.num, data_size);
                            }
                        },
                    }
                },
            }
        }

        const opt_symbol = program.data_vars.getPtr(name);
        if (opt_symbol) |symbol| {
            symbol.offset = offset;
            symbol.size = program.data_block.buffer.items.len - offset;
        } else unreachable;
    }
}
