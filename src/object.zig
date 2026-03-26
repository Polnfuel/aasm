const std = @import("std");
const parser = @import("parser");
const lexer = @import("lexer");
const datagen = @import("datagen");
const codegen = @import("codegen");

const elf = std.elf;

const ObjectError = error{
    SymbolNotFound,
    NoSectionInFile,
};

pub const ObjFile = struct {
    elf_header: elf.Elf64_Ehdr,
    text_section: ?elf.Elf64_Shdr,
    data_section: ?elf.Elf64_Shdr,
    code_buffer: ?*std.ArrayList(u8),
    data_buffer: ?*std.ArrayList(u8),
    shnstrtab: std.ArrayList(u8),
    strtab: std.ArrayList(u8),
    symtab: std.ArrayList(elf.Elf64_Sym),
    relatab: std.ArrayList(elf.Elf64_Rela),
    shnstrtab_section: elf.Elf64_Shdr,
    strtab_section: ?elf.Elf64_Shdr,
    symtab_section: ?elf.Elf64_Shdr,
    relatab_section: ?elf.Elf64_Shdr,

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
        };
    }

    pub fn deinit(self: *ObjFile, allocator: std.mem.Allocator) void {
        self.shnstrtab.deinit(allocator);
        self.strtab.deinit(allocator);
        self.symtab.deinit(allocator);
        self.relatab.deinit(allocator);
    }

    pub fn printStrTabSymTab(self: ObjFile) void {
        std.debug.print(" Section Names Table \n", .{});
        for (self.shnstrtab.items) |str| {
            std.debug.print("{c}", .{if (str > 0) str else ' '});
        }
        std.debug.print("\n", .{});

        std.debug.print(" Strings Table \n", .{});
        for (self.strtab.items) |str| {
            std.debug.print("{c}", .{if (str > 0) str else ' '});
        }
        std.debug.print("\n", .{});

        std.debug.print(" Symbols Table \n", .{});
        for (self.symtab.items) |symbol| {
            std.debug.print("  stind: {d:3}   value: {d:5}   scind: {d:1}\n", .{ symbol.st_name, symbol.st_value, symbol.st_shndx });
        }

        std.debug.print("  Relocations Table \n", .{});
        for (self.relatab.items) |rela| {
            const sym_name: [*:0]u8 = @ptrCast(self.strtab.items[self.symtab.items[rela.r_sym()].st_name..]);
            std.debug.print(" symname: {s:15} type: {d:3} offset: {d:3}\n", .{ sym_name, rela.r_type(), rela.r_offset });
        }
        std.debug.print("\n", .{});
    }
};

pub const Program = struct {
    content: []u8,
    tokens: std.ArrayList(lexer.Token),
    entry: ?[]u8,
    data_section: ?parser.DataSection,
    code_section: ?parser.CodeSection,
    allocator: std.mem.Allocator,

    pub fn new(file_name: []const u8, allocator: std.mem.Allocator) !Program {
        var program = Program{
            .content = undefined,
            .tokens = undefined,
            .entry = null,
            .data_section = null,
            .code_section = null,
            .allocator = allocator,
        };
        try program.loadFromFile(file_name);
        return program;
    }

    fn loadFromFile(self: *Program, file_name: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
        defer file.close();

        const file_stat = try file.stat();
        const file_size = file_stat.size;
        // std.debug.print("Loaded {d} bytes from {s}\n", .{ file_size, file_name });

        self.content = try self.allocator.alloc(u8, file_size + 1);

        var file_reader = file.reader(self.content);
        var reader = &file_reader.interface;
        try reader.readSliceAll(self.content[0..file_size]);
        self.content[file_size] = '\n';
    }

    pub fn tokenize(self: *Program) !void {
        self.tokens = try lexer.tokenizeContent(self.content, self.allocator);
    }

    pub fn printTokens(self: *Program) void {
        lexer.printTokens(self.tokens);
    }

    pub fn parse(self: *Program) !void {
        try parser.parseTokensToAST(self);
    }

    pub fn printParse(self: *Program) void {
        parser.printAST(self);
    }

    pub fn printSymTabs(self: *Program) void {
        parser.printSymbolTables(self);
    }

    pub fn genDataCodeBuffers(self: *Program) !void {
        if (self.data_section) |*data_section| {
            // bufferize data section
            try datagen.bufferizeDataSection(data_section, self.allocator);
            // std.debug.print("Data buffer:\n", .{});
            // printBuffer(data_section.buffer);
        }
        if (self.code_section) |*code_section| {
            // bufferize code section
            try codegen.bufferizeCodeSection(code_section, self.allocator);
            // std.debug.print("Code buffer\n", .{});
            // printBuffer(code_section.buffer);
        }
    }

    fn defineObjFileTables(self: *Program, objfile: *ObjFile) !void {
        var symbol_indices = std.StringHashMap(u32).init(self.allocator);
        defer symbol_indices.deinit();
        errdefer symbol_indices.deinit();

        try objfile.symtab.append(self.allocator, .{ .st_name = 0, .st_value = 0, .st_size = 0, .st_info = 0, .st_other = 0, .st_shndx = elf.SHN_UNDEF });
        var symtab_size: u32 = 1;

        try objfile.strtab.append(self.allocator, 0);
        var strtab_size: u32 = 1;

        try objfile.shnstrtab.append(self.allocator, 0);
        var shnstrtab_size: u32 = 1;

        objfile.shnstrtab_section = elf.Elf64_Shdr{
            .sh_name = undefined,
            .sh_type = elf.SHT_STRTAB,
            .sh_flags = elf.SHF_STRINGS,
            .sh_addr = 0,
            .sh_offset = undefined,
            .sh_size = undefined,
            .sh_link = 0,
            .sh_info = 0,
            .sh_addralign = 0,
            .sh_entsize = 0,
        };

        const code_section_ind: u8 = 1;
        const data_section_ind: u8 = if (self.code_section != null) 2 else 1;

        var str_start = strtab_size;

        str_start = strtab_size;
        if (self.code_section != null) {
            try objfile.strtab.appendSlice(self.allocator, @ptrCast(".text"));
            try objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(objfile.strtab.items.len);
            try objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = code_section_ind,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            symtab_size += 1;
        }
        str_start = strtab_size;
        if (self.data_section != null) {
            try objfile.strtab.appendSlice(self.allocator, @ptrCast(".data"));
            try objfile.strtab.append(self.allocator, 0);
            strtab_size = @truncate(objfile.strtab.items.len);
            try objfile.symtab.append(self.allocator, elf.Elf64_Sym{
                .st_name = str_start,
                .st_value = 0,
                .st_info = (elf.STB_LOCAL << 4) + (elf.STT_SECTION & 0xF),
                .st_shndx = data_section_ind,
                .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                .st_size = 0,
            });
            symtab_size += 1;
        }

        str_start = strtab_size;
        if (self.data_section) |*data_section| {
            objfile.data_buffer = &data_section.buffer;
            objfile.data_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = elf.SHF_ALLOC + elf.SHF_WRITE,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = objfile.data_buffer.?.items.len * @sizeOf(u8),
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x40,
                .sh_entsize = 0,
            };
            try objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".data"));
            try objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(objfile.shnstrtab.items.len);

            var iter = data_section.symbols.iterator();
            while (iter.next()) |entry| {
                // Put a new string into hash map
                str_start = strtab_size;
                try objfile.strtab.appendSlice(self.allocator, entry.key_ptr.*);
                try objfile.strtab.append(self.allocator, 0);
                strtab_size = @truncate(objfile.strtab.items.len);

                const binding: u8 = switch (entry.value_ptr.binding) {
                    .Local => elf.STB_LOCAL,
                    .Global => elf.STB_GLOBAL,
                };

                const symbol = elf.Elf64_Sym{
                    .st_name = str_start,
                    .st_value = entry.value_ptr.offset,
                    .st_size = 0,
                    .st_info = (binding << 4) + (elf.STT_OBJECT & 0xF),
                    .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                    .st_shndx = data_section_ind,
                };

                try objfile.symtab.append(self.allocator, symbol);
                try symbol_indices.put(entry.key_ptr.*, symtab_size);
                symtab_size += 1;
            }
        }

        const entry_point: []const u8 = self.entry orelse @ptrCast("");
        var entry_found = false;

        str_start = strtab_size;
        if (self.code_section) |*code_section| {
            objfile.code_buffer = &code_section.buffer;
            objfile.text_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = elf.SHF_ALLOC + elf.SHF_EXECINSTR,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = objfile.code_buffer.?.items.len * @sizeOf(u8),
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0x40,
                .sh_entsize = 0,
            };
            try objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".text"));
            try objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(objfile.shnstrtab.items.len);

            var iter = code_section.symbols.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, entry_point)) {
                    entry_found = true;
                    continue;
                }

                // Put a new string into hash map
                str_start = strtab_size;
                try objfile.strtab.appendSlice(self.allocator, entry.key_ptr.*);
                try objfile.strtab.append(self.allocator, 0);
                strtab_size = @truncate(objfile.strtab.items.len);

                const binding: u8 = switch (entry.value_ptr.binding) {
                    .Local => elf.STB_LOCAL,
                    .Global => elf.STB_GLOBAL,
                };

                const symbol = elf.Elf64_Sym{
                    .st_name = str_start,
                    .st_value = entry.value_ptr.offset,
                    .st_size = 0,
                    .st_info = (binding << 4) + (elf.STT_FUNC & 0xF),
                    .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                    .st_shndx = code_section_ind,
                };

                try objfile.symtab.append(self.allocator, symbol);
                try symbol_indices.put(entry.key_ptr.*, symtab_size);
                symtab_size += 1;
            }

            if (entry_found) {
                const entry = code_section.symbols.get(entry_point) orelse unreachable;

                str_start = strtab_size;
                try objfile.strtab.appendSlice(self.allocator, entry_point);
                try objfile.strtab.append(self.allocator, 0);
                strtab_size = @truncate(objfile.strtab.items.len);

                const symbol = elf.Elf64_Sym{
                    .st_name = str_start,
                    .st_value = entry.offset,
                    .st_size = 0,
                    .st_info = (elf.STB_GLOBAL << 4) + (elf.STT_FUNC & 0xF),
                    .st_other = @intFromEnum(elf.STV.DEFAULT) & 0x3,
                    .st_shndx = code_section_ind,
                };

                try objfile.symtab.append(self.allocator, symbol);
                try symbol_indices.put(entry_point, symtab_size);
                symtab_size += 1;
            }

            for (code_section.relocations.items) |relocation| {
                var sym_ind: u32 = 0;
                if (symbol_indices.get(relocation.name)) |index| {
                    sym_ind = index;
                } else {
                    return ObjectError.SymbolNotFound;
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

                try objfile.relatab.append(self.allocator, rela);
            }
        }
        if (objfile.symtab.items.len > 1) {
            objfile.strtab_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_STRTAB,
                .sh_flags = elf.SHF_STRINGS,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = objfile.strtab.items.len * @sizeOf(u8),
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 0,
                .sh_entsize = 0,
            };

            try objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".strtab"));
            try objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(objfile.shnstrtab.items.len);

            objfile.symtab_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_SYMTAB,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = objfile.symtab.items.len * @sizeOf(elf.Elf64_Sym),
                .sh_link = undefined,
                // Index of first global symbol
                .sh_info = @truncate(objfile.symtab.items.len - 1),
                .sh_addralign = 0,
                .sh_entsize = @sizeOf(elf.Elf64_Sym),
            };

            try objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".symtab"));
            try objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(objfile.shnstrtab.items.len);
        }

        if (objfile.relatab.items.len > 0) {
            objfile.relatab_section = elf.Elf64_Shdr{
                .sh_name = shnstrtab_size,
                .sh_type = elf.SHT_RELA,
                .sh_flags = 0,
                .sh_addr = 0,
                .sh_offset = undefined,
                .sh_size = objfile.relatab.items.len * @sizeOf(elf.Elf64_Rela),
                .sh_link = undefined,
                .sh_info = undefined,
                .sh_addralign = 0,
                .sh_entsize = @sizeOf(elf.Elf64_Rela),
            };

            try objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".rela.text"));
            try objfile.shnstrtab.append(self.allocator, 0);
            shnstrtab_size = @truncate(objfile.shnstrtab.items.len);
        }

        objfile.shnstrtab_section.sh_name = shnstrtab_size;

        try objfile.shnstrtab.appendSlice(self.allocator, @ptrCast(".shstrtab"));
        try objfile.shnstrtab.append(self.allocator, 0);
        shnstrtab_size = @truncate(objfile.shnstrtab.items.len);

        objfile.shnstrtab_section.sh_size = shnstrtab_size;
    }

    fn writeElf64_Ehdr(writer: *std.io.Writer, ehdr: *const elf.Elf64_Ehdr) !void {
        _ = try writer.write(&ehdr.e_ident);
        try writer.writeInt(u16, @intFromEnum(ehdr.e_type), .little);
        try writer.writeInt(u16, @intFromEnum(ehdr.e_machine), .little);
        try writer.writeInt(u32, ehdr.e_version, .little);
        try writer.writeInt(u64, ehdr.e_entry, .little);
        try writer.writeInt(u64, ehdr.e_phoff, .little);
        try writer.writeInt(u64, ehdr.e_shoff, .little);
        try writer.writeInt(u32, ehdr.e_flags, .little);
        try writer.writeInt(u16, ehdr.e_ehsize, .little);
        try writer.writeInt(u16, ehdr.e_phentsize, .little);
        try writer.writeInt(u16, ehdr.e_phnum, .little);
        try writer.writeInt(u16, ehdr.e_shentsize, .little);
        try writer.writeInt(u16, ehdr.e_shnum, .little);
        try writer.writeInt(u16, ehdr.e_shstrndx, .little);
    }

    fn writeElf64_Shdr(writer: *std.io.Writer, shdr: *const elf.Elf64_Shdr) !void {
        try writer.writeInt(u32, shdr.sh_name, .little);
        try writer.writeInt(u32, shdr.sh_type, .little);
        try writer.writeInt(u64, shdr.sh_flags, .little);
        try writer.writeInt(u64, shdr.sh_addr, .little);
        try writer.writeInt(u64, shdr.sh_offset, .little);
        try writer.writeInt(u64, shdr.sh_size, .little);
        try writer.writeInt(u32, shdr.sh_link, .little);
        try writer.writeInt(u32, shdr.sh_info, .little);
        try writer.writeInt(u64, shdr.sh_addralign, .little);
        try writer.writeInt(u64, shdr.sh_entsize, .little);
    }

    fn writeSymbolsBuffer(writer: *std.io.Writer, symbols: []elf.Elf64_Sym) !void {
        for (symbols) |sym| {
            try writer.writeStruct(sym, .little);
        }
    }
    fn writeRelocationsBuffer(writer: *std.io.Writer, relocations: []elf.Elf64_Rela) !void {
        for (relocations) |rel| {
            try writer.writeStruct(rel, .little);
        }
    }

    pub fn genObjectFile(self: *Program, file_name: []const u8) !void {
        var objfile = ObjFile.new();
        defer objfile.deinit(self.allocator);
        errdefer objfile.deinit(self.allocator);

        try self.defineObjFileTables(&objfile);
        // objfile.printStrTabSymTab();

        const with_text = if (objfile.text_section != null) true else false;
        const with_data = if (objfile.data_section != null) true else false;
        const with_symbols = if (objfile.symtab.items.len > 1) true else false;
        const with_relocations = if (objfile.relatab.items.len > 0) true else false;

        var text_index: u16 = 0;
        if (with_text) text_index += 1;
        var data_index: u16 = text_index;
        if (with_data) data_index += 1;

        if (data_index == 0) {
            return ObjectError.NoSectionInFile;
        }

        const shstrtab_index: u16 = data_index + 1;
        var strtab_index: u16 = shstrtab_index;
        var symtab_index: u16 = shstrtab_index;
        if (with_symbols) {
            strtab_index = shstrtab_index + 1;
            symtab_index = strtab_index + 1;
        }
        var relatext_index: u16 = symtab_index;
        if (with_relocations) {
            relatext_index = symtab_index + 1;
        }

        var file_pos: usize = 0;

        // Elf Header
        objfile.elf_header = elf.Elf64_Ehdr{
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
            .e_shnum = relatext_index + 1,
            .e_shstrndx = shstrtab_index,
        };

        file_pos += objfile.elf_header.e_ehsize;
        objfile.elf_header.e_shoff = file_pos;

        // Section Header Table Entry 0
        file_pos += objfile.elf_header.e_shentsize;

        // Section Header Table Entry 1 - .text
        if (with_text) {
            file_pos += objfile.elf_header.e_shentsize;
        }

        // Section Header Table Entry 2 - .data
        if (with_data) {
            file_pos += objfile.elf_header.e_shentsize;
        }

        // Section Header Table Entry 3 - .shstrtab
        file_pos += objfile.elf_header.e_shentsize;

        // Section Header Table Entry 4-5 - .strtab and .symtab
        if (with_symbols) {
            file_pos += objfile.elf_header.e_shentsize;
            file_pos += objfile.elf_header.e_shentsize;
        }

        // Section Header Table Entry 5 - .rela.text
        if (with_relocations) {
            file_pos += objfile.elf_header.e_shentsize;
        }

        // now file_pos is first byte after Section Header Table

        // Code buffer
        if (with_text) {
            objfile.text_section.?.sh_offset = file_pos;
            file_pos += objfile.text_section.?.sh_size;
        }
        // Data buffer
        if (with_data) {
            objfile.data_section.?.sh_offset = file_pos;
            file_pos += objfile.data_section.?.sh_size;
        }
        // Section Name String Table buffer
        objfile.shnstrtab_section.sh_offset = file_pos;
        file_pos += objfile.shnstrtab_section.sh_size;
        // String Table and Symbol Table buffers
        if (with_symbols) {
            objfile.strtab_section.?.sh_offset = file_pos;
            file_pos += objfile.strtab_section.?.sh_size;

            objfile.symtab_section.?.sh_offset = file_pos;
            file_pos += objfile.symtab_section.?.sh_size;

            objfile.symtab_section.?.sh_link = strtab_index;
        }
        // Relocation Table buffer
        if (with_relocations) {
            objfile.relatab_section.?.sh_offset = file_pos;
            file_pos += objfile.relatab_section.?.sh_size;

            objfile.relatab_section.?.sh_link = symtab_index;
            objfile.relatab_section.?.sh_info = text_index;
        }

        const file_buffer = try self.allocator.alloc(u8, file_pos);
        defer self.allocator.free(file_buffer);
        errdefer self.allocator.free(file_buffer);

        const cwd = std.fs.cwd();
        const file = try cwd.createFile(file_name, .{});
        defer file.close();
        errdefer file.close();

        var file_writer = file.writer(file_buffer);
        const writer = &file_writer.interface;

        try Program.writeElf64_Ehdr(writer, &objfile.elf_header);
        try Program.writeElf64_Shdr(writer, &elf.Elf64_Shdr{
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
        if (with_text) {
            try Program.writeElf64_Shdr(writer, &objfile.text_section.?);
        }
        if (with_data) {
            try Program.writeElf64_Shdr(writer, &objfile.data_section.?);
        }
        try Program.writeElf64_Shdr(writer, &objfile.shnstrtab_section);
        if (with_symbols) {
            try Program.writeElf64_Shdr(writer, &objfile.strtab_section.?);
            try Program.writeElf64_Shdr(writer, &objfile.symtab_section.?);
        }
        if (with_relocations) {
            try Program.writeElf64_Shdr(writer, &objfile.relatab_section.?);
        }

        if (with_text) {
            _ = try writer.write(objfile.code_buffer.?.items);
        }
        if (with_data) {
            _ = try writer.write(objfile.data_buffer.?.items);
        }
        _ = try writer.write(objfile.shnstrtab.items);
        if (with_symbols) {
            _ = try writer.write(objfile.strtab.items);
            try Program.writeSymbolsBuffer(writer, objfile.symtab.items);
        }
        if (with_relocations) {
            try Program.writeRelocationsBuffer(writer, objfile.relatab.items);
        }

        try writer.flush();
    }

    pub fn printBuffer(buffer: std.ArrayList(u8)) void {
        for (buffer.items) |byte| {
            std.debug.print("{x:02}", .{byte});
        }
        std.debug.print("\n", .{});
    }

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.content);
        self.tokens.deinit(self.allocator);
        if (self.data_section) |*data_section| {
            data_section.buffer.deinit(self.allocator);
            data_section.symbols.deinit();
            for (data_section.instr.items) |*instr| {
                instr.data.deinit(self.allocator);
            }
            data_section.instr.deinit(self.allocator);
        }
        if (self.code_section) |*code_section| {
            code_section.buffer.deinit(self.allocator);
            code_section.symbols.deinit();
            for (code_section.instr.items) |*instr| {
                switch (instr.*) {
                    .cpu => {
                        instr.cpu.operands.deinit(self.allocator);
                    },
                    .label => {},
                }
            }
            code_section.instr.deinit(self.allocator);
            code_section.relocations.deinit(self.allocator);
        }
    }
};
