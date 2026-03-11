const std = @import("std");
const lexer = @import("lexer");
const parser = @import("parser");

const REX_W = 0x48;
const REX_WB = 0x49;
const REX_B = 0x41;

pub var code_buffer: std.ArrayList(u8) = undefined;

pub var rellocations: std.StringHashMap(std.ArrayList(u64)) = undefined;

pub var data_virt_address: u64 = undefined;

fn immMinSize(imm: i64) u8 {
    if (imm > std.math.maxInt(i32)) {
        return 8;
    } else if (imm > std.math.maxInt(i16)) {
        return 4;
    } else if (imm > std.math.maxInt(i8)) {
        return 2;
    } else {
        return 1;
    }
}

fn regCode(reg: lexer.TokenType) u3 {
    switch (reg) {
        .Rax, .Eax, .Ax, .Al, .R8, .R8d, .R8w, .R8b => {
            return 0b000;
        },
        .Rcx, .Ecx, .Cx, .Cl, .R9, .R9d, .R9w, .R9b => {
            return 0b001;
        },
        .Rdx, .Edx, .Dx, .Dl, .R10, .R10d, .R10w, .R10b => {
            return 0b010;
        },
        .Rbx, .Ebx, .Bx, .Bl, .R11, .R11d, .R11w, .R11b => {
            return 0b011;
        },
        .Rsp, .Esp, .Sp, .Ah, .R12, .R12d, .R12w, .R12b => {
            return 0b100;
        },
        .Rbp, .Ebp, .Bp, .Ch, .R13, .R13d, .R13w, .R13b => {
            return 0b101;
        },
        .Rsi, .Esi, .Si, .Dh, .R14, .R14d, .R14w, .R14b => {
            return 0b110;
        },
        .Rdi, .Edi, .Di, .Bh, .R15, .R15d, .R15w, .R15b => {
            return 0b111;
        },
        else => {
            return 0;
        },
    }
}

fn sibByte(op1: parser.ComplexAddress, op2: parser.Register) u8 {
    const base: u3 = regCode(op2.name);
    var ss: u2 = undefined;
    if (op1.scale) |scale| {
        switch (scale) {
            0 => {
                ss = 0b00;
            },
            2 => {
                ss = 0b01;
            },
            4 => {
                ss = 0b10;
            },
            8 => {
                ss = 0b11;
            },
            else => {
                ss = 0;
            },
        }
    } else {
        ss = 0;
    }

    var ind: u3 = undefined;
    if (op1.index) |index| {
        ind = regCode(index.name);
    }
    const byte: u8 = (@as(u8, ss) << 6) | (@as(u8, ind) << 3) | (base);
    return byte;
}

fn modRMReg(op1: parser.Operand, op2: parser.Operand) u8 {
    var mod: u2 = undefined;
    var rm: u3 = undefined;
    var reg: u3 = undefined;
    switch (op1) {
        .reg => {
            switch (op2) {
                .reg => {
                    mod = 0b11;
                    rm = regCode(op1.reg.name);
                    reg = regCode(op2.reg.name);
                },
                .mem => {
                    reg = regCode(op1.reg.name);
                    switch (op2.mem.mem) {
                        .label => {
                            mod = 0b00;
                            rm = 0b100;
                        },
                        .addr => {
                            if (op2.mem.mem.addr.index == null) {
                                mod = 0b00;
                                rm = regCode(op2.mem.mem.addr.base.name);
                            } else {
                                mod = 0b00;
                                rm = 0b100;
                            }
                        },
                    }
                },
                else => {},
            }
        },
        .mem => {
            // switch (op2) {
            //     .reg => {

            //     },
            //     else => {},
            // }
        },
        else => {},
    }
    const modrmreg: u8 = (@as(u8, mod) << 6) | (@as(u8, reg) << 3) | (rm);
    return modrmreg;
}

fn syscall(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 0) {
        // error - syscall must have exactly 0 operands
    }
    const buffer: [2]u8 = .{ 0x0F, 0x05 };
    try code_buffer.appendSlice(allocator, &buffer);
}

fn xor(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        // error - xor must have exactly 2 operands
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            switch (second) {
                .reg => {
                    if (first.reg.size == second.reg.size) {
                        const code = modRMReg(first, second);
                        const buffer: [2]u8 = .{ 0x31, code };
                        if (rexw) {
                            try code_buffer.append(allocator, REX_W);
                        }
                        try code_buffer.appendSlice(allocator, &buffer);
                    } else {
                        // error - operand sizes not match
                    }
                },
                .mem => {},
                .imm => {
                    const immsize = immMinSize(second.imm);
                    switch (first.reg.name) {
                        .Al => {
                            if (immsize == 1) {
                                const buffer: [2]u8 = .{ 0x34, @truncate(@as(u64, @bitCast(second.imm))) };
                                try code_buffer.appendSlice(allocator, &buffer);
                            } else {
                                // error - imm value too big
                            }
                        },
                        .Ax => {
                            if (immsize <= 2) {
                                const buffer: [3]u8 = .{ 0x35, @truncate(@as(u64, @bitCast(second.imm))), @truncate(@as(u64, @bitCast(second.imm >> 8))) };
                                try code_buffer.appendSlice(allocator, &buffer);
                            } else {
                                //
                            }
                        },
                        .Eax => {
                            if (immsize <= 4) {
                                const buffer: [5]u8 = .{ 0x35, @truncate(@as(u64, @bitCast(second.imm))), @truncate(@as(u64, @bitCast(second.imm >> 8))), @truncate(@as(u64, @bitCast(second.imm >> 16))), @truncate(@as(u64, @bitCast(second.imm >> 24))) };
                                try code_buffer.appendSlice(allocator, &buffer);
                            }
                        },
                        .Rax => {
                            if (immsize <= 4) {
                                const buffer: [6]u8 = .{ REX_W, 0x35, @truncate(@as(u64, @bitCast(second.imm))), @truncate(@as(u64, @bitCast(second.imm >> 8))), @truncate(@as(u64, @bitCast(second.imm >> 16))), @truncate(@as(u64, @bitCast(second.imm >> 24))) };
                                try code_buffer.appendSlice(allocator, &buffer);
                            }
                        },
                        else => {},
                    }
                },
                .label => {},
            }
        },
        .mem => {},
        .imm => {
            // error - immediate cannot be first operand of xor
        },
        .label => {
            // error - label cannot be first operand of xor
        },
    }
}

fn inc(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        // error - inc must have exactly 1 operand
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            const rexb = if (first.reg.name.isAdditionalReg()) true else false;
            const code = modRMReg(first, .{ .reg = try parser.Register.init(.Rax) });
            var buffer: [2]u8 = .{ 0xFF, code };
            if (first.reg.size == 1) {
                buffer[0] = 0xFE;
            }
            if (rexb) {
                try code_buffer.append(allocator, REX_WB);
            } else if (rexw) {
                try code_buffer.append(allocator, REX_W);
            }
            try code_buffer.appendSlice(allocator, &buffer);
        },
        .mem => {},
        .imm => {
            // error - immediate cannot be operand of inc
        },
        .label => {
            // error - label cannot be operand of inc
        },
    }
}

fn dec(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        // error - dec must have exactly 1 operand
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            switch (first.reg.size) {
                1 => {
                    const code = modRMReg(first, .{ .reg = try parser.Register.init(.Rcx) });
                    const buffer: [2]u8 = .{ 0xFE, code };
                    if (rexw) {
                        try code_buffer.append(allocator, REX_W);
                    }
                    try code_buffer.appendSlice(allocator, &buffer);
                },
                2, 4, 8 => {
                    const code = modRMReg(first, .{ .reg = try parser.Register.init(.Rcx) });
                    const buffer: [2]u8 = .{ 0xFF, code };
                    if (rexw) {
                        try code_buffer.append(allocator, REX_W);
                    }
                    try code_buffer.appendSlice(allocator, &buffer);
                },
                else => {
                    // error but unreachable
                },
            }
        },
        .mem => {},
        .imm => {
            // error - immediate cannot be operand of dec
        },
        .label => {
            // error - label cannot be operand of dec
        },
    }
}

fn testi(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        // error - test must have exactly 2 operands
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            const rexb = if (first.reg.name.isAdditionalReg()) true else false;
            switch (second) {
                .reg => {
                    if (first.reg.size == second.reg.size) {
                        const code = modRMReg(first, second);
                        var buffer: [2]u8 = .{ 0x85, code };
                        if (first.reg.size == 1) {
                            buffer[0] = 0x84;
                        }
                        if (rexb) {
                            try code_buffer.append(allocator, REX_WB);
                        } else if (rexw) {
                            try code_buffer.append(allocator, REX_W);
                        }
                        try code_buffer.appendSlice(allocator, &buffer);
                    } else {
                        // error - registers sizes don't match
                    }
                },
                .mem => {},
                .imm => {},
                .label => {
                    // error maybe
                },
            }
        },
        .mem => {},
        .imm => {
            // error - immediate cannot be first operand of test
        },
        .label => {
            // error - label cannot be first operand of test
        },
    }
}

fn add(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        // error - add must have exactly 2 operands
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            switch (second) {
                .reg => {},
                .mem => {
                    switch (second.mem.mem) {
                        .label => {
                            const data_label = second.mem.mem.label;
                            const res = parser.dl_table.get(data_label);
                            if (res) |record| {
                                const address = data_virt_address + record.offset;
                                const code = modRMReg(first, second);
                                if (code % 8 == 4) {
                                    const sib = sibByte(.{ .base = try parser.Register.init(.Rbp), .index = try parser.Register.init(.Rsp), .scale = 0 }, try parser.Register.init(.Rbp));
                                    const buffer: [7]u8 = .{ 0x8B, code, sib, @truncate(address), @truncate(address >> 8), @truncate(address >> 16), @truncate(address >> 24) };
                                    if (rexw) {
                                        try code_buffer.append(allocator, REX_W);
                                    }
                                    try code_buffer.appendSlice(allocator, &buffer);
                                }
                            }
                        },
                        .addr => {
                            const code = modRMReg(first, second);
                            const buffer: [2]u8 = .{ 0x03, code };
                            if (rexw) {
                                try code_buffer.append(allocator, REX_W);
                            }
                            try code_buffer.appendSlice(allocator, &buffer);
                        },
                    }
                },
                .imm => {
                    const immsize = immMinSize(second.imm);
                    if (immsize == 1) {
                        const imm: u8 = @truncate(@as(u64, @bitCast(second.imm)));
                        switch (first.reg.size) {
                            1 => {},
                            2, 4, 8 => {
                                const code = modRMReg(first, .{ .reg = try parser.Register.init(.Rax) });
                                const buffer: [3]u8 = .{ 0x83, code, imm };
                                if (rexw) {
                                    try code_buffer.append(allocator, REX_W);
                                }
                                try code_buffer.appendSlice(allocator, &buffer);
                            },
                            else => {
                                // error but unreachable
                            },
                        }
                    }
                },
                .label => {},
            }
        },
        .mem => {},
        .imm => {
            // error - immediate cannot be first operand of mov
        },
        .label => {
            // error - label cannot be first operand of mov
        },
    }
}

fn div(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        // error - div must have exactly 1 operand
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            const rexb = if (first.reg.name.isAdditionalReg()) true else false;
            const code = modRMReg(first, .{ .reg = try parser.Register.init(.Rsi) });
            var buffer: [2]u8 = .{ 0xF7, code };
            if (first.reg.size == 1) {
                buffer[0] = 0xF6;
            }
            if (rexb) {
                try code_buffer.append(allocator, REX_WB);
            } else if (rexw) {
                try code_buffer.append(allocator, REX_W);
            }
            try code_buffer.appendSlice(allocator, &buffer);
        },
        .mem => {},
        .imm => {
            // error - immediate cannot be operand of div
        },
        .label => {
            // error - label cannot be operand of div
        },
    }
}

fn lea(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        // error - lea must have exactly 2 operands
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            const rexb = if (first.reg.name.isAdditionalReg()) true else false;
            switch (second) {
                .mem => {
                    switch (second.mem.mem) {
                        .addr => {
                            const code = modRMReg(first, second);
                            if (code % 8 == 4) {
                                // [--][--]
                                const sib = sibByte(.{ .base = undefined, .index = second.mem.mem.addr.index, .scale = second.mem.mem.addr.scale }, try parser.Register.init(second.mem.mem.addr.base.name));
                                const buffer: [3]u8 = .{ 0x8D, code, sib };
                                if (rexb) {
                                    try code_buffer.append(allocator, REX_WB);
                                } else if (rexw) {
                                    try code_buffer.append(allocator, REX_W);
                                }
                                try code_buffer.appendSlice(allocator, &buffer);
                            }
                        },
                        .label => {
                            // error - second op of lea must be mem
                        },
                    }
                },
                else => {
                    // error - second op of lea must be mem
                },
            }
        },
        else => {
            // error - first op of lea must be reg
        },
    }
}

fn mov(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 2) {
        // error - mov must have exactly 2 operands
    }
    const first = instr.operands.items[0];
    const second = instr.operands.items[1];
    switch (first) {
        .reg => {
            const rexw = switch (first.reg.size) {
                8 => true,
                else => false,
            };
            const rexb = if (first.reg.name.isAdditionalReg()) true else false;
            switch (second) {
                .reg => {},
                .mem => {
                    // mov rcx, [count]
                    switch (second.mem.mem) {
                        .label => {
                            const data_label = second.mem.mem.label;
                            const res = parser.dl_table.get(data_label);
                            if (res) |record| {
                                const address = data_virt_address + record.offset;
                                const code = modRMReg(first, second);
                                if (code % 8 == 4) {
                                    // [--][--]
                                    const sib = sibByte(.{ .base = try parser.Register.init(.Rbp), .index = try parser.Register.init(.Rsp), .scale = 0 }, try parser.Register.init(.Rbp));
                                    const buffer: [7]u8 = .{ 0x8B, code, sib, @truncate(address), @truncate(address >> 8), @truncate(address >> 16), @truncate(address >> 24) };
                                    if (rexw) {
                                        try code_buffer.append(allocator, REX_W);
                                    }
                                    try code_buffer.appendSlice(allocator, &buffer);
                                }
                            }
                        },
                        .addr => {
                            const code = modRMReg(first, second);
                            if (code % 8 == 4) {
                                // [--][--]
                                const sib = sibByte(.{ .base = undefined, .index = second.mem.mem.addr.index, .scale = second.mem.mem.addr.scale }, try parser.Register.init(second.mem.mem.addr.base.name));
                                var buffer: [3]u8 = .{ 0x8B, code, sib };
                                if (first.reg.size == 1) {
                                    buffer[0] = 0x8A;
                                }
                                if (rexb) {
                                    try code_buffer.append(allocator, REX_WB);
                                } else if (rexw) {
                                    try code_buffer.append(allocator, REX_W);
                                }
                                try code_buffer.appendSlice(allocator, &buffer);
                            }
                        },
                    }
                },
                .imm => {
                    // mov rax, 1
                    const immsize = immMinSize(second.imm);

                    if (immsize == first.reg.size or (first.reg.size == 8 and immsize <= 4)) {
                        const code = modRMReg(first, .{ .reg = try parser.Register.init(.Rax) });
                        switch (first.reg.size) {
                            1 => {
                                var buffer: [3]u8 = .{ 0xC6, code, @truncate(@as(u64, @bitCast(second.imm))) };
                                try code_buffer.appendSlice(allocator, &buffer);
                            },
                            2 => {
                                var buffer: [4]u8 = .{ 0xC7, code, @truncate(@as(u64, @bitCast(second.imm))), @truncate(@as(u64, @bitCast(second.imm >> 8))) };
                                try code_buffer.appendSlice(allocator, &buffer);
                            },
                            4, 8 => {
                                var buffer: [6]u8 = .{ 0xC7, code, @truncate(@as(u64, @bitCast(second.imm))), @truncate(@as(u64, @bitCast(second.imm >> 8))), @truncate(@as(u64, @bitCast(second.imm >> 16))), @truncate(@as(u64, @bitCast(second.imm >> 24))) };
                                if (rexb) {
                                    try code_buffer.append(allocator, REX_WB);
                                } else if (rexw) {
                                    try code_buffer.append(allocator, REX_W);
                                }
                                try code_buffer.appendSlice(allocator, &buffer);
                            },
                            else => {
                                // error but unreachable
                            },
                        }
                    }
                },
                .label => {
                    // mov rbx, label
                    const data_label = second.label.name;
                    const res = parser.dl_table.get(data_label);
                    if (res) |record| {
                        const address = data_virt_address + record.offset;

                        if (address <= std.math.maxInt(u32)) {
                            // label 32-bit
                            const code = modRMReg(first, .{ .reg = try parser.Register.init(.Rax) });
                            const buffer: [7]u8 = .{ REX_W, 0xC7, code, @truncate(address), @truncate(address >> 8), @truncate(address >> 16), @truncate(address >> 24) };
                            try code_buffer.appendSlice(allocator, &buffer);
                        } else {
                            // label 64-bit
                        }
                    } else {
                        // error - label is not defined
                    }
                },
            }
        },
        .mem => {
            switch (first.mem.mem) {
                .label => {},
                .addr => {
                    switch (second) {
                        .reg => {
                            const rexw = switch (second.reg.size) {
                                8 => true,
                                else => false,
                            };
                            const rexb = if (second.reg.name.isAdditionalReg()) true else false;
                            const code = modRMReg(second, first);
                            if (code % 8 == 4) {
                                // [--][--]
                                const sib = sibByte(.{ .base = undefined, .index = first.mem.mem.addr.index, .scale = first.mem.mem.addr.scale }, try parser.Register.init(first.mem.mem.addr.base.name));
                                var buffer: [3]u8 = .{ 0x89, code, sib };
                                if (second.reg.size == 1) {
                                    buffer[0] = 0x88;
                                }
                                if (rexb) {
                                    try code_buffer.append(allocator, REX_WB);
                                } else if (rexw) {
                                    try code_buffer.append(allocator, REX_W);
                                }
                                try code_buffer.appendSlice(allocator, &buffer);
                            }
                        },
                        .imm => {},
                        .mem => {
                            // error - mov mem to mem not allowed
                        },
                        .label => {},
                    }
                },
            }
        },
        .imm => {
            // error - immediate cannot be first operand of mov
        },
        .label => {
            // error - label cannot be first operand of mov
        },
    }
}

fn jcc(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction, mnem: lexer.TokenType) !void {
    if (instr.operands.items.len != 1) {
        // error - jne must have exactly 1 operand
    }
    const first = instr.operands.items[0];
    switch (first) {
        .label => {
            // only uses rel32 for now
            var buffer: [6]u8 = .{ 0x0F, undefined, undefined, undefined, undefined, undefined };

            buffer[1] = switch (mnem) {
                .Je => 0x84,
                .Jne => 0x85,
                .Ja => 0x87,
                .Jz => 0x84,
                else => undefined,
            };

            try code_buffer.appendSlice(allocator, &buffer);

            var result = try rellocations.getOrPut(first.label.name);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            }
            const offset = code_buffer.items.len - 4;
            try result.value_ptr.append(allocator, offset);
        },
        else => {
            // error - jcc can jump only to label name
        },
    }
}

fn push(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        // error - push must have exactly 1 operand
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg => {
            const rexb = if (first.reg.name.isAdditionalReg()) true else false;
            var code: u8 = 0x50;
            switch (first.reg.size) {
                2, 8 => {
                    code += regCode(first.reg.name);
                },
                else => {
                    // error - invalid operand size
                },
            }
            if (rexb) {
                try code_buffer.append(allocator, REX_B);
            }
            try code_buffer.append(allocator, code);
        },
        .mem => {
            //
        },
        .imm => {
            //
        },
        .label => {
            //
        },
    }
}

fn pop(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        // error - push must have exactly 1 operand
    }
    const first = instr.operands.items[0];
    switch (first) {
        .reg => {
            const rexb = if (first.reg.name.isAdditionalReg()) true else false;
            var code: u8 = 0x58;
            switch (first.reg.size) {
                2, 8 => {
                    code += regCode(first.reg.name);
                },
                else => {
                    // error - invalid operand size
                },
            }
            if (rexb) {
                try code_buffer.append(allocator, REX_B);
            }
            try code_buffer.append(allocator, code);
        },
        .mem => {
            //
        },
        .imm => {
            //
        },
        .label => {
            //
        },
    }
}

fn jmp(allocator: std.mem.Allocator, instr: *const parser.CpuInstruction) !void {
    if (instr.operands.items.len != 1) {
        // error - jmp must have exactly 1 operand
    }
    const first = instr.operands.items[0];
    switch (first) {
        .label => {
            // only uses rel32 for now
            var buffer: [5]u8 = .{ 0xE9, undefined, undefined, undefined, undefined };

            try code_buffer.appendSlice(allocator, &buffer);

            var result = try rellocations.getOrPut(first.label.name);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            }
            const offset = code_buffer.items.len - 4;
            try result.value_ptr.append(allocator, offset);
        },
        else => {
            // error - jmp can jump only to label name
        },
    }
}

fn genInstruction(allocator: std.mem.Allocator, instruction: parser.CodeInstruction) !void {
    switch (instruction) {
        .label => {
            const cl_ptr = parser.cl_table.getPtr(instruction.label.name);
            if (cl_ptr) |cl| {
                cl.offset = code_buffer.items.len;
                const res = try rellocations.getOrPut(instruction.label.name);
                if (!res.found_existing) {
                    res.value_ptr.* = std.ArrayList(u64).empty;
                }
            }
        },
        .cpu => {
            switch (instruction.cpu.mnem) {
                .Mov => {
                    try mov(allocator, &instruction.cpu);
                },
                .Xor => {
                    try xor(allocator, &instruction.cpu);
                },
                .Add => {
                    try add(allocator, &instruction.cpu);
                },
                .Inc => {
                    try inc(allocator, &instruction.cpu);
                },
                .Dec => {
                    try dec(allocator, &instruction.cpu);
                },
                .Ja, .Je, .Jne, .Jz => {
                    try jcc(allocator, &instruction.cpu, instruction.cpu.mnem);
                },
                .Syscall => {
                    try syscall(allocator, &instruction.cpu);
                },
                .Div => {
                    try div(allocator, &instruction.cpu);
                },
                .Test => {
                    try testi(allocator, &instruction.cpu);
                },
                .Lea => {
                    try lea(allocator, &instruction.cpu);
                },
                .Push => {
                    try push(allocator, &instruction.cpu);
                },
                .Pop => {
                    try pop(allocator, &instruction.cpu);
                },
                .Jmp => {
                    try jmp(allocator, &instruction.cpu);
                },
                else => {
                    //
                },
            }
        },
    }
}

fn firstPass(allocator: std.mem.Allocator, instructions: []parser.CodeInstruction) !void {
    for (instructions) |instruction| {
        try genInstruction(allocator, instruction);
    }
}

fn secondPass() void {
    var cl_iter = parser.cl_table.iterator();
    while (cl_iter.next()) |cl| {
        const label = cl.key_ptr.*;
        if (cl.value_ptr.defined) {
            const result = rellocations.get(label);
            if (result) |rellocs| {
                for (rellocs.items) |ind| {
                    const address: i64 = @intCast(cl.value_ptr.offset);
                    const offset: i64 = @intCast(ind);
                    const rel32: i32 = @intCast(address - offset - 4);
                    const buffer: [4]u8 = std.mem.toBytes(rel32);
                    for (&buffer, 0..) |byte, i| {
                        code_buffer.items[@as(usize, @intCast(offset)) + i] = byte;
                    }
                }
            }
        }
    }
    if (parser.cl_table.get(parser.program.entry.name)) |rec| {
        if (rec.defined) {
            parser.program.entry.addr = @intCast(rec.offset);
        }
    }
}

pub fn bufferizeCodeSection(section: *parser.CodeSection, allocator: std.mem.Allocator, data_address: u64) !void {
    rellocations = std.StringHashMap(std.ArrayList(u64)).init(allocator);
    data_virt_address = data_address;
    try firstPass(allocator, section.instr.items);

    printFirstPass();

    secondPass();

    printCodeBuffer();

    std.debug.print("Entry - {s}: {d}\n", .{ parser.program.entry.name, parser.program.entry.addr });
}

fn printFirstPass() void {
    std.debug.print("Rellocations table: \n", .{});
    var iter = rellocations.iterator();
    while (iter.next()) |entry| {
        std.debug.print("{s}: \n", .{entry.key_ptr.*});
        for (entry.value_ptr.items) |offset| {
            std.debug.print("  {d}\n", .{offset});
        }
    }

    std.debug.print("Code labels table: \n", .{});
    var iter2 = parser.cl_table.iterator();
    while (iter2.next()) |entry| {
        std.debug.print("{s}: {d}, def - {}\n", .{ entry.key_ptr.*, entry.value_ptr.offset, entry.value_ptr.defined });
    }
}

fn printCodeBuffer() void {
    std.debug.print("Code buffer:\n", .{});
    for (code_buffer.items) |op| {
        std.debug.print("{x:02}", .{op});
    }
    std.debug.print("\n", .{});
}
