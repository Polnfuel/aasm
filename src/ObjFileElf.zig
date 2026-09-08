const std = @import("std");
const elf = std.elf;
const dwarf = std.dwarf;

const utils = @import("utils");
const Program = @import("Program");
const Label = Program.Label;

/// Elf64 object file representation
const ObjFileElf = @This();

pub const ObjectError = std.Io.Writer.Error || std.mem.Allocator.Error || std.Io.File.OpenError;

const Buffers = struct {
    const Buffer = std.ArrayList(u8);

    text: Buffer = .empty,
    data: Buffer = .empty,
    relatext: std.ArrayList(elf.Elf64.Rela) = .empty,
    debug_line: Buffer = .empty,
    debug_line_str: Buffer = .empty,
    reladebug_line: std.ArrayList(elf.Elf64.Rela) = .empty,
    debug_info: Buffer = .empty,
    debug_abbrev: Buffer = .empty,
    debug_str: Buffer = .empty,
    reladebug_info: std.ArrayList(elf.Elf64.Rela) = .empty,
    symtab: std.ArrayList(elf.Elf64.Sym) = .empty,
    strtab: Buffer = .empty,
    shstrtab: Buffer = .empty,

    pub fn deinit(self: *Buffers, alloc: std.mem.Allocator) void {
        self.relatext.deinit(alloc);
        self.debug_line.deinit(alloc);
        self.debug_line_str.deinit(alloc);
        self.reladebug_line.deinit(alloc);
        self.debug_info.deinit(alloc);
        self.debug_abbrev.deinit(alloc);
        self.debug_str.deinit(alloc);
        self.reladebug_info.deinit(alloc);
        self.symtab.deinit(alloc);
        self.strtab.deinit(alloc);
        self.shstrtab.deinit(alloc);
    }
};

const Sections = struct {
    const Section = struct {
        ind: u8 = 0,
        name: u32 = 0,
        offset: u64 = 0,
        size: usize = 0,
    };

    text: Section = Section{},
    data: Section = Section{},
    bss: Section = Section{},
    relatext: Section = Section{},
    debug_line: Section = Section{},
    debug_line_str: Section = Section{},
    reladebug_line: Section = Section{},
    debug_info: Section = Section{},
    debug_abbrev: Section = Section{},
    debug_str: Section = Section{},
    reladebug_info: Section = Section{},
    symtab: Section = Section{},
    strtab: Section = Section{},
    shstrtab: Section = Section{},

    pub fn print(self: *Sections) void {
        const info = @typeInfo(Sections).@"struct";
        inline for (info.fields) |field| {
            std.debug.print("{d:2} - {x:6} - {s} - {x}\n", .{
                @field(self, field.name).ind,
                @field(self, field.name).offset,
                field.name,
                @field(self, field.name).size,
            });
        }
    }
};

buffs: *Buffers,
sections: *Sections,
output_path: []const u8,

txt_sym: u32,
dbg_ln_sym: u32,
dbg_ln_str_sym: u32,
dbg_str_sym: u32,

symtab_info: u32,

pub fn init(self: *ObjFileElf, output_path: []const u8) std.mem.Allocator.Error!void {
    self.buffs = try utils.alloc.create(Buffers);
    self.buffs.* = Buffers{};
    self.sections = try utils.alloc.create(Sections);
    self.sections.* = Sections{};
    self.output_path = output_path;

    try self.buffs.symtab.append(utils.alloc, .{ .name = 0, .value = 0, .size = 0, .info = .{ .type = .NOTYPE, .bind = .LOCAL }, .other = .{ .visibility = .DEFAULT }, .shndx = elf.SHN_UNDEF });
    try self.buffs.strtab.append(utils.alloc, 0);
    try self.buffs.shstrtab.append(utils.alloc, 0);

    self.txt_sym = 0;
    self.dbg_ln_sym = 0;
    self.dbg_ln_str_sym = 0;
    self.dbg_str_sym = 0;
    self.symtab_info = undefined;
}

fn printStrtab(self: *ObjFileElf) void {
    std.debug.print(" Strtab: \n", .{});
    for (self.buffs.strtab.items) |byte| {
        std.debug.print("{c}", .{if (byte == 0) '.' else byte});
    }
    std.debug.print("\n", .{});

    std.debug.print(" Shstrtab: \n", .{});
    for (self.buffs.shstrtab.items) |byte| {
        std.debug.print("{c}", .{if (byte == 0) '.' else byte});
    }
    std.debug.print("\n", .{});
}

fn printSymtab(self: *ObjFileElf) void {
    std.debug.print(" Symtab: \n", .{});
    for (self.buffs.symtab.items) |sym| {
        const sym_name: []const u8 = std.mem.sliceTo(self.buffs.strtab.items[sym.name..], 0);
        std.debug.print("{x:016}{x:4}{t:8}{t:8}{t:8}{d:3} {s}\n", .{
            sym.value,
            sym.size,
            sym.info.type,
            sym.info.bind,
            sym.other.visibility,
            sym.shndx,
            sym_name,
        });
    }
}

fn appendName(self: *ObjFileElf, name: []const u8) std.mem.Allocator.Error!u32 {
    const prev_len = self.buffs.strtab.items.len;
    try self.buffs.strtab.appendSlice(utils.alloc, name);
    try self.buffs.strtab.append(utils.alloc, 0);
    return @truncate(prev_len);
}

fn appendSectionSymbol(self: *ObjFileElf, name: []const u8, shndx: u16) std.mem.Allocator.Error!void {
    try self.buffs.symtab.append(utils.alloc, .{
        .name = try self.appendName(name),
        .value = 0,
        .info = .{ .type = .SECTION, .bind = .LOCAL },
        .shndx = shndx,
        .other = .{ .visibility = .DEFAULT },
        .size = 0,
    });
}

fn appendSectionName(self: *ObjFileElf, name: []const u8) std.mem.Allocator.Error!u32 {
    const prev_len = self.buffs.shstrtab.items.len;
    try self.buffs.shstrtab.appendSlice(utils.alloc, name);
    try self.buffs.shstrtab.append(utils.alloc, 0);
    return @truncate(prev_len);
}

fn addSymbolsToSymtab(self: *ObjFileElf, program: *Program) std.mem.Allocator.Error!void {
    const buffs = self.buffs;
    const secs = self.sections;

    var symbols_map: std.AutoHashMapUnmanaged(Label, u32) = .empty;
    defer symbols_map.deinit(utils.alloc);

    var funcs = program.funcs.iterator();
    while (funcs.next()) |sym| {
        if (sym.value_ptr.visib == .Local) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(utils.stringValue(sym.key_ptr.*)),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .LOCAL, .type = .FUNC },
                .other = .{ .visibility = .DEFAULT },
                .shndx = secs.text.ind,
            };

            try symbols_map.put(utils.alloc, sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(utils.alloc, symbol);
        }
    }

    var data_vars = program.data_vars.iterator();
    while (data_vars.next()) |sym| {
        if (sym.value_ptr.visib == .Local) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(utils.stringValue(sym.key_ptr.*)),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .LOCAL, .type = .OBJECT },
                .other = .{ .visibility = .DEFAULT },
                .shndx = switch (sym.value_ptr.block) {
                    .Data => secs.data.ind,
                    .Bss => secs.bss.ind,
                },
            };

            if (utils.flags.debug) {
                try self.addVariableDebugInfo(sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            }
            try symbols_map.put(utils.alloc, sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(utils.alloc, symbol);
        }
    }

    self.symtab_info = @truncate(buffs.symtab.items.len);

    funcs = program.funcs.iterator();
    while (funcs.next()) |sym| {
        if (sym.value_ptr.visib == .Export) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(utils.stringValue(sym.key_ptr.*)),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .GLOBAL, .type = .FUNC },
                .other = .{ .visibility = .DEFAULT },
                .shndx = secs.text.ind,
            };

            try symbols_map.put(utils.alloc, sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(utils.alloc, symbol);
        }
    }

    data_vars = program.data_vars.iterator();
    while (data_vars.next()) |sym| {
        if (sym.value_ptr.visib == .Export) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(utils.stringValue(sym.key_ptr.*)),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .GLOBAL, .type = .OBJECT },
                .other = .{ .visibility = .DEFAULT },
                .shndx = switch (sym.value_ptr.block) {
                    .Data => secs.data.ind,
                    .Bss => secs.bss.ind,
                },
            };

            if (utils.flags.debug) {
                try self.addVariableDebugInfo(sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            }
            try symbols_map.put(utils.alloc, sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(utils.alloc, symbol);
        }
    }

    var lib_imports: std.AutoHashMapUnmanaged(Label, void) = .empty;
    defer lib_imports.deinit(utils.alloc);

    var imports = program.imports.iterator();
    while (imports.next()) |sym| {
        if (sym.value_ptr.* > 0) {
            try lib_imports.put(utils.alloc, sym.key_ptr.*, {});
        }

        const symbol = elf.Elf64.Sym{
            .name = try self.appendName(utils.stringValue(sym.key_ptr.*)),
            .value = 0,
            .size = 0,
            .info = .{ .bind = .GLOBAL, .type = .NOTYPE },
            .other = .{ .visibility = .DEFAULT },
            .shndx = elf.SHN_UNDEF,
        };

        try symbols_map.put(utils.alloc, sym.key_ptr.*, @truncate(buffs.symtab.items.len));
        try buffs.symtab.append(utils.alloc, symbol);
    }

    for (program.relocations.items) |relocation| {
        const sym_ind: u32 = symbols_map.get(relocation.name).?;
        const is_import: bool = lib_imports.contains(relocation.name);
        const rel_type: elf.R_X86_64 = switch (relocation.type) {
            .Abs64 => .@"64",
            .Abs32 => .@"32",
            .Abs32S => .@"32S",
            .Rel32C => if (is_import) .PLT32 else .PC32,
            .Rel32D => .PC32,
        };
        const rela = elf.Elf64.Rela{
            .offset = relocation.offset,
            .info = .{ .sym = sym_ind, .type = @intFromEnum(rel_type) },
            .addend = relocation.addend,
        };
        try buffs.relatext.append(utils.alloc, rela);
    }
}

fn writeUleb128(buf: *Buffers.Buffer, a: std.mem.Allocator, arg: anytype) std.mem.Allocator.Error!void {
    const Arg = @TypeOf(arg);
    const Int = switch (Arg) {
        comptime_int => std.math.IntFittingRange(arg, arg),
        else => Arg,
    };
    const Value = if (@typeInfo(Int).int.bits < 8) u8 else Int;
    var value: Value = arg;
    while (true) {
        var byte: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) {
            byte |= 0x80;
        }
        try buf.append(a, byte);
        if (value == 0) {
            break;
        }
    }
}

fn patchDebugInfoHeader(self: *ObjFileElf) std.mem.Allocator.Error!void {
    try self.buffs.debug_info.append(utils.alloc, 0);

    const unit_length = self.buffs.debug_info.items.len - 4;
    std.mem.writeInt(u32, self.buffs.debug_info.items[0..4], @truncate(unit_length), .little);
}

fn addVariableDebugInfo(self: *ObjFileElf, name: Label, sym_ind: u32) std.mem.Allocator.Error!void {
    const name_offset: u32 = @truncate(self.buffs.debug_str.items.len);
    try self.buffs.debug_str.appendSlice(utils.alloc, utils.stringValue(name));
    try self.buffs.debug_str.append(utils.alloc, 0);

    const die_offset: u32 = @truncate(self.buffs.debug_info.items.len);
    try self.buffs.debug_info.appendSlice(utils.alloc, &.{
        0x02, 0,             0, 0, 0,
        0x09, dwarf.OP.addr, 0, 0, 0,
        0,    0,             0, 0, 0,
    });

    try self.buffs.reladebug_info.append(utils.alloc, .{
        .offset = die_offset + 1,
        .info = .{ .sym = self.dbg_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = name_offset,
    });
    try self.buffs.reladebug_info.append(utils.alloc, .{
        .offset = die_offset + 7,
        .info = .{ .sym = sym_ind, .type = @intFromEnum(elf.R_X86_64.@"64") },
        .addend = 0,
    });
}

fn genDwarfDebugInformation(self: *ObjFileElf, program: *Program, rel_path: []const u8) std.mem.Allocator.Error!void {
    const buffs = self.buffs;

    // Names for line number program
    const dir_path = std.fs.path.dirname(rel_path);
    const dir_cnt: u8 = if (dir_path != null) 2 else 1;
    try buffs.debug_line_str.appendSlice(utils.alloc, utils.comp_dir);
    try buffs.debug_line_str.append(utils.alloc, 0);
    const dir1_ind: u32 = @truncate(buffs.debug_line_str.items.len);
    if (dir_cnt > 1) {
        try buffs.debug_line_str.appendSlice(utils.alloc, dir_path.?);
        try buffs.debug_line_str.append(utils.alloc, 0);
    }
    const filename_ind: u32 = @truncate(buffs.debug_line_str.items.len);
    try buffs.debug_line_str.appendSlice(utils.alloc, program.file_name);
    try buffs.debug_line_str.append(utils.alloc, 0);

    // Line number program header and file/directories entries
    try buffs.debug_line.appendSlice(utils.alloc, &.{
        0,    0,    0,    0,    0x5,  0x0,
        0x8,  0x0,  0,    0,    0,    0,
        0x01, 0x01, 0x01, 0xfb, 0x0e, 0x0d,
        0,    1,    1,    1,    1,    0,
        0,    0,    1,    0,    0,    1,
    });

    try buffs.debug_line.appendSlice(utils.alloc, &.{
        0x01, 0x01, 0x1f, dir_cnt,
    });

    const dirs_start = buffs.debug_line.items.len;
    for (0..dir_cnt) |_| {
        try buffs.debug_line.appendSlice(utils.alloc, &.{ 0, 0, 0, 0 });
    }

    try buffs.debug_line.appendSlice(utils.alloc, &.{
        0x02, 0x01, 0x1f, 0x02, 0x0f, 0x02,
    });
    const files_start = buffs.debug_line.items.len;
    for (0..2) |_| {
        try buffs.debug_line.appendSlice(utils.alloc, &.{
            0, 0, 0, 0, dir_cnt - 1,
        });
    }
    buffs.debug_line.items[8] = @truncate(buffs.debug_line.items.len - 12);

    // Start of Line Number Program
    try buffs.debug_line.appendSlice(utils.alloc, &.{
        dwarf.LNS.extended_op, 0x09, dwarf.LNE.set_address,
        0,                     0,    0,
        0,                     0,    0,
        0,                     0,
    });
    const text_reloc_offset = buffs.debug_line.items.len - 8;

    const max_line_inc = 8;
    var line: usize = 1;
    var address: usize = 0;
    for (program.line_program.items[0 .. program.line_program.items.len - 1]) |entry| {
        const line_increment: u8 = @truncate(entry.line - line);
        const address_increment: u8 = @truncate(entry.offset - address);
        if (line_increment <= max_line_inc) {
            // TODO: if opcode > 255 do else {}
            const opcode: u8 = (line_increment + 5) + (0x0e * address_increment) + 0x0d;
            try buffs.debug_line.append(utils.alloc, opcode);
        } else {
            try buffs.debug_line.appendSlice(utils.alloc, &.{
                dwarf.LNS.advance_pc, address_increment,
            });
            try buffs.debug_line.appendSlice(utils.alloc, &.{
                dwarf.LNS.advance_line, line_increment,
            });
            try buffs.debug_line.append(utils.alloc, dwarf.LNS.copy);
        }
        line += line_increment;
        address += address_increment;
    }
    const last_addr_inc: u8 = @truncate(program.line_program.items[program.line_program.items.len - 1].offset - address);
    try buffs.debug_line.appendSlice(utils.alloc, &.{
        dwarf.LNS.advance_pc,  last_addr_inc,
        dwarf.LNS.extended_op, dwarf.LNE.end_sequence,
        dwarf.LNS.copy,
    });
    // End of Line Number Program

    // debug_line relocations
    try buffs.reladebug_line.append(utils.alloc, .{
        .offset = dirs_start,
        .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });
    if (dir_cnt > 1) {
        try buffs.reladebug_line.append(utils.alloc, .{
            .offset = dirs_start + 4,
            .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
            .addend = dir1_ind,
        });
    }
    try buffs.reladebug_line.append(utils.alloc, .{
        .offset = files_start,
        .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = filename_ind,
    });
    try buffs.reladebug_line.append(utils.alloc, .{
        .offset = files_start + 5,
        .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = filename_ind,
    });
    try buffs.reladebug_line.append(utils.alloc, .{
        .offset = text_reloc_offset,
        .info = .{ .sym = self.txt_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });

    const unit_length = buffs.debug_line.items.len - 4;
    std.mem.writeInt(u32, buffs.debug_line.items[0..4], @truncate(unit_length), .little);

    // Names for compile_unit abbrev
    try buffs.debug_str.appendSlice(utils.alloc, rel_path);
    try buffs.debug_str.append(utils.alloc, 0);
    const dir_ind: u32 = @truncate(buffs.debug_str.items.len);
    try buffs.debug_str.appendSlice(utils.alloc, utils.comp_dir);
    try buffs.debug_str.append(utils.alloc, 0);

    // DW_TAG_compile_unit abbrev
    try buffs.debug_abbrev.appendSlice(utils.alloc, &.{
        0x1,                dwarf.TAG.compile_unit, dwarf.CHILDREN.yes,
        dwarf.AT.stmt_list, dwarf.FORM.sec_offset,  dwarf.AT.low_pc,
        dwarf.FORM.addr,    dwarf.AT.high_pc,       dwarf.FORM.udata,
        dwarf.AT.name,      dwarf.FORM.strp,        dwarf.AT.comp_dir,
        dwarf.FORM.strp,    0x00,                   0x00,
    });

    // DW_TAG_variable
    try buffs.debug_abbrev.appendSlice(utils.alloc, &.{
        0x2,                dwarf.TAG.variable, dwarf.CHILDREN.no,
        dwarf.AT.name,      dwarf.FORM.strp,    dwarf.AT.location,
        dwarf.FORM.exprloc, 0x00,               0x00,
    });

    try buffs.debug_abbrev.append(utils.alloc, 0);

    // DIE for compile_unit
    try buffs.debug_info.appendSlice(utils.alloc, &.{
        0,    0,   0,                0,
        0x05, 0x0, dwarf.UT.compile, 0x08,
        0,    0,   0,                0,
        0x01, 0,   0,                0,
        0,    0,   0,                0,
        0,    0,   0,                0,
        0,
    });
    try writeUleb128(&buffs.debug_info, utils.alloc, program.code_block.buffer.items.len);
    const name_offset = buffs.debug_info.items.len;
    try buffs.debug_info.appendSlice(utils.alloc, &.{
        0, 0, 0, 0,
        0, 0, 0, 0,
    });

    // debug_info compile_unit relocations
    try buffs.reladebug_info.append(utils.alloc, .{
        .offset = 13,
        .info = .{ .sym = self.dbg_ln_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });
    try buffs.reladebug_info.append(utils.alloc, .{
        .offset = 17,
        .info = .{ .sym = self.txt_sym, .type = @intFromEnum(elf.R_X86_64.@"64") },
        .addend = 0,
    });
    try buffs.reladebug_info.append(utils.alloc, .{
        .offset = name_offset,
        .info = .{ .sym = self.dbg_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });
    try buffs.reladebug_info.append(utils.alloc, .{
        .offset = name_offset + 4,
        .info = .{ .sym = self.dbg_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = dir_ind,
    });
}

fn incInd(ind: *u8) u8 {
    const prev = ind.*;
    ind.* += 1;
    return prev;
}

pub fn compileProgram(self: *ObjFileElf, program: *Program, rel_path: []const u8) ObjectError!void {
    const buffs = self.buffs;
    const secs = self.sections;

    var ind: u8 = 1;

    secs.text.offset = std.mem.alignForward(u64, @sizeOf(elf.Elf64.Ehdr), 0x8);
    if (program.flags.has_code) {
        buffs.text = program.code_block.buffer;
        secs.text.ind = incInd(&ind);
        secs.text.name = try self.appendSectionName(".text");
        secs.text.size = buffs.text.items.len;
        self.txt_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(".text", secs.text.ind);
    }
    secs.data.offset = std.mem.alignForward(usize, secs.text.offset + secs.text.size, 0x8);
    if (program.flags.has_data) {
        buffs.data = program.data_buffer;
        secs.data.ind = incInd(&ind);
        secs.data.name = try self.appendSectionName(".data");
        secs.data.size = buffs.data.items.len;
    }
    secs.bss.offset = std.mem.alignForward(usize, secs.data.offset + secs.data.size, 0x8);
    if (program.flags.has_bss) {
        secs.bss.ind = incInd(&ind);
        secs.bss.name = try self.appendSectionName(".bss");
        secs.bss.size = program.bss_len;
    }
    if (program.relocations.items.len > 0) {
        secs.relatext.ind = incInd(&ind);
        secs.relatext.name = try self.appendSectionName(".rela.text");
        secs.relatext.offset = std.mem.alignForward(usize, secs.bss.offset, 0x8);
        secs.relatext.size = program.relocations.items.len * @sizeOf(elf.Elf64.Rela);
    } else {
        secs.relatext.offset = secs.bss.offset;
    }
    if (utils.flags.debug) {
        secs.debug_line.ind = incInd(&ind);
        secs.debug_line_str.ind = incInd(&ind);
        secs.reladebug_line.ind = incInd(&ind);
        secs.debug_info.ind = incInd(&ind);
        secs.debug_abbrev.ind = incInd(&ind);
        secs.debug_str.ind = incInd(&ind);
        secs.reladebug_info.ind = incInd(&ind);

        secs.debug_line.name = try self.appendSectionName(".debug_line");
        self.dbg_ln_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(".debug_line", secs.debug_line.ind);
        secs.debug_line_str.name = try self.appendSectionName(".debug_line_str");
        self.dbg_ln_str_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(".debug_line_str", secs.debug_line_str.ind);
        secs.reladebug_line.name = try self.appendSectionName(".rela.debug_line");
        secs.debug_info.name = try self.appendSectionName(".debug_info");
        try self.appendSectionSymbol(".debug_info", secs.debug_info.ind);
        secs.debug_abbrev.name = try self.appendSectionName(".debug_abbrev");
        secs.debug_str.name = try self.appendSectionName(".debug_str");
        self.dbg_str_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(".debug_str", secs.debug_str.ind);
        secs.reladebug_info.name = try self.appendSectionName(".rela.debug_info");

        try self.genDwarfDebugInformation(program, rel_path);
    } else {
        secs.reladebug_info.offset = secs.relatext.offset + secs.relatext.size;
    }
    secs.symtab.ind = incInd(&ind);
    secs.symtab.name = try self.appendSectionName(".symtab");

    try self.addSymbolsToSymtab(program);
    if (utils.flags.debug) {
        try self.patchDebugInfoHeader();
        secs.debug_line.offset = secs.relatext.offset + secs.relatext.size;
        secs.debug_line.size = buffs.debug_line.items.len;
        secs.debug_line_str.offset = secs.debug_line.offset + secs.debug_line.size;
        secs.debug_line_str.size = buffs.debug_line_str.items.len;
        secs.reladebug_line.offset = secs.debug_line_str.offset + secs.debug_line_str.size;
        secs.reladebug_line.size = buffs.reladebug_line.items.len * @sizeOf(elf.Elf64.Rela);
        secs.debug_info.offset = secs.reladebug_line.offset + secs.reladebug_line.size;
        secs.debug_info.size = buffs.debug_info.items.len;
        secs.debug_abbrev.offset = secs.debug_info.offset + secs.debug_info.size;
        secs.debug_abbrev.size = buffs.debug_abbrev.items.len;
        secs.debug_str.offset = secs.debug_abbrev.offset + secs.debug_abbrev.size;
        secs.debug_str.size = buffs.debug_str.items.len;
        secs.reladebug_info.offset = secs.debug_str.offset + secs.debug_str.size;
        secs.reladebug_info.size = buffs.reladebug_info.items.len * @sizeOf(elf.Elf64.Rela);
    }

    secs.symtab.offset = secs.reladebug_info.offset + secs.reladebug_info.size;
    secs.symtab.size = buffs.symtab.items.len * @sizeOf(elf.Elf64.Sym);

    secs.strtab.ind = incInd(&ind);
    secs.strtab.name = try self.appendSectionName(".strtab");
    secs.strtab.offset = secs.symtab.offset + secs.symtab.size;
    secs.strtab.size = buffs.strtab.items.len;

    secs.shstrtab.ind = incInd(&ind);
    secs.shstrtab.name = try self.appendSectionName(".shstrtab");
    secs.shstrtab.offset = secs.strtab.offset + secs.strtab.size;
    secs.shstrtab.size = buffs.shstrtab.items.len;

    if (!utils.flags.quiet) {
        secs.print();
        self.printStrtab();
        self.printSymtab();
    }
}

pub fn writeObjFile(self: *ObjFileElf, program: *Program) ObjectError!void {
    const buffs = self.buffs;
    const secs = self.sections;

    const shtable = std.mem.alignForward(usize, secs.shstrtab.offset + secs.shstrtab.size, 0x8);
    const file_size = shtable + @as(usize, (secs.shstrtab.ind + 1)) * @sizeOf(elf.Elf64.Shdr);
    if (!utils.flags.quiet) {
        std.debug.print("shtable start: {x}\n", .{shtable});
        std.debug.print("file size: {d}\n", .{file_size});
    }

    const file_buffer = try utils.alloc.alloc(u8, file_size);
    defer utils.alloc.free(file_buffer);

    const file_name = if (self.output_path.len == 0)
        try std.mem.concat(utils.alloc, u8, &.{ std.fs.path.stem(program.file_name), @ptrCast(".o") })
    else
        self.output_path;
    defer if (self.output_path.len == 0) utils.alloc.free(file_name);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(utils.io, file_name, .{});
    defer file.close(utils.io);

    var file_writer = file.writer(utils.io, file_buffer);
    const writer = &file_writer.interface;

    try writer.writeStruct(elf.Elf64.Ehdr{
        .ident = [_]u8{ elf.MAGIC[0], elf.MAGIC[1], elf.MAGIC[2], elf.MAGIC[3], elf.ELFCLASS64, elf.ELFDATA2LSB, 1, @intFromEnum(elf.OSABI.GNU), 0, 0, 0, 0, 0, 0, 0, 0 },
        .type = elf.ET.REL,
        .machine = elf.EM.X86_64,
        .version = 1,
        .entry = 0,
        .phoff = 0,
        .shoff = shtable,
        .flags = 0,
        .ehsize = @sizeOf(elf.Elf64.Ehdr),
        .phentsize = 0,
        .phnum = 0,
        .shentsize = @sizeOf(elf.Elf64.Shdr),
        .shnum = secs.shstrtab.ind + 1,
        .shstrndx = secs.shstrtab.ind,
    }, .little);

    var padding: usize = 0;
    if (program.flags.has_code) {
        padding = secs.text.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.text.items);
    }
    if (program.flags.has_data) {
        padding = secs.data.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.data.items);
    }
    if (secs.relatext.size > 0) {
        padding = secs.relatext.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        for (buffs.relatext.items) |rela| {
            try writer.writeStruct(rela, .little);
        }
    }
    if (utils.flags.debug) {
        _ = try writer.write(buffs.debug_line.items);
        _ = try writer.write(buffs.debug_line_str.items);
        for (buffs.reladebug_line.items) |rela| {
            try writer.writeStruct(rela, .little);
        }
        _ = try writer.write(buffs.debug_info.items);
        _ = try writer.write(buffs.debug_abbrev.items);
        _ = try writer.write(buffs.debug_str.items);
        for (buffs.reladebug_info.items) |rela| {
            try writer.writeStruct(rela, .little);
        }
    }
    padding = secs.symtab.offset - writer.end;
    _ = try writer.splatByte(0, padding);
    for (buffs.symtab.items) |sym| {
        try writer.writeStruct(sym, .little);
    }
    _ = try writer.write(buffs.strtab.items);
    _ = try writer.write(buffs.shstrtab.items);

    padding = shtable - writer.end;
    _ = try writer.splatByte(0, padding);
    try writer.writeStruct(elf.Elf64.Shdr{ .name = 0, .type = .NULL, .addr = 0, .addralign = 0, .entsize = 0, .flags = .{ .shf = .{} }, .info = 0, .link = 0, .offset = 0, .size = 0 }, .little);
    if (program.flags.has_code) {
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.text.name,
            .type = .PROGBITS,
            .flags = .{ .shf = .{ .ALLOC = true, .EXECINSTR = true } },
            .addr = 0,
            .offset = secs.text.offset,
            .size = secs.text.size,
            .link = 0,
            .info = 0,
            .addralign = 0x8,
            .entsize = 0,
        }, .little);
    }
    if (program.flags.has_data) {
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.data.name,
            .type = .PROGBITS,
            .flags = .{ .shf = .{ .ALLOC = true, .WRITE = true } },
            .addr = 0,
            .offset = secs.data.offset,
            .size = secs.data.size,
            .link = 0,
            .info = 0,
            .addralign = 0x8,
            .entsize = 0,
        }, .little);
    }
    if (program.flags.has_bss) {
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.bss.name,
            .type = .NOBITS,
            .flags = .{ .shf = .{ .ALLOC = true, .WRITE = true } },
            .addr = 0,
            .offset = secs.bss.offset,
            .size = secs.bss.size,
            .link = 0,
            .info = 0,
            .addralign = 0x8,
            .entsize = 0,
        }, .little);
    }
    if (secs.relatext.size > 0) {
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.relatext.name,
            .type = .RELA,
            .flags = .{ .shf = .{} },
            .addr = 0,
            .offset = secs.relatext.offset,
            .size = secs.relatext.size,
            .link = secs.symtab.ind,
            .info = secs.text.ind,
            .addralign = 0x8,
            .entsize = @sizeOf(elf.Elf64.Rela),
        }, .little);
    }
    if (utils.flags.debug) {
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.debug_line.name,
            .type = .PROGBITS,
            .flags = .{ .shf = .{} },
            .addr = 0,
            .offset = secs.debug_line.offset,
            .size = secs.debug_line.size,
            .link = 0,
            .info = 0,
            .addralign = 0x1,
            .entsize = 0,
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.debug_line_str.name,
            .type = .PROGBITS,
            .flags = .{ .shf = .{ .MERGE = true, .STRINGS = true } },
            .addr = 0,
            .offset = secs.debug_line_str.offset,
            .size = secs.debug_line_str.size,
            .link = 0,
            .info = 0,
            .addralign = 0x1,
            .entsize = 0x1,
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.reladebug_line.name,
            .type = .RELA,
            .flags = .{ .shf = .{} },
            .addr = 0,
            .offset = secs.reladebug_line.offset,
            .size = secs.reladebug_line.size,
            .link = secs.symtab.ind,
            .info = secs.debug_line.ind,
            .addralign = 0x1,
            .entsize = @sizeOf(elf.Elf64.Rela),
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.debug_info.name,
            .type = .PROGBITS,
            .flags = .{ .shf = .{} },
            .addr = 0,
            .offset = secs.debug_info.offset,
            .size = secs.debug_info.size,
            .link = 0,
            .info = 0,
            .addralign = 0x1,
            .entsize = 0,
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.debug_abbrev.name,
            .type = .PROGBITS,
            .flags = .{ .shf = .{} },
            .addr = 0,
            .offset = secs.debug_abbrev.offset,
            .size = secs.debug_abbrev.size,
            .link = 0,
            .info = 0,
            .addralign = 0x1,
            .entsize = 0,
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.debug_str.name,
            .type = .PROGBITS,
            .flags = .{ .shf = .{ .MERGE = true, .STRINGS = true } },
            .addr = 0,
            .offset = secs.debug_str.offset,
            .size = secs.debug_str.size,
            .link = 0,
            .info = 0,
            .addralign = 0x1,
            .entsize = 0x1,
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.reladebug_info.name,
            .type = .RELA,
            .flags = .{ .shf = .{} },
            .addr = 0,
            .offset = secs.reladebug_info.offset,
            .size = secs.reladebug_info.size,
            .link = secs.symtab.ind,
            .info = secs.debug_info.ind,
            .addralign = 0x1,
            .entsize = @sizeOf(elf.Elf64.Rela),
        }, .little);
    }
    try writer.writeStruct(elf.Elf64.Shdr{
        .name = secs.symtab.name,
        .type = .SYMTAB,
        .flags = .{ .shf = .{} },
        .addr = 0,
        .offset = secs.symtab.offset,
        .size = secs.symtab.size,
        .link = secs.strtab.ind,
        .info = self.symtab_info,
        .addralign = 0x1,
        .entsize = @sizeOf(elf.Elf64.Sym),
    }, .little);
    try writer.writeStruct(elf.Elf64.Shdr{
        .name = secs.strtab.name,
        .type = .STRTAB,
        .flags = .{ .shf = .{ .STRINGS = true } },
        .addr = 0,
        .offset = secs.strtab.offset,
        .size = secs.strtab.size,
        .link = 0,
        .info = 0,
        .addralign = 0x1,
        .entsize = 0,
    }, .little);
    try writer.writeStruct(elf.Elf64.Shdr{
        .name = secs.shstrtab.name,
        .type = .STRTAB,
        .flags = .{ .shf = .{ .STRINGS = true } },
        .addr = 0,
        .offset = secs.shstrtab.offset,
        .size = secs.shstrtab.size,
        .link = 0,
        .info = 0,
        .addralign = 0x1,
        .entsize = 0,
    }, .little);

    try writer.flush();
}

pub fn deinit(self: *ObjFileElf) void {
    self.buffs.deinit(utils.alloc);
    utils.alloc.destroy(self.buffs);
    utils.alloc.destroy(self.sections);
}
