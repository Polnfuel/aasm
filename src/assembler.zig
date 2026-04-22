const std = @import("std");
const LexerError = @import("lexer").LexerError;
const ParserError = @import("parser").ParserError;
const program = @import("program");
const Program = program.Program;
const stdbuffers = @import("stdbuffers");

const elf = std.elf;
const dwarf = std.dwarf;

pub const LoadFileError = error{SourceFileTooBig} || std.fs.Dir.RealPathAllocError || std.fs.File.OpenError || std.fs.File.StatError || std.mem.Allocator.Error || std.Io.Reader.Error;

pub const ObjectError = error{ObjectError} || std.Io.Writer.Error || std.mem.Allocator.Error || std.fs.File.OpenError;

pub const AssemblerError = LexerError || ParserError || program.BufferGenError || program.ProgramError || ObjectError;

pub const ObjFile = struct {
    elf_header: elf.Elf64_Ehdr,
    text_section: ?elf.Elf64_Shdr,
    data_section: ?elf.Elf64_Shdr,
    code_buffer: ?std.ArrayList(u8),
    data_buffer: ?std.ArrayList(u8),
    shnstrtab: std.ArrayList(u8),
    strtab: std.ArrayList(u8),
    symtab: std.ArrayList(elf.Elf64_Sym),
    relatab: std.ArrayList(elf.Elf64_Rela),
    shnstrtab_section: elf.Elf64_Shdr,
    strtab_section: ?elf.Elf64_Shdr,
    symtab_section: ?elf.Elf64_Shdr,
    relatab_section: ?elf.Elf64_Shdr,
    section_count: usize,

    pub fn new() ObjFile {
        return ObjFile{
            .elf_header = undefined,
            .text_section = null,
            .data_section = null,
            .code_buffer = null,
            .data_buffer = null,
            .shnstrtab = .empty,
            .strtab = .empty,
            .symtab = .empty,
            .relatab = .empty,
            .shnstrtab_section = undefined,
            .strtab_section = null,
            .symtab_section = null,
            .relatab_section = null,
            .section_count = 0,
        };
    }

    pub fn deinit(self: *ObjFile, allocator: std.mem.Allocator) void {
        self.shnstrtab.deinit(allocator);
        self.strtab.deinit(allocator);
        self.symtab.deinit(allocator);
        self.relatab.deinit(allocator);
    }

    pub fn printStrTabSymTab(self: ObjFile) void {
        std.debug.print(" Section Names Table \n ", .{});
        for (self.shnstrtab.items) |str| {
            std.debug.print("{c}", .{if (str > 0) str else ' '});
        }
        std.debug.print("\n", .{});

        std.debug.print(" Strings Table \n ", .{});
        for (self.strtab.items) |str| {
            std.debug.print("{c}", .{if (str > 0) str else ' '});
        }
        std.debug.print("\n", .{});

        std.debug.print(" Symbols Table \n", .{});
        std.debug.print("{s:>6}: {s:^16} {s:>5} {s:<7} {s:<6} {s:<7} {s:>4} \n", .{ "Num", "Value", "Size", "Type", "Link", "Vis", "Ind" });
        for (self.symtab.items, 0..) |symbol, i| {
            const sym_name: [*:0]u8 = @ptrCast(self.strtab.items[symbol.st_name..]);
            const t = switch (symbol.st_type()) {
                0 => "NOTYPE",
                1 => "OBJECT",
                2 => "FUNC",
                3 => "SECTION",
                4 => "FILE",
                5 => "COMMON",
                else => "",
            };
            const l = switch (symbol.st_bind()) {
                0 => "LOCAL",
                1 => "GLOBAL",
                2 => "WEAK",
                else => "",
            };
            const v = switch (symbol.st_other) {
                0 => "DEFAULT",
                1 => "INTERNAL",
                2 => "HIDDEN",
                3 => "PROTECTED",
                else => "",
            };
            std.debug.print("{d:>6}: {x:0>16} {d:>5} {s:<7} {s:<6} {s:<7} {d:>4} {s:<}\n", .{ i, symbol.st_value, symbol.st_size, t, l, v, symbol.st_shndx, sym_name });
        }

        std.debug.print(" Relocations Table \n", .{});
        std.debug.print("{s:^12}  {s:^12} {s:^16} {s:^16} {s:<} \n", .{ "Offset", "Info", "Type", "Value", "Name + Addend" });
        for (self.relatab.items) |rela| {
            const sym_name: [*:0]u8 = @ptrCast(self.strtab.items[self.symtab.items[rela.r_sym()].st_name..]);
            const t = switch (rela.r_type()) {
                1 => "R_X86_64_64",
                2 => "R_X86_64_PC32",
                else => "",
            };
            std.debug.print("{x:0>12}  {x:0>12} {s:<17} {x:0>16} {s:<} {s} {d} \n", .{
                rela.r_offset,
                rela.r_info,
                t,
                self.symtab.items[rela.r_sym()].st_value,
                sym_name,
                if (rela.r_addend < 0) "-" else "+",
                @abs(rela.r_addend),
            });
        }
        std.debug.print("\n", .{});
    }
};

const AsmFlags = packed struct {
    text: bool,
    data: bool,
    symbols: bool,
    relocations: bool,
    debug_info: bool,

    pub fn new() AsmFlags {
        return AsmFlags{
            .text = false,
            .data = false,
            .symbols = false,
            .relocations = false,
            .debug_info = false,
        };
    }
};

pub const Assembler = struct {
    rel_path: []const u8,
    output_file: []const u8,
    allocator: std.mem.Allocator,
    program: program.Program,
    objfile: ObjFile,

    flags: AsmFlags,
    file_size: usize,

    fn loadFromFile(self: *Assembler, input_file: []const u8) LoadFileError![]const u8 {
        const file = try std.fs.openFileAbsolute(input_file, .{ .mode = .read_only });
        defer file.close();

        const file_stat = try file.stat();
        const file_size = file_stat.size;

        if (file_size > std.math.pow(u64, 2, 20)) {
            return LoadFileError.SourceFileTooBig;
        }

        var content = try self.allocator.alloc(u8, file_size + 1);
        errdefer self.allocator.free(content);

        var file_reader = file.reader(content);
        var reader = &file_reader.interface;
        try reader.readSliceAll(content[0..file_size]);
        content[file_size] = '\n';

        return content;
    }

    pub fn new(rel_path: []const u8, allocator: std.mem.Allocator, gen_debug: bool) LoadFileError!Assembler {
        var assembler = Assembler{
            .rel_path = undefined,
            .output_file = undefined,
            .allocator = allocator,
            .program = undefined,
            .objfile = ObjFile.new(),
            .flags = AsmFlags.new(),
            .file_size = 0,
        };
        assembler.flags.debug_info = gen_debug;
        assembler.rel_path = try assembler.allocator.dupe(u8, rel_path);

        const output_name = std.fs.path.stem(assembler.rel_path);
        assembler.output_file = try assembler.allocator.dupe(u8, output_name);

        const input_abs_path = try std.fs.cwd().realpathAlloc(assembler.allocator, rel_path);
        defer assembler.allocator.free(input_abs_path);

        const content = try assembler.loadFromFile(input_abs_path);
        assembler.program = try Program.new(std.fs.path.basename(input_abs_path), content, assembler.allocator, gen_debug);
        if (assembler.flags.debug_info) {
            assembler.program.debug_info.dir_path = std.fs.path.dirname(rel_path);
        }
        return assembler;
    }

    fn defineObjFileTables(self: *Assembler) ObjectError!void {
        var symbol_indices = std.StringHashMap(u32).init(self.allocator);
        defer symbol_indices.deinit();

        try self.objfile.symtab.append(self.allocator, .{ .st_name = 0, .st_value = 0, .st_size = 0, .st_info = 0, .st_other = 0, .st_shndx = elf.SHN_UNDEF });
        var symtab_size: u32 = 1;

        try self.objfile.strtab.append(self.allocator, 0);
        var strtab_size: u32 = 1;

        try self.objfile.shnstrtab.append(self.allocator, 0);
        var shnstrtab_size: u32 = 1;

        self.objfile.shnstrtab_section = elf.Elf64_Shdr{
            .sh_name = undefined,
            .sh_type = elf.SHT_STRTAB,
            .sh_flags = elf.SHF_STRINGS,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0x1,
            .sh_entsize = 0,
        };

        const code_section_ind: u8 = 1;
        const data_section_ind: u8 = if (self.program.code_block != null) 2 else 1;
        self.objfile.section_count = data_section_ind + 2;

        var str_start = strtab_size;

        str_start = strtab_size;
        if (self.program.code_block) |*code_block| {
            self.objfile.code_buffer = code_block.buffer;
            self.objfile.text_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = elf.SHF_ALLOC + elf.SHF_EXECINSTR,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = self.objfile.code_buffer.?.items.len * @sizeOf(u8),
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x8,
                .sh_entsize = 0,
            };
            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".text"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            try self.objfile.strtab.appendSlice(self.allocator, @ptrCast(".text"));
            try self.objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(self.objfile.strtab.items.len);

            try self.objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = code_section_ind,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });

            if (self.flags.debug_info) {
                self.program.debug_info.text_symbol_ind = symtab_size;
            }

            symtab_size += 1;
        } else {
            self.flags.debug_info = false;
        }

        str_start = strtab_size;
        if (self.program.data_block) |*data_block| {
            self.objfile.data_buffer = data_block.buffer;
            self.objfile.data_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = elf.SHF_ALLOC + elf.SHF_WRITE,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = self.objfile.data_buffer.?.items.len * @sizeOf(u8),
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x8,
                .sh_entsize = 0,
            };
            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".data"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            try self.objfile.strtab.appendSlice(self.allocator, @ptrCast(".data"));
            try self.objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(self.objfile.strtab.items.len);

            try self.objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = data_section_ind,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            symtab_size += 1;
        }

        if (self.flags.debug_info) {
            self.program.debug_info.dbline_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = 0,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x1,
                .sh_entsize = 0,
            };
            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".debug_line"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            str_start = strtab_size;
            try self.objfile.strtab.appendSlice(self.allocator, @ptrCast(".debug_line"));
            try self.objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(self.objfile.strtab.items.len);

            try self.objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = undefined,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            self.program.debug_info.debug_line_ind = symtab_size;
            symtab_size += 1;

            self.program.debug_info.dblinestr_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = elf.SHF_MERGE + elf.SHF_STRINGS,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = 0,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x1,
                .sh_entsize = 0x1,
            };

            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".debug_line_str"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            str_start = strtab_size;
            try self.objfile.strtab.appendSlice(self.allocator, @ptrCast(".debug_line_str"));
            try self.objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(self.objfile.strtab.items.len);

            try self.objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = undefined,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            self.program.debug_info.debug_line_str_ind = symtab_size;
            symtab_size += 1;

            self.program.debug_info.dblinerela_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_RELA,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = 0,
                .sh_link = undefined,
                .sh_info = undefined,
                .sh_addralign = 0x1,
                .sh_entsize = @sizeOf(elf.Elf64_Rela),
            };

            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".rela.debug_line"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            self.program.debug_info.dbinfo_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = 0,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x1,
                .sh_entsize = 0,
            };
            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".debug_info"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            str_start = strtab_size;
            try self.objfile.strtab.appendSlice(self.allocator, @ptrCast(".debug_info"));
            try self.objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(self.objfile.strtab.items.len);

            try self.objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = undefined,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            self.program.debug_info.debug_info_ind = symtab_size;
            symtab_size += 1;

            self.program.debug_info.dbabbrev_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = 0,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x1,
                .sh_entsize = 0,
            };
            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".debug_abbrev"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            str_start = strtab_size;
            try self.objfile.strtab.appendSlice(self.allocator, @ptrCast(".debug_abbrev"));
            try self.objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(self.objfile.strtab.items.len);

            try self.objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = undefined,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            self.program.debug_info.debug_abbrev_ind = symtab_size;
            symtab_size += 1;

            self.program.debug_info.dbstr_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = elf.SHF_MERGE + elf.SHF_STRINGS,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = 0,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x1,
                .sh_entsize = 0x1,
            };

            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".debug_str"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            str_start = strtab_size;
            try self.objfile.strtab.appendSlice(self.allocator, @ptrCast(".debug_str"));
            try self.objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(self.objfile.strtab.items.len);

            try self.objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = undefined,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            self.program.debug_info.debug_str_ind = symtab_size;
            symtab_size += 1;

            self.program.debug_info.dbinforela_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_RELA,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = 0,
                .sh_link = undefined,
                .sh_info = undefined,
                .sh_addralign = 0x1,
                .sh_entsize = @sizeOf(elf.Elf64_Rela),
            };

            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".rela.debug_info"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            self.objfile.section_count += 7;
        }

        // First append all LOCAL symbols
        var sym_iter = self.program.symbols.iterator();
        while (sym_iter.next()) |sym| {
            if (sym.value_ptr.type == .Local or sym.value_ptr.type == .Hidden) {
                str_start = strtab_size;
                try self.objfile.strtab.appendSlice(self.allocator, sym.key_ptr.*);
                try self.objfile.strtab.append(self.allocator, 0);
                strtab_size = @truncate(self.objfile.strtab.items.len);

                var sym_type: u8 = undefined;
                var sym_shndx: u16 = undefined;
                switch (sym.value_ptr.section) {
                    .Code => {
                        sym_type = elf.STT_FUNC;
                        sym_shndx = code_section_ind;
                    },
                    .Data => {
                        sym_type = elf.STT_OBJECT;
                        sym_shndx = data_section_ind;
                    },
                    .Undef => unreachable,
                }

                const visib = if (sym.value_ptr.type == .Local) elf.STV.DEFAULT else elf.STV.HIDDEN;

                const symbol = elf.Elf64_Sym{
                    .st_name = str_start,
                    .st_value = sym.value_ptr.offset,
                    .st_size = 0,
                    .st_info = (elf.STB_LOCAL << 4) + (sym_type & 0xF),
                    .st_other = @intFromEnum(visib) & 0x3,
                    .st_shndx = sym_shndx,
                };

                try self.objfile.symtab.append(self.allocator, symbol);
                try symbol_indices.put(sym.key_ptr.*, symtab_size);
                symtab_size += 1;
            }
        }

        const first_global = self.objfile.symtab.items.len;

        // Second append all GLOBAL symbols
        sym_iter = self.program.symbols.iterator();
        while (sym_iter.next()) |sym| {
            if (sym.value_ptr.type == .Export or sym.value_ptr.type == .Import) {
                str_start = strtab_size;
                try self.objfile.strtab.appendSlice(self.allocator, sym.key_ptr.*);
                try self.objfile.strtab.append(self.allocator, 0);
                strtab_size = @truncate(self.objfile.strtab.items.len);

                var sym_type: u8 = undefined;
                var sym_shndx: u16 = undefined;
                switch (sym.value_ptr.section) {
                    .Code => {
                        sym_type = elf.STT_FUNC;
                        sym_shndx = code_section_ind;
                    },
                    .Data => {
                        sym_type = elf.STT_OBJECT;
                        sym_shndx = data_section_ind;
                    },
                    .Undef => {
                        sym_type = elf.STT_NOTYPE;
                        sym_shndx = elf.SHN_UNDEF;
                    },
                }

                const symbol = elf.Elf64_Sym{
                    .st_name = str_start,
                    .st_value = sym.value_ptr.offset,
                    .st_size = 0,
                    .st_info = (elf.STB_GLOBAL << 4) + (sym_type & 0xF),
                    .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                    .st_shndx = sym_shndx,
                };

                try self.objfile.symtab.append(self.allocator, symbol);
                try symbol_indices.put(sym.key_ptr.*, symtab_size);
                symtab_size += 1;
            }
        }

        str_start = strtab_size;
        if (self.program.code_block) |*code_block| {
            for (code_block.relocations.items) |relocation| {
                var sym_ind: u32 = 0;
                if (symbol_indices.get(relocation.name)) |index| {
                    sym_ind = index;
                } else {
                    stdbuffers.printErrorFormatted("symbol '{s}' not found", .{relocation.name});
                    return ObjectError.ObjectError;
                }
                const rel_type: elf.R_X86_64 = switch (relocation.type) {
                    .Abs64D => .@"64",
                    .Abs32D => .@"32",
                    .Rel32C => .PC32,
                    .Rel32D => .PC32,
                };
                const rela = elf.Elf64_Rela{
                    .r_offset = relocation.offset,
                    .r_info = (@as(u64, sym_ind) << 32) + (@intFromEnum(rel_type) & 0xFFFFFFFF),
                    .r_addend = relocation.addend,
                };

                try self.objfile.relatab.append(self.allocator, rela);
            }
        }

        if (self.objfile.symtab.items.len > 1) {
            self.objfile.strtab_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_STRTAB,
                .sh_flags = elf.SHF_STRINGS,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = self.objfile.strtab.items.len * @sizeOf(u8),
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 1,
                .sh_entsize = 0,
            };

            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".strtab"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            self.objfile.symtab_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_SYMTAB,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = self.objfile.symtab.items.len * @sizeOf(elf.Elf64_Sym),
                .sh_link = undefined,
                .sh_info = @truncate(first_global),
                .sh_addralign = 1,
                .sh_entsize = @sizeOf(elf.Elf64_Sym),
            };

            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".symtab"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            self.objfile.section_count += 2;
        }

        if (self.objfile.relatab.items.len > 0) {
            self.objfile.relatab_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_RELA,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = self.objfile.relatab.items.len * @sizeOf(elf.Elf64_Rela),
                .sh_link = undefined,
                .sh_info = undefined,
                .sh_addralign = 1,
                .sh_entsize = @sizeOf(elf.Elf64_Rela),
            };

            try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".rela.text"));
            try self.objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

            self.objfile.section_count += 1;
        }

        self.objfile.shnstrtab_section.sh_name = shnstrtab_size;

        try self.objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".shstrtab"));
        try self.objfile.shnstrtab.append(self.allocator, 0);
        shnstrtab_size = @truncate(self.objfile.shnstrtab.items.len);

        self.objfile.shnstrtab_section.sh_size = shnstrtab_size;
    }

    fn writeElf64_Ehdr(writer: *std.io.Writer, ehdr: *const elf.Elf64_Ehdr) ObjectError!void {
        try writer.writeStruct(ehdr.*, .little);
    }
    fn writeElf64_Shdr(writer: *std.io.Writer, shdr: *const elf.Elf64_Shdr) ObjectError!void {
        try writer.writeStruct(shdr.*, .little);
    }
    fn writeSymbolsBuffer(writer: *std.io.Writer, symbols: []elf.Elf64_Sym) ObjectError!void {
        for (symbols) |sym| {
            try writer.writeStruct(sym, .little);
        }
    }
    fn writeRelocationsBuffer(writer: *std.io.Writer, relocations: []elf.Elf64_Rela) ObjectError!void {
        for (relocations) |rel| {
            try writer.writeStruct(rel, .little);
        }
    }

    fn defineDebugLine(self: *Assembler) std.mem.Allocator.Error!void {
        const dir_cnt: u8 = if (self.program.debug_info.dir_path != null) 2 else 1;
        try self.program.debug_info.debug_line_str_buffer.appendSlice(self.allocator, self.program.debug_info.cwd_path);
        try self.program.debug_info.debug_line_str_buffer.append(self.allocator, 0);
        const dir1_ind: u32 = @truncate(self.program.debug_info.debug_line_str_buffer.items.len);
        if (dir_cnt > 1) {
            try self.program.debug_info.debug_line_str_buffer.appendSlice(self.allocator, self.program.debug_info.dir_path.?);
            try self.program.debug_info.debug_line_str_buffer.append(self.allocator, 0);
        }
        const filename_ind: u32 = @truncate(self.program.debug_info.debug_line_str_buffer.items.len);
        try self.program.debug_info.debug_line_str_buffer.appendSlice(self.allocator, self.program.file_name);
        try self.program.debug_info.debug_line_str_buffer.append(self.allocator, 0);
        // std.debug.print("{d}, {d}, {d}\n", .{ 0, dir1_ind, filename_ind });
        self.program.debug_info.dblinestr_section.sh_size = self.program.debug_info.debug_line_str_buffer.items.len;

        try self.program.debug_info.debug_line_buffer.appendSlice(self.allocator, &.{
            0,    0,    0,    0,    0x5,  0x0,
            0x8,  0x0,  0,    0,    0,    0,
            0x01, 0x01, 0x01, 0xfb, 0x0e, 0x0d,
            0,    1,    1,    1,    1,    0,
            0,    0,    1,    0,    0,    1,
        });

        // Directories
        try self.program.debug_info.debug_line_buffer.appendSlice(self.allocator, &.{
            0x01, 0x01, 0x1f, dir_cnt,
        });

        const dirs_start = self.program.debug_info.debug_line_buffer.items.len;
        for (0..dir_cnt) |_| {
            try self.program.debug_info.debug_line_buffer.appendSlice(self.allocator, &.{ 0, 0, 0, 0 });
        }

        // Files
        try self.program.debug_info.debug_line_buffer.appendSlice(self.allocator, &.{
            0x02, 0x01, 0x1f, 0x02, 0x0f, 0x02,
        });
        const files_start = self.program.debug_info.debug_line_buffer.items.len;
        for (0..2) |_| {
            try self.program.debug_info.debug_line_buffer.appendSlice(self.allocator, &.{
                0, 0, 0, 0, dir_cnt - 1,
            });
        }
        self.program.debug_info.debug_line_buffer.items[8] = @truncate(self.program.debug_info.debug_line_buffer.items.len - 12);

        // Line Number Program
        const text_reloc = try self.program.debug_info.createLineNumberProgram(self.allocator);

        // Relocations
        // cwd:
        try self.program.debug_info.debug_line_rela_buffer.append(self.allocator, .{
            .r_offset = dirs_start,
            .r_info = (self.program.debug_info.debug_line_str_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
            .r_addend = 0,
        });
        // dir:
        if (dir_cnt > 1) {
            try self.program.debug_info.debug_line_rela_buffer.append(self.allocator, .{
                .r_offset = dirs_start + 4,
                .r_info = (self.program.debug_info.debug_line_str_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
                .r_addend = dir1_ind,
            });
        }
        // files:
        try self.program.debug_info.debug_line_rela_buffer.append(self.allocator, .{
            .r_offset = files_start,
            .r_info = (self.program.debug_info.debug_line_str_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
            .r_addend = filename_ind,
        });
        try self.program.debug_info.debug_line_rela_buffer.append(self.allocator, .{
            .r_offset = files_start + 5,
            .r_info = (self.program.debug_info.debug_line_str_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
            .r_addend = filename_ind,
        });
        // text:
        try self.program.debug_info.debug_line_rela_buffer.append(self.allocator, .{
            .r_offset = text_reloc,
            .r_info = (self.program.debug_info.text_symbol_ind << 32) + (@intFromEnum(elf.R_X86_64.@"64")),
            .r_addend = 0,
        });

        //
        const unit_length = self.program.debug_info.debug_line_buffer.items.len - 4;
        std.mem.writeInt(u32, self.program.debug_info.debug_line_buffer.items[0..4], @truncate(unit_length), .little);
        self.program.debug_info.dbline_section.sh_size = self.program.debug_info.debug_line_buffer.items.len;
        self.program.debug_info.dblinerela_section.sh_size = self.program.debug_info.debug_line_rela_buffer.items.len * self.program.debug_info.dblinerela_section.sh_entsize;
    }

    fn defineDebugInfo(self: *Assembler) std.mem.Allocator.Error!void {
        try self.program.debug_info.debug_str_buffer.appendSlice(self.allocator, self.rel_path);
        try self.program.debug_info.debug_str_buffer.append(self.allocator, 0);
        const dir_ind: u32 = @truncate(self.program.debug_info.debug_str_buffer.items.len);
        try self.program.debug_info.debug_str_buffer.appendSlice(self.allocator, self.program.debug_info.cwd_path);
        try self.program.debug_info.debug_str_buffer.append(self.allocator, 0);
        self.program.debug_info.dbstr_section.sh_size = self.program.debug_info.debug_str_buffer.items.len;

        // Debug Abbrev
        try self.program.debug_info.debug_abbrev_buffer.appendSlice(self.allocator, &.{
            0x1,                dwarf.TAG.compile_unit, dwarf.CHILDREN.no,
            dwarf.AT.stmt_list, dwarf.FORM.sec_offset,  dwarf.AT.low_pc,
            dwarf.FORM.addr,    dwarf.AT.high_pc,       dwarf.FORM.udata,
            dwarf.AT.name,      dwarf.FORM.strp,        dwarf.AT.comp_dir,
            dwarf.FORM.strp,    0x00,                   0x00,
            0x00,
        });

        // Debug Info
        try self.program.debug_info.debug_info_buffer.appendSlice(self.allocator, &.{
            0,    0,   0,                0,
            0x05, 0x0, dwarf.UT.compile, 0x08,
            0,    0,   0,                0,
            0x01, 0,   0,                0,
            0,    0,   0,                0,
            0,    0,   0,                0,
            0,
        });
        // high_pc uleb128
        try self.program.debug_info.debug_info_buffer.append(self.allocator, @truncate(self.objfile.code_buffer.?.items.len));
        const name_offset = self.program.debug_info.debug_info_buffer.items.len;
        try self.program.debug_info.debug_info_buffer.appendSlice(self.allocator, &.{
            0, 0, 0, 0,
            0, 0, 0, 0,
        });

        // Relocations

        // abbrev:
        try self.program.debug_info.debug_info_rela_buffer.append(self.allocator, .{
            .r_offset = 8,
            .r_info = (self.program.debug_info.debug_abbrev_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
            .r_addend = 0,
        });
        // debug_line:
        try self.program.debug_info.debug_info_rela_buffer.append(self.allocator, .{
            .r_offset = 13,
            .r_info = (self.program.debug_info.debug_line_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
            .r_addend = 0,
        });

        // text:
        try self.program.debug_info.debug_info_rela_buffer.append(self.allocator, .{
            .r_offset = 17,
            .r_info = (self.program.debug_info.text_symbol_ind << 32) + (@intFromEnum(elf.R_X86_64.@"64")),
            .r_addend = 0,
        });
        // name:
        try self.program.debug_info.debug_info_rela_buffer.append(self.allocator, .{
            .r_offset = name_offset,
            .r_info = (self.program.debug_info.debug_str_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
            .r_addend = 0,
        });
        // comp_dir:
        try self.program.debug_info.debug_info_rela_buffer.append(self.allocator, .{
            .r_offset = name_offset + 4,
            .r_info = (self.program.debug_info.debug_str_ind << 32) + (@intFromEnum(elf.R_X86_64.@"32")),
            .r_addend = dir_ind,
        });

        //
        const unit_length = self.program.debug_info.debug_info_buffer.items.len - 4;
        std.mem.writeInt(u32, self.program.debug_info.debug_info_buffer.items[0..4], @truncate(unit_length), .little);
        self.program.debug_info.dbinfo_section.sh_size = self.program.debug_info.debug_info_buffer.items.len;
        self.program.debug_info.dbabbrev_section.sh_size = self.program.debug_info.debug_abbrev_buffer.items.len;
        self.program.debug_info.dbinforela_section.sh_size = self.program.debug_info.debug_info_rela_buffer.items.len * self.program.debug_info.dbinforela_section.sh_entsize;
    }

    fn genObjectFile(self: *Assembler) ObjectError!void {
        try self.defineObjFileTables();
        // self.objfile.printStrTabSymTab();

        self.flags.text = if (self.objfile.text_section != null) true else false;
        self.flags.data = if (self.objfile.data_section != null) true else false;
        self.flags.symbols = if (self.objfile.symtab.items.len > 1) true else false;
        self.flags.relocations = if (self.objfile.relatab.items.len > 0) true else false;

        if (self.flags.debug_info) {
            try self.defineDebugLine();
            try self.defineDebugInfo();
            // self.program.debug_info.print();
        }

        var text_index: u16 = 0;
        if (self.flags.text) text_index += 1;
        var data_index: u16 = text_index;
        if (self.flags.data) data_index += 1;

        const shstrtab_index: u16 = data_index + 1;
        var strtab_index: u16 = shstrtab_index;
        var symtab_index: u16 = shstrtab_index;
        if (self.flags.symbols) {
            strtab_index = shstrtab_index + 1;
            symtab_index = strtab_index + 1;
        }
        var relatext_index: u16 = symtab_index;
        if (self.flags.relocations) {
            relatext_index = symtab_index + 1;
        }
        var dbg_line_index: u16 = relatext_index;
        var dbg_line_str_index: u16 = relatext_index;
        var dbg_line_rela_index: u16 = relatext_index;
        var dbg_info_index: u16 = relatext_index;
        var dbg_abbrev_index: u16 = relatext_index;
        var dbg_str_index: u16 = relatext_index;
        var dbg_info_rela_index: u16 = relatext_index;
        if (self.flags.debug_info) {
            dbg_line_index = relatext_index + 1;
            dbg_line_str_index = dbg_line_index + 1;
            dbg_line_rela_index = dbg_line_str_index + 1;
            dbg_info_index = dbg_line_rela_index + 1;
            dbg_abbrev_index = dbg_info_index + 1;
            dbg_str_index = dbg_abbrev_index + 1;
            dbg_info_rela_index = dbg_str_index + 1;

            self.objfile.symtab.items[self.program.debug_info.debug_line_ind].st_shndx = dbg_line_index;
            self.objfile.symtab.items[self.program.debug_info.debug_line_str_ind].st_shndx = dbg_line_str_index;
            self.objfile.symtab.items[self.program.debug_info.debug_info_ind].st_shndx = dbg_info_index;
            self.objfile.symtab.items[self.program.debug_info.debug_abbrev_ind].st_shndx = dbg_abbrev_index;
            self.objfile.symtab.items[self.program.debug_info.debug_str_ind].st_shndx = dbg_str_index;
        }

        self.file_size = 0;

        // Elf Header
        self.objfile.elf_header = elf.Elf64_Ehdr{
            .e_ident = [_]u8{ elf.MAGIC[0], elf.MAGIC[1], elf.MAGIC[2], elf.MAGIC[3], elf.ELFCLASS64, elf.ELFDATA2LSB, 1, @intFromEnum(elf.OSABI.GNU), 0, 0, 0, 0, 0, 0, 0, 0 },
            .e_type = elf.ET.REL,
            .e_machine = elf.EM.X86_64,
            .e_version = 1,
            .e_entry = 0,
            .e_phoff = 0,
            .e_shoff = undefined,
            .e_flags = 0,
            .e_ehsize = 64,
            .e_phentsize = 0,
            .e_phnum = 0,
            .e_shentsize = 64,
            .e_shnum = dbg_info_rela_index + 1,
            .e_shstrndx = shstrtab_index,
        };

        self.file_size += self.objfile.elf_header.e_ehsize;
        self.objfile.elf_header.e_shoff = self.file_size;

        // Section Header Table Entry 0
        self.file_size += self.objfile.elf_header.e_shentsize;

        // Section Header Table Entry 1 - .text
        if (self.flags.text) {
            self.file_size += self.objfile.elf_header.e_shentsize;
        }

        // Section Header Table Entry 2 - .data
        if (self.flags.data) {
            self.file_size += self.objfile.elf_header.e_shentsize;
        }

        // Section Header Table Entry 3 - .shstrtab
        self.file_size += self.objfile.elf_header.e_shentsize;

        // Section Header Table Entry 4-5 - .strtab and .symtab
        if (self.flags.symbols) {
            self.file_size += self.objfile.elf_header.e_shentsize;
            self.file_size += self.objfile.elf_header.e_shentsize;
        }

        // Section Header Table Entry 6 - .rela.text
        if (self.flags.relocations) {
            self.file_size += self.objfile.elf_header.e_shentsize;
        }

        // Section Header Table Entry 7-9
        // .debug_line, .debug_line_str, .rela.debug_line
        // Section Header Table Entry 10-13
        // .debug_info, .debug_abbrev, .debug_str, .rela.debug_info
        if (self.flags.debug_info) {
            self.file_size += self.objfile.elf_header.e_shentsize;
            self.file_size += self.objfile.elf_header.e_shentsize;
            self.file_size += self.objfile.elf_header.e_shentsize;
            self.file_size += self.objfile.elf_header.e_shentsize;
            self.file_size += self.objfile.elf_header.e_shentsize;
            self.file_size += self.objfile.elf_header.e_shentsize;
            self.file_size += self.objfile.elf_header.e_shentsize;
        }

        // now self.file_size is first byte after Section Header Table

        // Code buffer
        if (self.flags.text) {
            self.objfile.text_section.?.sh_offset = self.file_size;
            self.file_size += self.objfile.text_section.?.sh_size;
        }
        // Data buffer
        if (self.flags.data) {
            self.objfile.data_section.?.sh_offset = self.file_size;
            self.file_size += self.objfile.data_section.?.sh_size;
        }
        // Section Name String Table buffer
        self.objfile.shnstrtab_section.sh_offset = self.file_size;
        self.file_size += self.objfile.shnstrtab_section.sh_size;
        // String Table and Symbol Table buffers
        if (self.flags.symbols) {
            self.objfile.strtab_section.?.sh_offset = self.file_size;
            self.file_size += self.objfile.strtab_section.?.sh_size;

            self.objfile.symtab_section.?.sh_offset = self.file_size;
            self.file_size += self.objfile.symtab_section.?.sh_size;

            self.objfile.symtab_section.?.sh_link = strtab_index;
        }
        // Relocation Table buffer
        if (self.flags.relocations) {
            self.objfile.relatab_section.?.sh_offset = self.file_size;
            self.file_size += self.objfile.relatab_section.?.sh_size;

            self.objfile.relatab_section.?.sh_link = symtab_index;
            self.objfile.relatab_section.?.sh_info = text_index;
        }
        // Debug buffers
        if (self.flags.debug_info) {
            self.program.debug_info.dbline_section.sh_offset = self.file_size;
            self.file_size += self.program.debug_info.dbline_section.sh_size;

            self.program.debug_info.dblinestr_section.sh_offset = self.file_size;
            self.file_size += self.program.debug_info.dblinestr_section.sh_size;

            self.program.debug_info.dblinerela_section.sh_offset = self.file_size;
            self.file_size += self.program.debug_info.dblinerela_section.sh_size;

            self.program.debug_info.dblinerela_section.sh_link = symtab_index;
            self.program.debug_info.dblinerela_section.sh_info = dbg_line_index;

            self.program.debug_info.dbinfo_section.sh_offset = self.file_size;
            self.file_size += self.program.debug_info.dbinfo_section.sh_size;

            self.program.debug_info.dbabbrev_section.sh_offset = self.file_size;
            self.file_size += self.program.debug_info.dbabbrev_section.sh_size;

            self.program.debug_info.dbstr_section.sh_offset = self.file_size;
            self.file_size += self.program.debug_info.dbstr_section.sh_size;

            self.program.debug_info.dbinforela_section.sh_offset = self.file_size;
            self.file_size += self.program.debug_info.dbinforela_section.sh_size;

            self.program.debug_info.dbinforela_section.sh_link = symtab_index;
            self.program.debug_info.dbinforela_section.sh_info = dbg_info_index;
        }
    }

    fn writeObjectFile(self: *const Assembler) !void {
        const file_buffer = try self.allocator.alloc(u8, self.file_size);
        defer self.allocator.free(file_buffer);

        const cwd = std.fs.cwd();

        const file_name_ext = try std.mem.concat(self.allocator, u8, &.{ self.output_file, @ptrCast(".o") });
        defer self.allocator.free(file_name_ext);

        const file = try cwd.createFile(file_name_ext, .{});
        defer file.close();

        var file_writer = file.writer(file_buffer);
        const writer = &file_writer.interface;

        try Assembler.writeElf64_Ehdr(writer, &self.objfile.elf_header);
        try Assembler.writeElf64_Shdr(writer, &elf.Elf64_Shdr{
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
        if (self.flags.text) {
            try Assembler.writeElf64_Shdr(writer, &self.objfile.text_section.?);
        }
        if (self.flags.data) {
            try Assembler.writeElf64_Shdr(writer, &self.objfile.data_section.?);
        }
        try Assembler.writeElf64_Shdr(writer, &self.objfile.shnstrtab_section);
        if (self.flags.symbols) {
            try Assembler.writeElf64_Shdr(writer, &self.objfile.strtab_section.?);
            try Assembler.writeElf64_Shdr(writer, &self.objfile.symtab_section.?);
        }
        if (self.flags.relocations) {
            try Assembler.writeElf64_Shdr(writer, &self.objfile.relatab_section.?);
        }
        if (self.flags.debug_info) {
            try Assembler.writeElf64_Shdr(writer, &self.program.debug_info.dbline_section);
            try Assembler.writeElf64_Shdr(writer, &self.program.debug_info.dblinestr_section);
            try Assembler.writeElf64_Shdr(writer, &self.program.debug_info.dblinerela_section);
            try Assembler.writeElf64_Shdr(writer, &self.program.debug_info.dbinfo_section);
            try Assembler.writeElf64_Shdr(writer, &self.program.debug_info.dbabbrev_section);
            try Assembler.writeElf64_Shdr(writer, &self.program.debug_info.dbstr_section);
            try Assembler.writeElf64_Shdr(writer, &self.program.debug_info.dbinforela_section);
        }

        if (self.flags.text) {
            _ = try writer.write(self.objfile.code_buffer.?.items);
        }
        if (self.flags.data) {
            _ = try writer.write(self.objfile.data_buffer.?.items);
        }
        _ = try writer.write(self.objfile.shnstrtab.items);
        if (self.flags.symbols) {
            _ = try writer.write(self.objfile.strtab.items);
            try Assembler.writeSymbolsBuffer(writer, self.objfile.symtab.items);
        }
        if (self.flags.relocations) {
            try Assembler.writeRelocationsBuffer(writer, self.objfile.relatab.items);
        }
        if (self.flags.debug_info) {
            _ = try writer.write(self.program.debug_info.debug_line_buffer.items);
            _ = try writer.write(self.program.debug_info.debug_line_str_buffer.items);
            try Assembler.writeRelocationsBuffer(writer, self.program.debug_info.debug_line_rela_buffer.items);
            _ = try writer.write(self.program.debug_info.debug_info_buffer.items);
            _ = try writer.write(self.program.debug_info.debug_abbrev_buffer.items);
            _ = try writer.write(self.program.debug_info.debug_str_buffer.items);
            try Assembler.writeRelocationsBuffer(writer, self.program.debug_info.debug_info_rela_buffer.items);
        }

        try writer.flush();
    }

    pub fn genObj(self: *Assembler) AssemblerError!void {
        // Fill all program data
        try self.program.tokenize();
        // self.program.printTokens();
        try self.program.parse();
        // self.program.printParse();
        // self.program.printSymTab();
        try self.program.checkEntry();
        try self.program.genDataCodeBuffers();
        // self.program.printDebugInfo();

        // Create object file data from program data
        try self.genObjectFile();
    }

    pub fn writeObj(self: *Assembler) AssemblerError!void {
        try self.writeObjectFile();
    }

    pub fn deinit(self: *Assembler) void {
        self.allocator.free(self.rel_path);
        self.allocator.free(self.output_file);
        self.program.deinit();
        self.objfile.deinit(self.allocator);
    }
};
