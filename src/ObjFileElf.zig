const std = @import("std");
const elf = std.elf;
const dwarf = std.dwarf;

const Program = @import("Program");

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
        ind: u8,
        name: u32,
        offset: u64,
        size: usize,

        const empty = Section{
            .ind = 0,
            .name = 0,
            .offset = 0,
            .size = 0,
        };
    };

    text: Section = .empty,
    data: Section = .empty,
    relatext: Section = .empty,
    debug_line: Section = .empty,
    debug_line_str: Section = .empty,
    reladebug_line: Section = .empty,
    debug_info: Section = .empty,
    debug_abbrev: Section = .empty,
    debug_str: Section = .empty,
    reladebug_info: Section = .empty,
    symtab: Section = .empty,
    strtab: Section = .empty,
    shstrtab: Section = .empty,

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

txt_sym: u32,
dbg_ln_sym: u32,
dbg_ln_str_sym: u32,
dbg_str_sym: u32,

symtab_info: u32,

pub fn init(self: *ObjFileElf, alloc: std.mem.Allocator) std.mem.Allocator.Error!void {
    self.buffs = try alloc.create(Buffers);
    self.buffs.* = Buffers{};
    self.sections = try alloc.create(Sections);
    self.sections.* = Sections{};

    try self.buffs.symtab.append(alloc, .{ .name = 0, .value = 0, .size = 0, .info = .{ .type = .NOTYPE, .bind = .LOCAL }, .other = .{ .visibility = .DEFAULT }, .shndx = elf.SHN_UNDEF });
    try self.buffs.strtab.append(alloc, 0);
    try self.buffs.shstrtab.append(alloc, 0);

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

fn appendName(self: *ObjFileElf, alloc: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!u32 {
    const prev_len = self.buffs.strtab.items.len;
    try self.buffs.strtab.appendSlice(alloc, name);
    try self.buffs.strtab.append(alloc, 0);
    return @truncate(prev_len);
}

fn appendSectionSymbol(self: *ObjFileElf, alloc: std.mem.Allocator, name: []const u8, shndx: u16) std.mem.Allocator.Error!void {
    try self.buffs.symtab.append(alloc, .{
        .name = try self.appendName(alloc, name),
        .value = 0,
        .info = .{ .type = .SECTION, .bind = .LOCAL },
        .shndx = shndx,
        .other = .{ .visibility = .DEFAULT },
        .size = 0,
    });
}

fn appendSectionName(self: *ObjFileElf, alloc: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!u32 {
    const prev_len = self.buffs.shstrtab.items.len;
    try self.buffs.shstrtab.appendSlice(alloc, name);
    try self.buffs.shstrtab.append(alloc, 0);
    return @truncate(prev_len);
}

fn addSymbolsToSymtab(self: *ObjFileElf, program: *Program) std.mem.Allocator.Error!void {
    const buffs = self.buffs;
    const secs = self.sections;

    var symbols_map: std.StringHashMap(u32) = .init(program.alloc);
    defer symbols_map.deinit();

    var funcs = program.funcs.iterator();
    while (funcs.next()) |sym| {
        if (sym.value_ptr.visib == .Local) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(program.alloc, sym.key_ptr.*),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .LOCAL, .type = .FUNC },
                .other = .{ .visibility = .DEFAULT },
                .shndx = secs.text.ind,
            };

            try symbols_map.put(sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(program.alloc, symbol);
        }
    }

    var data_vars = program.data_vars.iterator();
    while (data_vars.next()) |sym| {
        if (sym.value_ptr.visib == .Local) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(program.alloc, sym.key_ptr.*),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .LOCAL, .type = .OBJECT },
                .other = .{ .visibility = .DEFAULT },
                .shndx = secs.data.ind,
            };

            if (program.flags.debug) {
                try self.addVariableDebugInfo(program, sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            }
            try symbols_map.put(sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(program.alloc, symbol);
        }
    }

    self.symtab_info = @truncate(buffs.symtab.items.len);

    funcs = program.funcs.iterator();
    while (funcs.next()) |sym| {
        if (sym.value_ptr.visib == .Export) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(program.alloc, sym.key_ptr.*),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .GLOBAL, .type = .FUNC },
                .other = .{ .visibility = .DEFAULT },
                .shndx = secs.text.ind,
            };

            try symbols_map.put(sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(program.alloc, symbol);
        }
    }

    data_vars = program.data_vars.iterator();
    while (data_vars.next()) |sym| {
        if (sym.value_ptr.visib == .Export) {
            const symbol = elf.Elf64.Sym{
                .name = try self.appendName(program.alloc, sym.key_ptr.*),
                .value = sym.value_ptr.offset,
                .size = sym.value_ptr.size,
                .info = .{ .bind = .GLOBAL, .type = .OBJECT },
                .other = .{ .visibility = .DEFAULT },
                .shndx = secs.data.ind,
            };

            if (program.flags.debug) {
                try self.addVariableDebugInfo(program, sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            }
            try symbols_map.put(sym.key_ptr.*, @truncate(buffs.symtab.items.len));
            try buffs.symtab.append(program.alloc, symbol);
        }
    }

    var lib_imports: std.StringHashMap(void) = .init(program.alloc);
    defer lib_imports.deinit();

    var imports = program.imports.iterator();
    while (imports.next()) |sym| {
        if (sym.value_ptr.* > 0) {
            try lib_imports.put(sym.key_ptr.*, {});
        }

        const symbol = elf.Elf64.Sym{
            .name = try self.appendName(program.alloc, sym.key_ptr.*),
            .value = 0,
            .size = 0,
            .info = .{ .bind = .GLOBAL, .type = .NOTYPE },
            .other = .{ .visibility = .DEFAULT },
            .shndx = elf.SHN_UNDEF,
        };

        try symbols_map.put(sym.key_ptr.*, @truncate(buffs.symtab.items.len));
        try buffs.symtab.append(program.alloc, symbol);
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
        try buffs.relatext.append(program.alloc, rela);
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

fn patchDebugInfoHeader(self: *ObjFileElf, program: *Program) std.mem.Allocator.Error!void {
    try self.buffs.debug_info.append(program.alloc, 0);

    const unit_length = self.buffs.debug_info.items.len - 4;
    std.mem.writeInt(u32, self.buffs.debug_info.items[0..4], @truncate(unit_length), .little);
}

fn addVariableDebugInfo(self: *ObjFileElf, program: *Program, name: []const u8, sym_ind: u32) std.mem.Allocator.Error!void {
    const name_offset: u32 = @truncate(self.buffs.debug_str.items.len);
    try self.buffs.debug_str.appendSlice(program.alloc, name);
    try self.buffs.debug_str.append(program.alloc, 0);

    const die_offset: u32 = @truncate(self.buffs.debug_info.items.len);
    try self.buffs.debug_info.appendSlice(program.alloc, &.{
        0x02, 0,             0, 0, 0,
        0x09, dwarf.OP.addr, 0, 0, 0,
        0,    0,             0, 0, 0,
    });

    try self.buffs.reladebug_info.append(program.alloc, .{
        .offset = die_offset + 1,
        .info = .{ .sym = self.dbg_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = name_offset,
    });
    try self.buffs.reladebug_info.append(program.alloc, .{
        .offset = die_offset + 7,
        .info = .{ .sym = sym_ind, .type = @intFromEnum(elf.R_X86_64.@"64") },
        .addend = 0,
    });
}

fn genDwarfDebugInformation(self: *ObjFileElf, program: *Program, cwd_path: []const u8, rel_path: []const u8) std.mem.Allocator.Error!void {
    const buffs = self.buffs;

    // Names for line number program
    const dir_path = std.fs.path.dirname(rel_path);
    const dir_cnt: u8 = if (dir_path != null) 2 else 1;
    try buffs.debug_line_str.appendSlice(program.alloc, cwd_path);
    try buffs.debug_line_str.append(program.alloc, 0);
    const dir1_ind: u32 = @truncate(buffs.debug_line_str.items.len);
    if (dir_cnt > 1) {
        try buffs.debug_line_str.appendSlice(program.alloc, dir_path.?);
        try buffs.debug_line_str.append(program.alloc, 0);
    }
    const filename_ind: u32 = @truncate(buffs.debug_line_str.items.len);
    try buffs.debug_line_str.appendSlice(program.alloc, program.file_name);
    try buffs.debug_line_str.append(program.alloc, 0);

    // Line number program header and file/directories entries
    try buffs.debug_line.appendSlice(program.alloc, &.{
        0,    0,    0,    0,    0x5,  0x0,
        0x8,  0x0,  0,    0,    0,    0,
        0x01, 0x01, 0x01, 0xfb, 0x0e, 0x0d,
        0,    1,    1,    1,    1,    0,
        0,    0,    1,    0,    0,    1,
    });

    try buffs.debug_line.appendSlice(program.alloc, &.{
        0x01, 0x01, 0x1f, dir_cnt,
    });

    const dirs_start = buffs.debug_line.items.len;
    for (0..dir_cnt) |_| {
        try buffs.debug_line.appendSlice(program.alloc, &.{ 0, 0, 0, 0 });
    }

    try buffs.debug_line.appendSlice(program.alloc, &.{
        0x02, 0x01, 0x1f, 0x02, 0x0f, 0x02,
    });
    const files_start = buffs.debug_line.items.len;
    for (0..2) |_| {
        try buffs.debug_line.appendSlice(program.alloc, &.{
            0, 0, 0, 0, dir_cnt - 1,
        });
    }
    buffs.debug_line.items[8] = @truncate(buffs.debug_line.items.len - 12);

    // Start of Line Number Program
    try buffs.debug_line.appendSlice(program.alloc, &.{
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
            try buffs.debug_line.append(program.alloc, opcode);
        } else {
            try buffs.debug_line.appendSlice(program.alloc, &.{
                dwarf.LNS.advance_pc, address_increment,
            });
            try buffs.debug_line.appendSlice(program.alloc, &.{
                dwarf.LNS.advance_line, line_increment,
            });
            try buffs.debug_line.append(program.alloc, dwarf.LNS.copy);
        }
        line += line_increment;
        address += address_increment;
    }
    const last_addr_inc: u8 = @truncate(program.line_program.items[program.line_program.items.len - 1].offset - address);
    try buffs.debug_line.appendSlice(program.alloc, &.{
        dwarf.LNS.advance_pc,  last_addr_inc,
        dwarf.LNS.extended_op, dwarf.LNE.end_sequence,
        dwarf.LNS.copy,
    });
    // End of Line Number Program

    // debug_line relocations
    try buffs.reladebug_line.append(program.alloc, .{
        .offset = dirs_start,
        .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });
    if (dir_cnt > 1) {
        try buffs.reladebug_line.append(program.alloc, .{
            .offset = dirs_start + 4,
            .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
            .addend = dir1_ind,
        });
    }
    try buffs.reladebug_line.append(program.alloc, .{
        .offset = files_start,
        .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = filename_ind,
    });
    try buffs.reladebug_line.append(program.alloc, .{
        .offset = files_start + 5,
        .info = .{ .sym = self.dbg_ln_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = filename_ind,
    });
    try buffs.reladebug_line.append(program.alloc, .{
        .offset = text_reloc_offset,
        .info = .{ .sym = self.txt_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });

    const unit_length = buffs.debug_line.items.len - 4;
    std.mem.writeInt(u32, buffs.debug_line.items[0..4], @truncate(unit_length), .little);

    // Names for compile_unit abbrev
    try buffs.debug_str.appendSlice(program.alloc, rel_path);
    try buffs.debug_str.append(program.alloc, 0);
    const dir_ind: u32 = @truncate(buffs.debug_str.items.len);
    try buffs.debug_str.appendSlice(program.alloc, cwd_path);
    try buffs.debug_str.append(program.alloc, 0);

    // DW_TAG_compile_unit abbrev
    try buffs.debug_abbrev.appendSlice(program.alloc, &.{
        0x1,                dwarf.TAG.compile_unit, dwarf.CHILDREN.yes,
        dwarf.AT.stmt_list, dwarf.FORM.sec_offset,  dwarf.AT.low_pc,
        dwarf.FORM.addr,    dwarf.AT.high_pc,       dwarf.FORM.udata,
        dwarf.AT.name,      dwarf.FORM.strp,        dwarf.AT.comp_dir,
        dwarf.FORM.strp,    0x00,                   0x00,
    });

    // DW_TAG_variable
    try buffs.debug_abbrev.appendSlice(program.alloc, &.{
        0x2,                dwarf.TAG.variable, dwarf.CHILDREN.no,
        dwarf.AT.name,      dwarf.FORM.strp,    dwarf.AT.location,
        dwarf.FORM.exprloc, 0x00,               0x00,
    });

    try buffs.debug_abbrev.append(program.alloc, 0);

    // DIE for compile_unit
    try buffs.debug_info.appendSlice(program.alloc, &.{
        0,    0,   0,                0,
        0x05, 0x0, dwarf.UT.compile, 0x08,
        0,    0,   0,                0,
        0x01, 0,   0,                0,
        0,    0,   0,                0,
        0,    0,   0,                0,
        0,
    });
    try writeUleb128(&buffs.debug_info, program.alloc, program.code_block.buffer.items.len);
    const name_offset = buffs.debug_info.items.len;
    try buffs.debug_info.appendSlice(program.alloc, &.{
        0, 0, 0, 0,
        0, 0, 0, 0,
    });

    // debug_info compile_unit relocations
    try buffs.reladebug_info.append(program.alloc, .{
        .offset = 13,
        .info = .{ .sym = self.dbg_ln_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });
    try buffs.reladebug_info.append(program.alloc, .{
        .offset = 17,
        .info = .{ .sym = self.txt_sym, .type = @intFromEnum(elf.R_X86_64.@"64") },
        .addend = 0,
    });
    try buffs.reladebug_info.append(program.alloc, .{
        .offset = name_offset,
        .info = .{ .sym = self.dbg_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = 0,
    });
    try buffs.reladebug_info.append(program.alloc, .{
        .offset = name_offset + 4,
        .info = .{ .sym = self.dbg_str_sym, .type = @intFromEnum(elf.R_X86_64.@"32") },
        .addend = dir_ind,
    });
}

pub fn compileProgram(self: *ObjFileElf, program: *Program, cwd_path: []const u8, rel_path: []const u8) ObjectError!void {
    const buffs = self.buffs;
    const secs = self.sections;

    secs.text.offset = std.mem.alignForward(usize, @sizeOf(elf.Elf64.Ehdr), 0x8);
    if (program.flags.has_code) {
        buffs.text = program.code_block.buffer;
        secs.text.ind = 1;
        secs.text.name = try self.appendSectionName(program.alloc, ".text");
        secs.text.size = buffs.text.items.len;
        self.txt_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(program.alloc, ".text", secs.text.ind);
    }
    secs.data.ind = secs.text.ind;
    secs.data.offset = std.mem.alignForward(usize, secs.text.offset + secs.text.size, 0x8);
    if (program.flags.has_data) {
        buffs.data = program.data_block.buffer;
        secs.data.ind += 1;
        secs.data.name = try self.appendSectionName(program.alloc, ".data");
        secs.data.size = buffs.data.items.len;
        try self.appendSectionSymbol(program.alloc, ".data", secs.data.ind);
    }
    secs.relatext.ind = secs.data.ind;
    if (program.relocations.items.len > 0) {
        secs.relatext.ind += 1;
        secs.relatext.name = try self.appendSectionName(program.alloc, ".rela.text");
        secs.relatext.offset = std.mem.alignForward(usize, secs.data.offset + secs.data.size, 0x8);
        secs.relatext.size = program.relocations.items.len * @sizeOf(elf.Elf64.Rela);
    } else {
        secs.relatext.offset = secs.data.offset + secs.data.size;
    }
    if (program.flags.debug) {
        secs.debug_line.ind = secs.relatext.ind + 1;
        secs.debug_line_str.ind = secs.debug_line.ind + 1;
        secs.reladebug_line.ind = secs.debug_line_str.ind + 1;
        secs.debug_info.ind = secs.reladebug_line.ind + 1;
        secs.debug_abbrev.ind = secs.debug_info.ind + 1;
        secs.debug_str.ind = secs.debug_abbrev.ind + 1;
        secs.reladebug_info.ind = secs.debug_str.ind + 1;

        secs.debug_line.name = try self.appendSectionName(program.alloc, ".debug_line");
        self.dbg_ln_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(program.alloc, ".debug_line", secs.debug_line.ind);
        secs.debug_line_str.name = try self.appendSectionName(program.alloc, ".debug_line_str");
        self.dbg_ln_str_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(program.alloc, ".debug_line_str", secs.debug_line_str.ind);
        secs.reladebug_line.name = try self.appendSectionName(program.alloc, ".rela.debug_line");
        secs.debug_info.name = try self.appendSectionName(program.alloc, ".debug_info");
        try self.appendSectionSymbol(program.alloc, ".debug_info", secs.debug_info.ind);
        secs.debug_abbrev.name = try self.appendSectionName(program.alloc, ".debug_abbrev");
        secs.debug_str.name = try self.appendSectionName(program.alloc, ".debug_str");
        self.dbg_str_sym = @truncate(buffs.symtab.items.len);
        try self.appendSectionSymbol(program.alloc, ".debug_str", secs.debug_str.ind);
        secs.reladebug_info.name = try self.appendSectionName(program.alloc, ".rela.debug_info");

        try self.genDwarfDebugInformation(program, cwd_path, rel_path);
    } else {
        secs.reladebug_info.ind = secs.relatext.ind;
        secs.reladebug_info.offset = secs.relatext.offset + secs.relatext.size;
    }
    secs.symtab.ind = secs.reladebug_info.ind + 1;
    secs.symtab.name = try self.appendSectionName(program.alloc, ".symtab");

    try self.addSymbolsToSymtab(program);
    if (program.flags.debug) {
        try self.patchDebugInfoHeader(program);
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

    secs.strtab.ind = secs.symtab.ind + 1;
    secs.strtab.name = try self.appendSectionName(program.alloc, ".strtab");
    secs.strtab.offset = secs.symtab.offset + secs.symtab.size;
    secs.strtab.size = buffs.strtab.items.len;

    secs.shstrtab.ind = secs.strtab.ind + 1;
    secs.shstrtab.name = try self.appendSectionName(program.alloc, ".shstrtab");
    secs.shstrtab.offset = secs.strtab.offset + secs.strtab.size;
    secs.shstrtab.size = buffs.shstrtab.items.len;

    if (!program.flags.quiet) {
        secs.print();
        self.printStrtab();
        self.printSymtab();
    }
}

pub fn writeObjFile(self: *ObjFileElf, io: std.Io, program: *Program) ObjectError!void {
    const buffs = self.buffs;
    const secs = self.sections;

    const shtable = std.mem.alignForward(usize, secs.shstrtab.offset + secs.shstrtab.size, 0x8);
    const file_size = shtable + @as(usize, (secs.shstrtab.ind + 1)) * @sizeOf(elf.Elf64.Shdr);
    std.debug.print("shtable: {x}, filesize: {x}\n", .{ shtable, file_size });

    const file_buffer = try program.alloc.alloc(u8, file_size);
    defer program.alloc.free(file_buffer);

    const file_name_ext = try std.mem.concat(program.alloc, u8, &.{ std.fs.path.stem(program.file_name), @ptrCast(".o") });
    defer program.alloc.free(file_name_ext);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, file_name_ext, .{});
    defer file.close(io);

    var file_writer = file.writer(io, file_buffer);
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
    std.debug.print("writer.end c: {x}\n", .{writer.end});
    if (program.flags.has_data) {
        padding = secs.data.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.data.items);
    }
    std.debug.print("writer.end d: {x}\n", .{writer.end});
    if (secs.relatext.size > 0) {
        padding = secs.relatext.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        for (buffs.relatext.items) |rela| {
            try writer.writeStruct(rela, .little);
        }
    }
    std.debug.print("writer.end rt: {x}\n", .{writer.end});
    if (program.flags.debug) {
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
    std.debug.print("writer.end db: {x}\n", .{writer.end});
    for (buffs.symtab.items) |sym| {
        try writer.writeStruct(sym, .little);
    }
    std.debug.print("writer.end sy: {x}\n", .{writer.end});
    _ = try writer.write(buffs.strtab.items);
    std.debug.print("writer.end st: {x}\n", .{writer.end});
    _ = try writer.write(buffs.shstrtab.items);
    std.debug.print("writer.end sh: {x}\n", .{writer.end});

    std.debug.print("shtable: {x}, writer.end: {x}\n", .{ shtable, writer.end });
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
    if (program.flags.debug) {
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

pub fn deinit(self: *ObjFileElf, alloc: std.mem.Allocator) void {
    self.buffs.deinit(alloc);
}
