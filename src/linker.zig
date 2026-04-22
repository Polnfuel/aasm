const std = @import("std");
const assembler = @import("assembler");
const stdbuffers = @import("stdbuffers");

const elf = std.elf;

pub const LinkerError = error{LinkingFailed} || std.mem.Allocator.Error || std.Io.Writer.Error || std.fs.File.OpenError || std.fs.File.ChmodError;

const Executable = struct {
    ehdr: elf.Elf64_Ehdr,
    text: std.ArrayList(u8),
    data: std.ArrayList(u8),
    text_addr: usize,
    code_addr: usize,
    data_addr: usize,
    buf_count: usize,
    entry_addr: usize,

    pub fn new() Executable {
        return Executable{
            .ehdr = undefined,
            .text = .empty,
            .data = .empty,
            .text_addr = 0,
            .code_addr = 0,
            .data_addr = 0,
            .buf_count = 0,
            .entry_addr = 0,
        };
    }

    pub fn addNoOps(self: *Executable, bytes: usize, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        var i: usize = bytes;
        while (i >= 9) : (i -= 9) {
            try self.text.appendSlice(allocator, &.{ 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 });
        }
        switch (i) {
            1 => {
                try self.text.append(allocator, 0x90);
            },
            2 => {
                try self.text.appendSlice(allocator, &.{ 0x66, 0x90 });
            },
            3 => {
                try self.text.appendSlice(allocator, &.{ 0x0F, 0x1F, 0x00 });
            },
            4 => {
                try self.text.appendSlice(allocator, &.{ 0x0F, 0x1F, 0x40, 0x00 });
            },
            5 => {
                try self.text.appendSlice(allocator, &.{ 0x0F, 0x1F, 0x44, 0x00, 0x00 });
            },
            6 => {
                try self.text.appendSlice(allocator, &.{ 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 });
            },
            7 => {
                try self.text.appendSlice(allocator, &.{ 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 });
            },
            8 => {
                try self.text.appendSlice(allocator, &.{ 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 });
            },
            else => {},
        }
    }

    pub fn tillNextAlignedAddress(current: u64, alignment: u64) u64 {
        const aligned = (current + alignment - 1) & ~(alignment - 1);
        return aligned - current;
    }

    pub fn deinit(self: *Executable, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.data.deinit(allocator);
    }
};

const FiNoSecNo = struct {
    file_no: u32,
    section_no: u32,
};

const HMContext = struct {
    pub fn hash(self: *const HMContext, key: FiNoSecNo) u64 {
        _ = self;
        return (key.file_no * 2 + key.section_no);
    }
    pub fn eql(self: *const HMContext, first: FiNoSecNo, second: FiNoSecNo) bool {
        _ = self;
        if (first.file_no == second.file_no and first.section_no == second.section_no) {
            return true;
        }
        return false;
    }
};

const LinkerSymbol = struct {
    glob_address: usize,
    glob_shndx: u16,
    strip: bool,
};

pub const Linker = struct {
    entry: ?[]u8,
    allocator: std.mem.Allocator,
    exe: Executable,
    assems: []assembler.Assembler,
    output_name: []const u8,
    locals: std.StringHashMap(LinkerSymbol),
    globals: std.StringHashMap(LinkerSymbol),
    offsets: std.HashMap(FiNoSecNo, usize, HMContext, 80),

    strip: bool,
    g: bool,

    pub fn new(allocator: std.mem.Allocator, assems: []assembler.Assembler, output: []const u8, strip: bool, debug_info: bool) Linker {
        return Linker{
            .entry = null,
            .allocator = allocator,
            .exe = Executable.new(),
            .assems = assems,
            .output_name = output,
            .locals = std.StringHashMap(LinkerSymbol).init(allocator),
            .globals = std.StringHashMap(LinkerSymbol).init(allocator),
            .offsets = std.HashMap(FiNoSecNo, usize, HMContext, 80).init(allocator),
            .strip = strip,
            .g = debug_info,
        };
    }

    fn printBuffers(self: *Linker) void {
        std.debug.print("Global text buffer ({d})\n", .{self.exe.text.items.len});
        for (self.exe.text.items) |byte| {
            std.debug.print("{x:02}", .{byte});
        }
        std.debug.print("\n\n", .{});
        std.debug.print("Global data buffer ({d})\n", .{self.exe.data.items.len});
        for (self.exe.data.items) |byte| {
            std.debug.print("{x:02}", .{byte});
        }
        std.debug.print("\n\n", .{});
    }

    fn printOffsets(self: *Linker) void {
        std.debug.print("Global sections offsets mapping\n", .{});
        var iter = self.offsets.iterator();
        while (iter.next()) |entry| {
            const filename = self.assems[entry.key_ptr.file_no].program.file_name;
            const sec_name = if (entry.key_ptr.section_no == 1) ".text" else ".data";
            std.debug.print("{s}: {s} - {d}\n", .{ filename, sec_name, entry.value_ptr.* });
        }
        std.debug.print("\n", .{});
    }

    fn printLocals(self: *const Linker) void {
        std.debug.print("Local symbols\n", .{});
        var iter = self.locals.iterator();
        while (iter.next()) |entry| {
            std.debug.print("{s:<15} {x:0>16} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.glob_address, entry.value_ptr.glob_shndx });
        }
        std.debug.print("\n", .{});
    }

    fn printGlobals(self: *const Linker) void {
        std.debug.print("Global symbols\n", .{});
        var iter = self.globals.iterator();
        while (iter.next()) |entry| {
            std.debug.print("{s:<15} {x:0>16} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.glob_address, entry.value_ptr.glob_shndx });
        }
        std.debug.print("\n", .{});
    }

    fn patchTextRelocation(self: *Linker, offset: usize, value: u64, comptime bytes: u8) void {
        // std.debug.print("{d}: {d}\n", .{ offset, value });
        self.exe.text.items[offset] = @truncate(value);
        if (bytes > 1) {
            self.exe.text.items[offset + 1] = @truncate(value >> 8);
        }
        if (bytes > 2) {
            self.exe.text.items[offset + 2] = @truncate(value >> 16);
            self.exe.text.items[offset + 3] = @truncate(value >> 24);
        }
        if (bytes > 4) {
            self.exe.text.items[offset + 4] = @truncate(value >> 32);
            self.exe.text.items[offset + 5] = @truncate(value >> 40);
            self.exe.text.items[offset + 6] = @truncate(value >> 48);
            self.exe.text.items[offset + 7] = @truncate(value >> 56);
        }
    }

    pub fn linkExe(self: *Linker) LinkerError!void {
        // First pass - determine entry and segments count
        var with_text = false;
        var with_data = false;
        for (self.assems) |*assem| {
            if (assem.objfile.text_section) |_| {
                with_text = true;
            }
            if (assem.objfile.data_section) |_| {
                with_data = true;
            }
            if (assem.program.entry) |entry| {
                if (self.entry == null) {
                    self.entry = entry;
                } else {
                    stdbuffers.printErrorFormatted("multiple definition of '{s}' entry", .{entry});
                    return LinkerError.LinkingFailed;
                }
            }
        }
        if (self.entry == null) {
            stdbuffers.printError("none of source files contains entry point declaration");
            return LinkerError.LinkingFailed;
        }
        if (!with_text) {
            stdbuffers.printError("none of source files contains executable code section");
            return LinkerError.LinkingFailed;
        }

        const buffers_count: usize = if (with_data) 2 else 1;
        self.exe.code_addr = 0x400000 + @sizeOf(elf.Elf64_Ehdr) + buffers_count * @sizeOf(elf.Elf64_Phdr);
        // std.debug.print("code address: {x}\n\n", .{self.exe.code_addr});
        self.exe.buf_count = buffers_count;

        // Second pass - merge buffers
        for (self.assems, 0..) |*assem, i| {
            if (assem.objfile.code_buffer) |cb| {
                const padding = Executable.tillNextAlignedAddress(self.exe.code_addr + self.exe.text.items.len, 8);
                try self.exe.addNoOps(padding, self.allocator);

                const offset = self.exe.text.items.len;
                try self.offsets.putNoClobber(.{ .file_no = @truncate(i), .section_no = 1 }, offset);
                try self.exe.text.appendSlice(self.allocator, cb.items);
            }
            if (assem.objfile.data_buffer) |db| {
                const offset = self.exe.data.items.len;
                try self.offsets.putNoClobber(.{ .file_no = @truncate(i), .section_no = 2 }, offset);
                try self.exe.data.appendSlice(self.allocator, db.items);
            }
        }

        const d_padding = Executable.tillNextAlignedAddress(self.exe.code_addr + self.exe.text.items.len, 0x1000);
        const data_address: usize = self.exe.code_addr + self.exe.text.items.len + d_padding;

        self.exe.text_addr = 0x400000;
        self.exe.data_addr = data_address;

        // self.printBuffers();
        // self.printOffsets();

        // Third pass - iterate over all LOCAL symbols

        for (self.assems, 0..) |*assem, i| {
            if (assem.flags.symbols) {
                for (assem.objfile.symtab.items) |symbol| {
                    if (symbol.st_bind() == elf.STB_LOCAL) {
                        const sym_shndx: u16 = switch (symbol.st_type()) {
                            elf.STT_FUNC => 1,
                            elf.STT_OBJECT => 2,
                            else => continue,
                        };
                        const sh_offset = self.offsets.get(.{ .file_no = @truncate(i), .section_no = symbol.st_shndx }) orelse unreachable;
                        const sh_address = switch (sym_shndx) {
                            1 => self.exe.code_addr,
                            2 => self.exe.data_addr,
                            else => unreachable,
                        };
                        const sym_address = sh_address + sh_offset + symbol.st_value;
                        const sym_name: []const u8 = std.mem.sliceTo(assem.objfile.strtab.items[symbol.st_name..], 0);
                        try self.locals.putNoClobber(sym_name, LinkerSymbol{
                            .glob_address = sym_address,
                            .glob_shndx = sym_shndx,
                            .strip = if (@as(elf.STV, @enumFromInt(symbol.st_other)) == elf.STV.HIDDEN) true else false,
                        });
                    }
                }
            }
        }

        // self.printLocals();

        // Fourth pass - iterate over all defined GLOBAL symbols

        for (self.assems, 0..) |*assem, i| {
            if (assem.flags.symbols) {
                for (assem.objfile.symtab.items) |symbol| {
                    if (symbol.st_bind() == elf.STB_GLOBAL and symbol.st_shndx != elf.SHN_UNDEF) {
                        const sym_shndx: u16 = switch (symbol.st_type()) {
                            elf.STT_FUNC => 1,
                            elf.STT_OBJECT => 2,
                            else => continue,
                        };
                        const shift: u8 = if (!assem.flags.text) 1 else 0;
                        const sh_offset = self.offsets.get(.{ .file_no = @truncate(i), .section_no = symbol.st_shndx + shift }) orelse unreachable;
                        const sh_address = switch (sym_shndx) {
                            1 => self.exe.code_addr,
                            2 => self.exe.data_addr,
                            else => unreachable,
                        };
                        const sym_address = sh_address + sh_offset + symbol.st_value;
                        const sym_name: []const u8 = std.mem.sliceTo(assem.objfile.strtab.items[symbol.st_name..], 0);
                        try self.globals.putNoClobber(sym_name, LinkerSymbol{
                            .glob_address = sym_address,
                            .glob_shndx = sym_shndx,
                            .strip = false,
                        });

                        if (std.mem.eql(u8, sym_name, self.entry.?)) {
                            self.exe.entry_addr = sym_address;
                        }
                    }
                }
            }
        }

        // self.printGlobals();

        // Fifth pass - check if all undefined symbols defined elsewhere in other objects
        for (self.assems) |*assem| {
            if (assem.flags.symbols) {
                for (assem.objfile.symtab.items[1..]) |symbol| {
                    if (symbol.st_shndx == elf.SHN_UNDEF) {
                        const sym_name: []const u8 = std.mem.sliceTo(assem.objfile.strtab.items[symbol.st_name..], 0);
                        const defined = self.globals.contains(sym_name);
                        if (!defined) {
                            stdbuffers.printSourceErrorFormatted(assem.program.file_name, "unable to resolve symbol '{s}'", .{sym_name}, assem.program.content, 1);
                            return LinkerError.LinkingFailed;
                        }
                    }
                }
            }
        }

        // Sixth pass - apply all relocations
        for (self.assems, 0..) |*assem, i| {
            if (assem.flags.relocations) {
                for (assem.objfile.relatab.items) |rela| {
                    const sym_idx = rela.r_sym();
                    const symbol = assem.objfile.symtab.items[sym_idx];
                    const sym_name: []const u8 = std.mem.sliceTo(assem.objfile.strtab.items[symbol.st_name..], 0);

                    const lnk_symbol = if (self.locals.get(sym_name)) |sym| sym else self.globals.get(sym_name);
                    if (lnk_symbol) |l_sym| {
                        const S = l_sym.glob_address;
                        const A = rela.r_addend;
                        const rtype: elf.R_X86_64 = @enumFromInt(rela.r_type());
                        const shn_offset = self.offsets.get(.{ .file_no = @truncate(i), .section_no = 1 }) orelse unreachable;
                        const text_offset = shn_offset + rela.r_offset;
                        const reloc_address = self.exe.code_addr + text_offset;

                        switch (rtype) {
                            .@"64" => {
                                const r_value: u64 = @bitCast(@as(i64, @bitCast(S)) +% A);
                                // std.debug.print("  64: {s:<15} {x:0>16}\n", .{ sym_name, r_value });
                                self.patchTextRelocation(text_offset, r_value, 8);
                            },
                            .PC32 => {
                                const r_value: i32 = @truncate(@as(i64, @bitCast(S -% reloc_address)) + A);
                                // std.debug.print("PC32: {s:<15} {x:0>16}\n", .{ sym_name, r_value });
                                self.patchTextRelocation(text_offset, @as(u32, @bitCast(r_value)), 4);
                            },
                            .@"32" => {
                                const r_value: u32 = @truncate(@as(u64, @bitCast(@as(i64, @bitCast(S)) +% A)));
                                // std.debug.print("  32: {s:<15} {x:0>16}\n", .{ sym_name, r_value });
                                self.patchTextRelocation(text_offset, r_value, 4);
                            },
                            else => {
                                stdbuffers.printError("unsupported relocation type");
                                return LinkerError.LinkingFailed;
                            },
                        }
                    } else {
                        stdbuffers.printSourceErrorFormatted(assem.program.file_name, "unable to resolve symbol '{s}'", .{sym_name}, assem.program.content, 1);
                        return LinkerError.LinkingFailed;
                    }
                }
            }
        }

        // self.printBuffers();

        try self.writeExe();
    }

    fn writeElf64_Ehdr(writer: *std.io.Writer, ehdr: *const elf.Elf64_Ehdr) std.Io.Writer.Error!void {
        try writer.writeStruct(ehdr.*, .little);
    }
    fn writeElf64_Phdr(writer: *std.io.Writer, ehdr: *const elf.Elf64_Phdr) std.Io.Writer.Error!void {
        try writer.writeStruct(ehdr.*, .little);
    }
    fn writeElf64_Shdr(writer: *std.io.Writer, shdr: *const elf.Elf64_Shdr) std.Io.Writer.Error!void {
        try writer.writeStruct(shdr.*, .little);
    }

    fn writeExe(self: *Linker) LinkerError!void {
        // Program headers
        self.exe.ehdr = elf.Elf64_Ehdr{
            .e_ident = [_]u8{ elf.MAGIC[0], elf.MAGIC[1], elf.MAGIC[2], elf.MAGIC[3], elf.ELFCLASS64, elf.ELFDATA2LSB, 1, @intFromEnum(elf.OSABI.GNU), 0, 0, 0, 0, 0, 0, 0, 0 },
            .e_type = elf.ET.EXEC,
            .e_machine = elf.EM.X86_64,
            .e_version = 1,
            .e_entry = self.exe.entry_addr,
            .e_phoff = 64,
            .e_shoff = 0,
            .e_flags = 0,
            .e_ehsize = 64,
            .e_phentsize = 56,
            .e_phnum = @truncate(self.exe.buf_count),
            .e_shentsize = 0,
            .e_shnum = 0,
            .e_shstrndx = elf.SHN_UNDEF,
        };
        const text_phdr = elf.Elf64_Phdr{
            .p_type = elf.PT_LOAD,
            .p_offset = 0,
            .p_vaddr = self.exe.text_addr,
            .p_paddr = self.exe.text_addr,
            .p_filesz = @sizeOf(elf.Elf64_Ehdr) + self.exe.buf_count * @sizeOf(elf.Elf64_Phdr) + self.exe.text.items.len,
            .p_memsz = @sizeOf(elf.Elf64_Ehdr) + self.exe.buf_count * @sizeOf(elf.Elf64_Phdr) + self.exe.text.items.len,
            .p_flags = elf.PF_R + elf.PF_X,
            .p_align = 0x1000,
        };
        const padding = Executable.tillNextAlignedAddress(text_phdr.p_filesz, 0x1000);
        const data_phdr = elf.Elf64_Phdr{
            .p_type = elf.PT_LOAD,
            .p_offset = text_phdr.p_filesz + padding,
            .p_vaddr = self.exe.data_addr,
            .p_paddr = self.exe.data_addr,
            .p_filesz = self.exe.data.items.len,
            .p_memsz = self.exe.data.items.len,
            .p_flags = elf.PF_R + elf.PF_W,
            .p_align = 0x1000,
        };

        // Section headers
        const sections_offset = text_phdr.p_filesz + if (self.exe.buf_count > 1) data_phdr.p_filesz + padding else 0;

        var shstrtab_buffer: std.ArrayList(u8) = .empty;
        defer shstrtab_buffer.deinit(self.allocator);
        try shstrtab_buffer.append(self.allocator, 0);

        var strtab_buffer: std.ArrayList(u8) = .empty;
        defer strtab_buffer.deinit(self.allocator);
        try strtab_buffer.append(self.allocator, 0);

        var symtab_buffer: std.ArrayList(elf.Elf64_Sym) = .empty;
        defer symtab_buffer.deinit(self.allocator);
        try symtab_buffer.append(self.allocator, .{ .st_name = 0, .st_value = 0, .st_size = 0, .st_info = 0, .st_other = 0, .st_shndx = elf.SHN_UNDEF });

        var shstrtab = elf.Elf64_Shdr{
            .sh_name = 1,
            .sh_type = elf.SHT_STRTAB,
            .sh_flags = elf.SHF_STRINGS,
            .sh_addr = 0,
            .sh_offset = sections_offset,
            .sh_size = undefined,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 1,
            .sh_entsize = 0,
        };
        try shstrtab_buffer.appendSlice(self.allocator, ".shstrtab");
        try shstrtab_buffer.append(self.allocator, 0);

        var strtab = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_STRTAB,
            .sh_flags = elf.SHF_STRINGS,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 1,
            .sh_entsize = 0,
        };
        try shstrtab_buffer.appendSlice(self.allocator, ".strtab");
        try shstrtab_buffer.append(self.allocator, 0);

        var symtab = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_SYMTAB,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = @truncate(2 + self.exe.buf_count),
            .sh_info = undefined,
            .sh_addralign = 1,
            .sh_entsize = @sizeOf(elf.Elf64_Sym),
        };
        try shstrtab_buffer.appendSlice(self.allocator, ".symtab");
        try shstrtab_buffer.append(self.allocator, 0);

        var l_iter = self.locals.iterator();
        var g_iter = self.globals.iterator();
        while (l_iter.next()) |sym| {
            if (!sym.value_ptr.strip) {
                const sym_name = strtab_buffer.items.len;
                try strtab_buffer.appendSlice(self.allocator, sym.key_ptr.*);
                try strtab_buffer.append(self.allocator, 0);

                const sym_type: u8 = if (sym.value_ptr.glob_shndx == 1) elf.STT_FUNC else elf.STT_OBJECT;

                const symbol = elf.Elf64_Sym{
                    .st_name = @truncate(sym_name),
                    .st_value = sym.value_ptr.glob_address,
                    .st_size = 0,
                    .st_info = (elf.STB_LOCAL << 4) + (sym_type & 0xF),
                    .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                    .st_shndx = sym.value_ptr.glob_shndx,
                };
                try symtab_buffer.append(self.allocator, symbol);
            }
        }
        symtab.sh_info = @truncate(symtab_buffer.items.len);
        while (g_iter.next()) |sym| {
            const sym_name = strtab_buffer.items.len;
            try strtab_buffer.appendSlice(self.allocator, sym.key_ptr.*);
            try strtab_buffer.append(self.allocator, 0);

            const sym_type: u8 = if (sym.value_ptr.glob_shndx == 1) elf.STT_FUNC else elf.STT_OBJECT;

            const symbol = elf.Elf64_Sym{
                .st_name = @truncate(sym_name),
                .st_value = sym.value_ptr.glob_address,
                .st_size = 0,
                .st_info = (elf.STB_GLOBAL << 4) + (sym_type & 0xF),
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_shndx = sym.value_ptr.glob_shndx,
            };
            try symtab_buffer.append(self.allocator, symbol);
        }

        const txt_sec = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = elf.SHF_ALLOC + elf.SHF_EXECINSTR,
            .sh_addr = self.exe.code_addr,
            .sh_offset = @sizeOf(elf.Elf64_Ehdr) + self.exe.buf_count * @sizeOf(elf.Elf64_Phdr),
            .sh_size = text_phdr.p_filesz - (@sizeOf(elf.Elf64_Ehdr) + self.exe.buf_count * @sizeOf(elf.Elf64_Phdr)),
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 8,
            .sh_entsize = 0,
        };
        try shstrtab_buffer.appendSlice(self.allocator, ".text");
        try shstrtab_buffer.append(self.allocator, 0);

        const dat_sec = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = elf.SHF_ALLOC + elf.SHF_WRITE,
            .sh_addr = self.exe.data_addr,
            .sh_offset = data_phdr.p_offset,
            .sh_size = data_phdr.p_filesz,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 8,
            .sh_entsize = 0,
        };
        try shstrtab_buffer.appendSlice(self.allocator, ".data");
        try shstrtab_buffer.append(self.allocator, 0);

        var debug_str_buffer: std.ArrayList(u8) = .empty;
        defer debug_str_buffer.deinit(self.allocator);

        var debug_line_str_buffer: std.ArrayList(u8) = .empty;
        defer debug_line_str_buffer.deinit(self.allocator);

        var dbg_info_size: usize = 0;
        var dbg_line_size: usize = 0;

        if (self.g) {
            var text_addresses = try std.ArrayList(u64).initCapacity(self.allocator, self.offsets.count());
            defer text_addresses.deinit(self.allocator);
            _ = text_addresses.addManyAsSliceAssumeCapacity(self.offsets.count());
            var offsets_iter = self.offsets.iterator();
            while (offsets_iter.next()) |entry| {
                if (entry.key_ptr.section_no == 1) {
                    const address = self.exe.code_addr + entry.value_ptr.*;
                    text_addresses.items[entry.key_ptr.file_no] = address;
                }
            }

            var str_map = std.StringHashMap(usize).init(self.allocator);
            defer str_map.deinit();

            var line_str_map = std.StringHashMap(usize).init(self.allocator);
            defer line_str_map.deinit();

            var str_start: usize = 0;
            var line_str_start: usize = 0;
            for (self.assems) |*assem| {
                var str_start_local: usize = 0;
                const str_buf = assem.program.debug_info.debug_str_buffer.items;
                while (str_start_local < str_buf.len) {
                    const str_null_term_slice: []u8 = std.mem.sliceTo(str_buf[str_start_local..], 0);

                    const result = try str_map.getOrPut(str_null_term_slice);
                    if (!result.found_existing) {
                        result.value_ptr.* = str_start;
                        try debug_str_buffer.appendSlice(self.allocator, str_null_term_slice);
                        try debug_str_buffer.append(self.allocator, 0);
                        str_start = debug_str_buffer.items.len;
                    }

                    str_start_local += str_null_term_slice.len + 1;
                }
                var line_str_start_local: usize = 0;
                const line_str_buf = assem.program.debug_info.debug_line_str_buffer.items;
                while (line_str_start_local < line_str_buf.len) {
                    const str_null_term_slice: []u8 = std.mem.sliceTo(line_str_buf[line_str_start_local..], 0);

                    const result = try line_str_map.getOrPut(str_null_term_slice);
                    if (!result.found_existing) {
                        result.value_ptr.* = line_str_start;
                        try debug_line_str_buffer.appendSlice(self.allocator, str_null_term_slice);
                        try debug_line_str_buffer.append(self.allocator, 0);
                        line_str_start = debug_line_str_buffer.items.len;
                    }

                    line_str_start_local += str_null_term_slice.len + 1;
                }
            }

            var dbg_line_offsets: std.ArrayList(u32) = .empty;
            defer dbg_line_offsets.deinit(self.allocator);

            // Patch Debug line relocations
            var dbg_line_start: u32 = 0;
            for (self.assems, 0..) |*assem, i| {
                try dbg_line_offsets.append(self.allocator, dbg_line_start);
                const debug_line = assem.program.debug_info.debug_line_buffer.items;
                dbg_line_start += @truncate(debug_line.len);
                dbg_line_size += debug_line.len;
                const symbols = assem.objfile.symtab.items;
                const strs = assem.objfile.strtab.items;
                for (assem.program.debug_info.debug_line_rela_buffer.items) |rela| {
                    const sym_index = rela.r_sym();
                    const symbol = symbols[sym_index];
                    const str_ind = symbol.st_name;
                    const sym_name: []u8 = std.mem.sliceTo(strs[str_ind..], 0);
                    if (std.mem.eql(u8, sym_name, ".debug_line_str")) {
                        const str_offset: u32 = @intCast(rela.r_addend);
                        const str_name: []u8 = std.mem.sliceTo(assem.program.debug_info.debug_line_str_buffer.items[str_offset..], 0);
                        const glob_line_str_offset = line_str_map.get(str_name) orelse unreachable;
                        std.mem.writeInt(u32, @ptrCast(debug_line[rela.r_offset..]), @truncate(glob_line_str_offset), .little);
                    } else if (std.mem.eql(u8, sym_name, ".text")) {
                        std.mem.writeInt(u64, @ptrCast(debug_line[rela.r_offset..]), text_addresses.items[i], .little);
                    }
                }
            }

            // Patch Debug info relocations
            for (self.assems, 0..) |*assem, i| {
                const debug_info = assem.program.debug_info.debug_info_buffer.items;
                dbg_info_size += debug_info.len;
                const symbols = assem.objfile.symtab.items;
                const strs = assem.objfile.strtab.items;
                for (assem.program.debug_info.debug_info_rela_buffer.items) |rela| {
                    const sym_index = rela.r_sym();
                    const symbol = symbols[sym_index];
                    const str_ind = symbol.st_name;
                    const sym_name: []u8 = std.mem.sliceTo(strs[str_ind..], 0);
                    if (std.mem.eql(u8, sym_name, ".debug_str")) {
                        const str_offset: u32 = @intCast(rela.r_addend);
                        const str_name: []u8 = std.mem.sliceTo(assem.program.debug_info.debug_str_buffer.items[str_offset..], 0);
                        const glob_line_str_offset = str_map.get(str_name) orelse unreachable;
                        std.mem.writeInt(u32, @ptrCast(debug_info[rela.r_offset..]), @truncate(glob_line_str_offset), .little);
                    } else if (std.mem.eql(u8, sym_name, ".debug_line")) {
                        const index = dbg_line_offsets.items[i];
                        std.mem.writeInt(u32, @ptrCast(debug_info[rela.r_offset..]), index, .little);
                    } else if (std.mem.eql(u8, sym_name, ".text")) {
                        std.mem.writeInt(u64, @ptrCast(debug_info[rela.r_offset..]), text_addresses.items[i], .little);
                    }
                }
            }
        }

        var debug_info_sec = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = dbg_info_size,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0x1,
            .sh_entsize = 0,
        };
        if (self.g) {
            try shstrtab_buffer.appendSlice(self.allocator, ".debug_info");
            try shstrtab_buffer.append(self.allocator, 0);
        }
        var debug_line_sec = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = dbg_line_size,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0x1,
            .sh_entsize = 0,
        };
        if (self.g) {
            try shstrtab_buffer.appendSlice(self.allocator, ".debug_line");
            try shstrtab_buffer.append(self.allocator, 0);
        }
        var debug_abbrev_sec = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = 0,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = self.assems[0].program.debug_info.debug_abbrev_buffer.items.len,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0x1,
            .sh_entsize = 0,
        };
        if (self.g) {
            try shstrtab_buffer.appendSlice(self.allocator, ".debug_abbrev");
            try shstrtab_buffer.append(self.allocator, 0);
        }
        var debug_str_sec = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = elf.SHF_MERGE + elf.SHF_STRINGS,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = debug_str_buffer.items.len,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0x1,
            .sh_entsize = 0x1,
        };
        if (self.g) {
            try shstrtab_buffer.appendSlice(self.allocator, ".debug_str");
            try shstrtab_buffer.append(self.allocator, 0);
        }
        var debug_line_str_sec = elf.Elf64_Shdr{
            .sh_name = @truncate(shstrtab_buffer.items.len),
            .sh_type = elf.SHT_PROGBITS,
            .sh_flags = elf.SHF_MERGE + elf.SHF_STRINGS,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = debug_line_str_buffer.items.len,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0x1,
            .sh_entsize = 0x1,
        };
        if (self.g) {
            try shstrtab_buffer.appendSlice(self.allocator, ".debug_line_str");
            try shstrtab_buffer.append(self.allocator, 0);
        }

        shstrtab.sh_size = @truncate(shstrtab_buffer.items.len);
        strtab.sh_size = @truncate(strtab_buffer.items.len);
        symtab.sh_size = @truncate(symtab_buffer.items.len * @sizeOf(elf.Elf64_Sym));
        strtab.sh_offset = shstrtab.sh_offset + shstrtab.sh_size;
        symtab.sh_offset = strtab.sh_offset + strtab.sh_size;
        if (self.g) {
            debug_info_sec.sh_offset = symtab.sh_offset + symtab.sh_size;
            debug_line_sec.sh_offset = debug_info_sec.sh_offset + debug_info_sec.sh_size;
            debug_abbrev_sec.sh_offset = debug_line_sec.sh_offset + debug_line_sec.sh_size;
            debug_str_sec.sh_offset = debug_abbrev_sec.sh_offset + debug_abbrev_sec.sh_size;
            debug_line_str_sec.sh_offset = debug_str_sec.sh_offset + debug_str_sec.sh_size;
        }

        if (!self.strip) {
            if (self.g) {
                self.exe.ehdr.e_shnum = @truncate(9 + self.exe.buf_count);
                self.exe.ehdr.e_shoff = debug_line_str_sec.sh_offset + debug_line_str_sec.sh_size;
            } else {
                self.exe.ehdr.e_shnum = @truncate(4 + self.exe.buf_count);
                self.exe.ehdr.e_shoff = symtab.sh_offset + symtab.sh_size;
            }
            self.exe.ehdr.e_shstrndx = @truncate(1 + self.exe.buf_count);
            self.exe.ehdr.e_shentsize = 64;
        }

        var file_size: u64 = 0;
        if (!self.strip) {
            if (self.g) {
                file_size = self.exe.ehdr.e_shoff + (9 + self.exe.buf_count) * @sizeOf(elf.Elf64_Shdr);
            } else {
                file_size = self.exe.ehdr.e_shoff + (4 + self.exe.buf_count) * @sizeOf(elf.Elf64_Shdr);
            }
        } else {
            file_size = data_phdr.p_offset + data_phdr.p_filesz;
        }

        const file_buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(file_buffer);

        const cwd = std.fs.cwd();

        const file = try cwd.createFile(self.output_name, .{});
        try file.chmod(0o755);
        defer file.close();

        var file_writer = file.writer(file_buffer);
        const writer = &file_writer.interface;

        try writeElf64_Ehdr(writer, &self.exe.ehdr);
        try writeElf64_Phdr(writer, &text_phdr);
        if (self.exe.buf_count > 1) {
            try writeElf64_Phdr(writer, &data_phdr);
        }
        _ = try writer.write(self.exe.text.items);
        if (self.exe.buf_count > 1) {
            _ = try writer.splatByte(0, padding);
            _ = try writer.write(self.exe.data.items);
        }

        if (!self.strip) {
            _ = try writer.write(shstrtab_buffer.items);
            _ = try writer.write(strtab_buffer.items);
            for (symtab_buffer.items) |sym| {
                try writer.writeStruct(sym, .little);
            }

            if (self.g) {
                for (self.assems) |*assem| {
                    _ = try writer.write(assem.program.debug_info.debug_info_buffer.items);
                }
                for (self.assems) |*assem| {
                    _ = try writer.write(assem.program.debug_info.debug_line_buffer.items);
                }
                _ = try writer.write(self.assems[0].program.debug_info.debug_abbrev_buffer.items);
                _ = try writer.write(debug_str_buffer.items);
                _ = try writer.write(debug_line_str_buffer.items);
            }

            try writeElf64_Shdr(writer, &elf.Elf64_Shdr{
                .sh_name = 0,
                .sh_type = elf.SHT_NULL,
                .sh_addr = 0,
                .sh_addralign = 0,
                .sh_entsize = 0,
                .sh_flags = 0,
                .sh_info = 0,
                .sh_link = 0,
                .sh_offset = 0,
                .sh_size = 0,
            });
            try writeElf64_Shdr(writer, &txt_sec);
            if (self.exe.buf_count > 1) {
                try writeElf64_Shdr(writer, &dat_sec);
            }
            try writeElf64_Shdr(writer, &shstrtab);
            try writeElf64_Shdr(writer, &strtab);
            try writeElf64_Shdr(writer, &symtab);

            if (self.g) {
                try writeElf64_Shdr(writer, &debug_info_sec);
                try writeElf64_Shdr(writer, &debug_line_sec);
                try writeElf64_Shdr(writer, &debug_abbrev_sec);
                try writeElf64_Shdr(writer, &debug_str_sec);
                try writeElf64_Shdr(writer, &debug_line_str_sec);
            }
        }

        try writer.flush();
    }

    pub fn deinit(self: *Linker) void {
        self.exe.deinit(self.allocator);
        self.locals.deinit();
        self.globals.deinit();
        self.offsets.deinit();
    }
};
