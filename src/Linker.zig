const std = @import("std");
const elf = std.elf;

const utils = @import("utils");
const Assembler = @import("Assembler");
const CompUnit = Assembler.CompUnit;

const Linker = @This();

pub const LinkerError = error{ LinkingFailed, LoadingFailed } || std.mem.Allocator.Error || std.Io.File.OpenError || std.Io.File.StatError || std.process.CurrentPathAllocError || std.Io.Writer.Error || std.Io.File.SetPermissionsError || std.posix.MMapError;

/// Elf64 executable file representation
const ExeElf = struct {
    const ExePhdrs = struct {
        phdr: elf.Elf64.Phdr,
        interp: elf.Elf64.Phdr,
        rx: elf.Elf64.Phdr,
        r: elf.Elf64.Phdr,
        rw: elf.Elf64.Phdr,
        dynamic: elf.Elf64.Phdr,

        pub fn print(self: *ExePhdrs) void {
            const info = @typeInfo(ExePhdrs).@"struct";
            inline for (info.fields) |field| {
                std.debug.print("{x:10} - {s} - {x}\n", .{ @field(self, field.name).vaddr, field.name, @field(self, field.name).filesz });
            }
        }
    };

    const ExeSections = struct {
        const Section = struct {
            ind: u8 = 0,
            name: u32 = 0,
            vaddr: u64 = 0,
            offset: u64 = 0,
            size: usize = 0,
        };
        plt: Section = Section{},
        text: Section = Section{},
        interp: Section = Section{},
        hash: Section = Section{},
        dynsym: Section = Section{},
        dynstr: Section = Section{},
        reladyn: Section = Section{},
        relaplt: Section = Section{},
        dynamic: Section = Section{},
        gotplt: Section = Section{},
        data: Section = Section{},
        bss: Section = Section{},

        debug_line: Section = Section{},
        debug_line_str: Section = Section{},
        debug_info: Section = Section{},
        debug_abrrev: Section = Section{},
        debug_str: Section = Section{},

        symtab: Section = Section{},
        strtab: Section = Section{},
        shstrtab: Section = Section{},

        pub fn print(self: *ExeSections) void {
            const info = @typeInfo(ExeSections).@"struct";
            inline for (info.fields) |field| {
                std.debug.print("{d:2} {x:10} - {x:6} - {s} - {x}\n", .{
                    @field(self, field.name).ind,
                    @field(self, field.name).vaddr,
                    @field(self, field.name).offset,
                    field.name,
                    @field(self, field.name).size,
                });
            }
        }
    };

    const Buffers = struct {
        const Buffer = std.ArrayList(u8);

        plt: Buffer = .empty,
        text: Buffer = .empty,
        interp: Buffer = .empty,
        hash: std.ArrayList(u32) = .empty,
        dynstr: Buffer = .empty,
        dynsym: std.ArrayList(elf.Elf64.Sym) = .empty,
        reladyn: std.ArrayList(elf.Elf64.Rela) = .empty,
        relaplt: std.ArrayList(elf.Elf64.Rela) = .empty,
        dynamic: std.ArrayList(elf.Elf64_Dyn) = .empty,
        gotplt: std.ArrayList(u64) = .empty,
        data: Buffer = .empty,
        bss: std.ArrayList(void) = .empty,

        debug_line: Buffer = .empty,
        debug_line_str: Buffer = .empty,
        debug_info: Buffer = .empty,
        debug_abrrev: Buffer = .empty,
        debug_str: Buffer = .empty,

        symtab: std.ArrayList(elf.Elf64.Sym) = .empty,
        strtab: Buffer = .empty,
        shstrtab: Buffer = .empty,

        pub fn deinit(self: *Buffers) void {
            self.plt.deinit(utils.alloc);
            self.text.deinit(utils.alloc);
            self.interp.deinit(utils.alloc);
            self.hash.deinit(utils.alloc);
            self.dynstr.deinit(utils.alloc);
            self.dynsym.deinit(utils.alloc);
            self.reladyn.deinit(utils.alloc);
            self.relaplt.deinit(utils.alloc);
            self.dynamic.deinit(utils.alloc);
            self.gotplt.deinit(utils.alloc);
            self.data.deinit(utils.alloc);
            self.debug_line.deinit(utils.alloc);
            self.debug_line_str.deinit(utils.alloc);
            self.debug_info.deinit(utils.alloc);
            self.debug_abrrev.deinit(utils.alloc);
            self.debug_str.deinit(utils.alloc);
            self.symtab.deinit(utils.alloc);
            self.strtab.deinit(utils.alloc);
            self.shstrtab.deinit(utils.alloc);
        }
    };

    output_name: []const u8,
    entry: ?struct { name: []const u8, vaddr: u64 },
    has_data: bool,
    has_bss: bool,
    has_dynamic: bool,
    has_plt: bool,
    has_copyobj: bool,
    has_debug: bool,
    has_shtable: bool,
    sections: *ExeSections,
    phdrs: *ExePhdrs,
    buffs: *Buffers,
    symtab_info: u32,

    pub fn init(self: *ExeElf) std.mem.Allocator.Error!void {
        self.entry = null;
        self.has_data = false;
        self.has_bss = false;
        self.has_dynamic = false;
        self.has_plt = false;
        self.has_copyobj = false;
        self.has_debug = false;
        self.has_shtable = true;
        self.sections = try utils.alloc.create(ExeSections);
        self.sections.* = ExeSections{};
        self.phdrs = try utils.alloc.create(ExePhdrs);
        self.buffs = try utils.alloc.create(Buffers);
        self.buffs.* = Buffers{};
    }

    pub fn addNoOps(self: *ExeElf, bytes: usize) void {
        var i: usize = bytes;
        while (i >= 9) : (i -= 9) {
            self.buffs.text.appendSliceAssumeCapacity(&.{ 0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 });
        }
        switch (i) {
            1 => self.buffs.text.appendAssumeCapacity(0x90),
            2 => self.buffs.text.appendSliceAssumeCapacity(&.{ 0x66, 0x90 }),
            3 => self.buffs.text.appendSliceAssumeCapacity(&.{ 0x0F, 0x1F, 0x00 }),
            4 => self.buffs.text.appendSliceAssumeCapacity(&.{ 0x0F, 0x1F, 0x40, 0x00 }),
            5 => self.buffs.text.appendSliceAssumeCapacity(&.{ 0x0F, 0x1F, 0x44, 0x00, 0x00 }),
            6 => self.buffs.text.appendSliceAssumeCapacity(&.{ 0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00 }),
            7 => self.buffs.text.appendSliceAssumeCapacity(&.{ 0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00 }),
            8 => self.buffs.text.appendSliceAssumeCapacity(&.{ 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 }),
            else => {},
        }
    }

    pub fn appendDynstrName(self: *ExeElf, name: []const u8) u32 {
        const index: u32 = @truncate(self.buffs.dynstr.items.len);
        self.buffs.dynstr.appendSliceAssumeCapacity(name);
        self.buffs.dynstr.appendAssumeCapacity(0);
        return index;
    }

    pub fn appendStrtabName(self: *ExeElf, name: []const u8) std.mem.Allocator.Error!u32 {
        const index: u32 = @truncate(self.buffs.strtab.items.len);
        try self.buffs.strtab.appendSlice(utils.alloc, name);
        try self.buffs.strtab.append(utils.alloc, 0);
        return index;
    }

    pub fn appendShstrtabName(self: *ExeElf, name: []const u8) std.mem.Allocator.Error!u32 {
        const index: u32 = @truncate(self.buffs.shstrtab.items.len);
        try self.buffs.shstrtab.appendSlice(utils.alloc, name);
        try self.buffs.shstrtab.append(utils.alloc, 0);
        return index;
    }

    pub fn patchTextRelocation(self: *ExeElf, offset: usize, comptime T: type, value: T) void {
        const bytes: comptime_int = @typeInfo(T).int.bits / 8;
        std.mem.writeInt(T, @ptrCast(self.buffs.text.items[offset .. offset + bytes]), value, .little);
    }

    pub fn deinit(self: *ExeElf) void {
        utils.alloc.destroy(self.sections);
        utils.alloc.destroy(self.phdrs);
        self.buffs.deinit();
        utils.alloc.destroy(self.buffs);
    }
};

const ObjInfo = packed struct {
    size: u15,
    section: enum(u1) {
        rodata,
        wdata,
    },
};

const Object = struct {
    info: ObjInfo,
    vaddr: u64,
};

const DynLibElf = struct {
    resolved_name: []const u8 = &.{},
    mem: []align(std.heap.page_size_min) u8,
    strings: [*:0]u8,
    syms: [*]elf.Elf64.Sym,
    hash_table: HashTable,

    const HashTable = union(enum) {
        hash: [*]std.posix.Elf_Symndx,
        gnu_hash: *elf.gnu_hash.Header,
    };

    pub fn open(file: std.Io.File, io: std.Io) LinkerError!DynLibElf {
        const stat = try file.stat(io);
        const page = std.heap.pageSize();

        const file_bytes = try std.posix.mmap(
            null,
            std.mem.alignForward(u64, stat.size, page),
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        defer std.posix.munmap(file_bytes);

        const eh = @as(*elf.Elf64.Ehdr, @ptrCast(file_bytes.ptr));

        const elf_addr = @intFromPtr(file_bytes.ptr);

        var opt_dynv: ?[]u64 = null;
        var addr_end: usize = 0;
        var i: usize = 0;
        var ph_addr: usize = elf_addr + eh.phoff;
        while (i < eh.phnum) : ({
            i += 1;
            ph_addr += eh.phentsize;
        }) {
            const ph = @as(*elf.Elf64.Phdr, @ptrFromInt(ph_addr));
            switch (ph.type) {
                elf.PT.DYNAMIC => {
                    const ptr: u64 = elf_addr + ph.offset;
                    const len: u64 = ph.filesz;
                    var slice: []u64 = &.{};
                    slice.ptr = @ptrFromInt(ptr);
                    slice.len = len;
                    opt_dynv = slice;
                },
                elf.PT.LOAD => {
                    addr_end = @max(addr_end, ph.vaddr + ph.memsz);
                },
                else => {},
            }
        }
        const dynv = opt_dynv orelse {
            return LinkerError.LoadingFailed;
        };

        const mem = try std.posix.mmap(null, addr_end, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(mem);

        const base = @intFromPtr(mem.ptr);
        i = 0;
        ph_addr = elf_addr + eh.phoff;
        while (i < eh.phnum) : ({
            i += 1;
            ph_addr += eh.phentsize;
        }) {
            const ph = @as(*elf.Elf64.Phdr, @ptrFromInt(ph_addr));
            switch (ph.type) {
                elf.PT.LOAD => {
                    const aligned = (base + ph.vaddr) & ~(@as(usize, page) - 1);
                    const extra = (base + ph.vaddr) - aligned;
                    const extended = std.mem.alignForward(usize, ph.memsz + extra, page);
                    const ptr = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(aligned));
                    const prot: std.posix.PROT = .{
                        .READ = ph.flags.R,
                        .WRITE = ph.flags.W,
                        .EXEC = ph.flags.X,
                    };
                    _ = try std.posix.mmap(ptr, extended, prot, .{ .TYPE = .PRIVATE, .FIXED = true }, file.handle, ph.offset - extra);
                },
                else => {},
            }
        }

        var opt_strs: ?[*:0]u8 = null;
        var opt_syms: ?[*]elf.Elf64.Sym = null;
        var opt_hashtab: ?[*]std.posix.Elf_Symndx = null;
        var opt_gnu_hash: ?*elf.gnu_hash.Header = null;

        i = 0;
        while (dynv[i] != 0) : (i += 2) {
            const p = base + dynv[i + 1];
            switch (dynv[i]) {
                elf.DT_STRTAB => opt_strs = @ptrFromInt(p),
                elf.DT_SYMTAB => opt_syms = @ptrFromInt(p),
                elf.DT_HASH => opt_hashtab = @ptrFromInt(p),
                elf.DT_GNU_HASH => opt_gnu_hash = @ptrFromInt(p),
                else => {},
            }
        }

        const hash_table: HashTable = if (opt_gnu_hash) |gnu|
            .{ .gnu_hash = gnu }
        else if (opt_hashtab) |hash|
            .{ .hash = hash }
        else
            return LinkerError.LoadingFailed;

        return DynLibElf{
            .mem = mem,
            .strings = opt_strs orelse return LinkerError.LoadingFailed,
            .syms = opt_syms orelse return LinkerError.LoadingFailed,
            .hash_table = hash_table,
        };
    }

    pub fn close(self: *DynLibElf) void {
        std.posix.munmap(self.mem);
    }

    pub fn lookup(self: *DynLibElf, sym_name: []const u8) ?union(enum) { func: elf.STT, obj: ObjInfo } {
        switch (self.hash_table) {
            .hash => {},
            .gnu_hash => |header| {
                const nbuckets = header.nbuckets;
                const symndx = header.symoffset;
                const bloom_shift = header.bloom_shift;
                const bloom_size = header.bloom_size;

                const bloom_ptr: [*]u64 = @ptrFromInt(@intFromPtr(header) + @sizeOf(elf.gnu_hash.Header));
                const bloom = bloom_ptr[0..bloom_size];

                const buckets_ptr: [*]u32 = @ptrFromInt(@intFromPtr(bloom_ptr) + @sizeOf(u64) * bloom_size);
                const buckets = buckets_ptr[0..nbuckets];

                const chain: [*]elf.gnu_hash.ChainEntry = @ptrFromInt(@intFromPtr(buckets_ptr) + @sizeOf(u32) * nbuckets);

                const hash = elf.gnu_hash.calculate(sym_name);
                const bloom_index = (hash / 64) % bloom_size;
                const bloom_val = bloom[bloom_index];

                const bit_index_0 = hash % 64;
                const bit_index_1 = (hash >> @intCast(bloom_shift)) % 64;
                const bit_mask: u64 = (@as(u64, 1) << @intCast(bit_index_0)) | (@as(u64, 1) << @intCast(bit_index_1));

                if (bloom_val & bit_mask != bit_mask) {
                    return null;
                }

                const bucket_index = hash % nbuckets;
                const chain_index = buckets[bucket_index] - symndx;

                const as_entry: elf.gnu_hash.ChainEntry = @bitCast(hash);
                var cur_index = chain_index;
                var end = false;
                while (!end) : (cur_index += 1) {
                    const cur_entry = chain[cur_index];
                    end = cur_entry.end_of_chain;

                    if (cur_entry.hash != as_entry.hash) continue;

                    const sym_index = cur_index + symndx;
                    const symbol = self.syms[sym_index];

                    const cur_name: []u8 = std.mem.sliceTo(self.strings + symbol.name, 0);
                    if (!std.mem.eql(u8, cur_name, sym_name)) {
                        continue;
                    }

                    if (symbol.info.type == .OBJECT) {
                        const sym_size: u15 = @intCast(symbol.size);
                        // TODO: Determine symbol section
                        return .{ .obj = .{ .size = sym_size, .section = .wdata } };
                    } else if (symbol.info.type == .FUNC or symbol.info.type == elf.STT.GNU_IFUNC) {
                        return .{ .func = .FUNC };
                    }
                }
            },
        }

        return null;
    }
};

const Flags = struct {
    debug: bool,
    strip: bool,
    quiet: bool,
};

const Shn = enum(u2) {
    text,
    data,
    bss,
};

const FileSection = packed struct {
    file: u14,
    section: Shn,
};

const HM_Context = struct {
    pub fn hash(self: *const HM_Context, key: FileSection) u64 {
        _ = self;
        return (key.file * 3 + @intFromEnum(key.section));
    }
    pub fn eql(self: *const HM_Context, first: FileSection, second: FileSection) bool {
        _ = self;
        return (first.file == second.file and first.section == second.section);
    }
};

const LinkerSymbol = packed struct {
    vaddr: u64,
    size: u30,
    shn: Shn,
};

const LibraryFile = struct {
    file: std.Io.File,
    name: []const u8,
};

exe: ExeElf,
comp_units: []CompUnit,
flags: Flags,
dyn_libs: std.ArrayList([]const u8),
dyn_funcs: std.StringHashMapUnmanaged(u64),
dyn_objects: std.StringHashMapUnmanaged(Object),
dyn_search_paths: std.ArrayList([]const u8),
dyn_runpath: std.ArrayList([]const u8),
offsets: std.HashMapUnmanaged(FileSection, usize, HM_Context, 80),
locals: std.StringHashMapUnmanaged(LinkerSymbol),
globals: std.StringHashMapUnmanaged(LinkerSymbol),

pub fn init(self: *Linker, output_name: []const u8, comp_units: []CompUnit, flags: Flags, search_paths: std.ArrayList([]const u8)) std.mem.Allocator.Error!void {
    self.comp_units = comp_units;
    self.dyn_libs = .empty;
    self.dyn_funcs = .empty;
    self.dyn_objects = .empty;
    self.dyn_search_paths = search_paths;
    self.dyn_runpath = .empty;
    self.offsets = .empty;
    self.locals = .empty;
    self.globals = .empty;
    self.flags = flags;
    try self.exe.init();
    self.exe.output_name = output_name;
    if (flags.debug) {
        self.exe.has_debug = true;
    } else if (flags.strip) {
        self.exe.has_shtable = false;
    }
}

fn checkIfValidLibrary(file_handle: std.Io.File.Handle) std.posix.MMapError!bool {
    const first_page = try std.posix.mmap(null, std.heap.pageSize(), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file_handle, 0);
    defer std.posix.munmap(first_page);

    if (first_page.len < @sizeOf(elf.Elf64.Ehdr)) return false;

    const eh = @as(*elf.Elf64.Ehdr, @ptrCast(first_page.ptr));
    if (!std.mem.eql(u8, eh.ident[0..4], elf.MAGIC) or eh.type != elf.ET.DYN) {
        return false;
    }

    return true;
}

fn searchInPath(self: *Linker, cwd_path: []const u8, search_dir_path: []const u8, lib_fullname: []const u8, save_path: bool) LinkerError!?LibraryFile {
    const abs_file_path = try std.fs.path.resolve(utils.alloc, &.{ cwd_path, search_dir_path, lib_fullname });
    defer utils.alloc.free(abs_file_path);

    const abs_dir_path = abs_file_path[0 .. abs_file_path.len - lib_fullname.len];
    // std.debug.print("Abs file: {s}\n", .{abs_file_path});
    // std.debug.print("Abs dir: {s}\n", .{abs_dir_path});

    const file = std.Io.Dir.openFileAbsolute(utils.io, abs_file_path, .{}) catch return null;

    if (!try checkIfValidLibrary(file.handle)) {
        const search_dir = try std.Io.Dir.openDirAbsolute(utils.io, abs_dir_path, .{ .iterate = true });
        var dir_iter = search_dir.iterateAssumeFirstIteration();
        while (try dir_iter.next(utils.io)) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.name, lib_fullname)) {
                // std.debug.print("File {s}\n", .{entry.name});
                const dir_file = try search_dir.openFile(utils.io, entry.name, .{});
                if (try checkIfValidLibrary(dir_file.handle)) {
                    // std.debug.print("Found valid file {s} in {s}\n", .{ entry.name, abs_dir_path });
                    if (save_path) {
                        try self.dyn_runpath.append(utils.alloc, try utils.alloc.dupe(u8, abs_dir_path));
                    }
                    return LibraryFile{ .file = dir_file, .name = try utils.alloc.dupe(u8, entry.name) };
                }
                dir_file.close(utils.io);
            }
        }
        return null;
    } else {
        if (save_path) {
            try self.dyn_runpath.append(utils.alloc, try utils.alloc.dupe(u8, abs_dir_path));
        }
        return LibraryFile{ .file = file, .name = try utils.alloc.dupe(u8, lib_fullname) };
    }
}

fn resolveLibFileName(libname: []const u8) std.mem.Allocator.Error![]const u8 {
    var buffer = try utils.alloc.alloc(u8, libname.len + 6);
    defer utils.alloc.free(buffer);

    var len: usize = 0;
    if (!std.mem.startsWith(u8, libname, "lib")) {
        @memcpy(buffer[len .. len + 3], "lib");
        len += 3;
    }
    @memcpy(buffer[len .. len + libname.len], libname);
    len += libname.len;
    if (std.mem.findPosLinear(u8, libname, 0, ".so") == null) {
        @memcpy(buffer[len .. len + 3], ".so");
        len += 3;
    }

    const copy = try utils.alloc.dupe(u8, buffer[0..len]);
    return copy;
}

fn findLib(self: *Linker, lib_fullname: []const u8) LinkerError!DynLibElf {
    const cwd_path_sent = try std.process.currentPathAlloc(utils.io, utils.alloc);
    defer utils.alloc.free(cwd_path_sent);
    const cwd_path: []const u8 = @ptrCast(cwd_path_sent);

    for (self.dyn_search_paths.items) |search_path| {
        const found_file = try self.searchInPath(cwd_path, search_path, lib_fullname, true) orelse continue;
        defer {
            found_file.file.close(utils.io);
            utils.alloc.free(found_file.name);
        }

        var dynlib = DynLibElf.open(found_file.file, utils.io) catch continue;
        dynlib.resolved_name = try utils.alloc.dupe(u8, found_file.name);
        return dynlib;
    }

    const syslib_prefix = "/usr/lib64/";
    const found_file = try self.searchInPath(cwd_path, syslib_prefix, lib_fullname, false) orelse {
        utils.printErrorFmt("Could not find '{s}' library\n", .{lib_fullname});
        return LinkerError.LinkingFailed;
    };
    defer {
        found_file.file.close(utils.io);
        utils.alloc.free(found_file.name);
    }

    var dynlib = DynLibElf.open(found_file.file, utils.io) catch {
        utils.printErrorFmt("Could not find '{s}' library\n", .{lib_fullname});
        return LinkerError.LinkingFailed;
    };
    dynlib.resolved_name = try utils.alloc.dupe(u8, found_file.name);
    return dynlib;
}

fn printDynstr(self: *Linker) void {
    std.debug.print("Dynstr: \n", .{});
    for (self.exe.buffs.dynstr.items) |byte| {
        std.debug.print("{c}", .{if (byte == 0) '.' else byte});
    }
    std.debug.print("\n", .{});
}

fn printDynsym(self: *Linker) void {
    std.debug.print("Dynsym: \n", .{});
    for (self.exe.buffs.dynsym.items) |sym| {
        const sym_name: []const u8 = std.mem.sliceTo(self.exe.buffs.dynstr.items[sym.name..], 0);
        std.debug.print("{x:016}{x:4}{t:7}{t:8}{t:8}{d:3} {s}\n", .{
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

fn printStrtab(self: *Linker) void {
    std.debug.print(" Strtab: \n", .{});
    for (self.exe.buffs.strtab.items) |byte| {
        std.debug.print("{c}", .{if (byte == 0) '.' else byte});
    }
    std.debug.print("\n", .{});

    std.debug.print(" Shstrtab: \n", .{});
    for (self.exe.buffs.shstrtab.items) |byte| {
        std.debug.print("{c}", .{if (byte == 0) '.' else byte});
    }
    std.debug.print("\n", .{});
}

fn printSymtab(self: *Linker) void {
    std.debug.print(" Symtab: \n", .{});
    for (self.exe.buffs.symtab.items) |sym| {
        const sym_name: []const u8 = std.mem.sliceTo(self.exe.buffs.strtab.items[sym.name..], 0);
        std.debug.print("{x:016}{x:4}{t:7}{t:8}{t:8}{d:3} {s}\n", .{
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

fn printFuncsObjects(self: *Linker) void {
    var f_iter = self.dyn_funcs.iterator();
    var o_iter = self.dyn_objects.iterator();
    std.debug.print("Dyn funcs: \n", .{});
    while (f_iter.next()) |func| {
        std.debug.print("{x:016} {s}\n", .{ func.value_ptr.*, func.key_ptr.* });
    }
    std.debug.print("Dyn objects: \n", .{});
    while (o_iter.next()) |obj| {
        std.debug.print("{x:016} {s} {x} {t}\n", .{ obj.value_ptr.vaddr, obj.key_ptr.*, obj.value_ptr.info.size, obj.value_ptr.info.section });
    }
}

fn printBuffers(self: *Linker) void {
    std.debug.print("plt buffer: \n", .{});
    for (self.exe.buffs.plt.items) |byte| {
        std.debug.print("{x:02}", .{byte});
    }
    std.debug.print("\n", .{});

    std.debug.print("text buffer: \n", .{});
    for (self.exe.buffs.text.items) |byte| {
        std.debug.print("{x:02}", .{byte});
    }
    std.debug.print("\n", .{});

    std.debug.print("data buffer: \n", .{});
    for (self.exe.buffs.data.items) |byte| {
        std.debug.print("{x:02}", .{byte});
    }
    std.debug.print("\n", .{});
}

fn printSymbols(self: *Linker) void {
    std.debug.print(" Local symbols\n", .{});
    var l_iter = self.locals.iterator();
    while (l_iter.next()) |sym| {
        std.debug.print("{s:<15} {x:0>16}\n", .{ sym.key_ptr.*, sym.value_ptr.vaddr });
    }

    std.debug.print(" Global symbols\n", .{});
    var g_iter = self.globals.iterator();
    while (g_iter.next()) |sym| {
        std.debug.print("{s:<15} {x:0>16}\n", .{ sym.key_ptr.*, sym.value_ptr.vaddr });
    }
    std.debug.print(" Entry: {s} {x:016}\n", .{ self.exe.entry.?.name, self.exe.entry.?.vaddr });
}

fn printRelas(self: *Linker) void {
    std.debug.print(" RelaPlt: \n", .{});
    for (self.exe.buffs.relaplt.items) |rela| {
        const sym = self.exe.buffs.dynsym.items[rela.info.sym];
        const sym_name: []const u8 = std.mem.sliceTo(self.exe.buffs.dynstr.items[sym.name..], 0);
        std.debug.print("{x:016} {x:08}{x:08} {t:16} {x:016} {s}\n", .{
            rela.offset,
            rela.info.sym,
            rela.info.type,
            @as(elf.R_X86_64, @enumFromInt(rela.info.type)),
            sym.value,
            sym_name,
        });
    }
    std.debug.print(" RelaDyn: \n", .{});
    for (self.exe.buffs.reladyn.items) |rela| {
        const sym = self.exe.buffs.dynsym.items[rela.info.sym];
        const sym_name: []const u8 = std.mem.sliceTo(self.exe.buffs.dynstr.items[sym.name..], 0);
        std.debug.print("{x:016} {x:08}{x:08} {t:16} {x:016} {s}\n", .{
            rela.offset,
            rela.info.sym,
            rela.info.type,
            @as(elf.R_X86_64, @enumFromInt(rela.info.type)),
            sym.value,
            sym_name,
        });
    }
}

fn linkPlt(self: *Linker) void {
    const plt = &self.exe.buffs.plt;
    const gotplt = &self.exe.buffs.gotplt;
    const relaplt = &self.exe.buffs.relaplt;
    const dynsym = &self.exe.buffs.dynsym;

    const plt_vaddr = self.exe.sections.plt.vaddr;
    const gotplt_vaddr = self.exe.sections.gotplt.vaddr;

    const disp: u32 = @intCast(gotplt_vaddr + 8 - plt_vaddr);
    plt.appendSliceAssumeCapacity(&.{ 0xFF, 0x35 });
    plt.appendSliceAssumeCapacity(std.mem.asBytes(&(disp - 6)));
    plt.appendSliceAssumeCapacity(&.{ 0xFF, 0x25 });
    plt.appendSliceAssumeCapacity(std.mem.asBytes(&(disp - 4)));
    plt.appendSliceAssumeCapacity(&.{ 0x0F, 0x1F, 0x40, 0x00 });

    gotplt.appendAssumeCapacity(self.exe.sections.dynamic.vaddr);
    gotplt.appendSliceAssumeCapacity(&.{ 0, 0 });

    var plt_diff: u32 = @intCast(gotplt_vaddr - plt_vaddr + 2);
    var index: u32 = 0;
    var jmp_diff: u32 = 0xFFFFFFE0;

    var funcs_iter = self.dyn_funcs.iterator();
    while (funcs_iter.next()) |func| {
        func.value_ptr.* = plt_vaddr + plt.items.len;
        plt.appendSliceAssumeCapacity(&.{ 0xFF, 0x25 });
        plt.appendSliceAssumeCapacity(std.mem.asBytes(&plt_diff));
        plt_diff -= 8;

        plt.appendAssumeCapacity(0x68);
        plt.appendSliceAssumeCapacity(std.mem.asBytes(&index));
        index += 1;

        plt.appendAssumeCapacity(0xE9);
        plt.appendSliceAssumeCapacity(std.mem.asBytes(&jmp_diff));
        jmp_diff -= 16;

        gotplt.appendAssumeCapacity(func.value_ptr.* + 6);

        const sym_name = self.exe.appendDynstrName(func.key_ptr.*);
        const sym_ind: u32 = @truncate(dynsym.items.len);
        dynsym.appendAssumeCapacity(.{
            .name = sym_name,
            .info = .{ .bind = .GLOBAL, .type = .FUNC },
            .other = .{ .visibility = .DEFAULT },
            .shndx = elf.SHN_UNDEF,
            .value = 0,
            .size = 0,
        });
        relaplt.appendAssumeCapacity(.{
            .offset = gotplt_vaddr + (index + 2) * 8,
            .info = .{ .sym = sym_ind, .type = @intFromEnum(elf.R_X86_64.JUMP_SLOT) },
            .addend = 0,
        });
    }
}

fn linkGot(self: *Linker) void {
    const dynsym = &self.exe.buffs.dynsym;
    const reladyn = &self.exe.buffs.reladyn;

    var bss_vaddr = self.exe.sections.bss.vaddr;
    var dynobject_iter = self.dyn_objects.iterator();
    while (dynobject_iter.next()) |obj| {
        switch (obj.value_ptr.info.section) {
            .wdata => {
                const start = bss_vaddr;
                bss_vaddr = std.mem.alignForward(u64, bss_vaddr, 0x8);
                obj.value_ptr.vaddr = bss_vaddr;
                bss_vaddr += obj.value_ptr.info.size;
                self.exe.buffs.bss.appendNTimesAssumeCapacity({}, bss_vaddr - start);

                const sym_name = self.exe.appendDynstrName(obj.key_ptr.*);
                const sym_ind: u32 = @truncate(dynsym.items.len);
                dynsym.appendAssumeCapacity(.{
                    .name = sym_name,
                    .info = .{ .bind = .GLOBAL, .type = .OBJECT },
                    .other = .{ .visibility = .DEFAULT },
                    .shndx = self.exe.sections.bss.ind,
                    .value = obj.value_ptr.vaddr,
                    .size = obj.value_ptr.info.size,
                });
                reladyn.appendAssumeCapacity(.{
                    .offset = obj.value_ptr.vaddr,
                    .info = .{ .sym = sym_ind, .type = @intFromEnum(elf.R_X86_64.COPY) },
                    .addend = 0,
                });
            },
            .rodata => {}, // TODO: put in .got
        }
    }
}

fn mergeTextDataBss(self: *Linker) LinkerError!void {
    for (self.comp_units, 0..) |unit, i| {
        if (unit.program.flags.has_code) {
            const prev_len = self.exe.buffs.text.items.len;
            const next_aligned = std.mem.alignForward(usize, prev_len, 0x10);
            self.exe.addNoOps(next_aligned - prev_len);
            const offset = self.exe.buffs.text.items.len;
            try self.offsets.putNoClobber(utils.alloc, .{ .file = @truncate(i), .section = .text }, offset);
            self.exe.buffs.text.appendSliceAssumeCapacity(unit.objfile.buffs.text.items);
        }
        if (unit.program.flags.has_data) {
            const prev_len = self.exe.buffs.data.items.len;
            const next_aligned = std.mem.alignForward(usize, prev_len, 0x8);
            self.exe.buffs.data.appendNTimesAssumeCapacity(0, next_aligned - prev_len);
            const offset = self.exe.buffs.data.items.len;
            try self.offsets.putNoClobber(utils.alloc, .{ .file = @truncate(i), .section = .data }, offset);
            self.exe.buffs.data.appendSliceAssumeCapacity(unit.objfile.buffs.data.items);
        }
        if (unit.program.flags.has_bss) {
            const prev_len = self.exe.buffs.bss.items.len;
            const next_aligned = std.mem.alignForward(usize, prev_len, 0x8);
            self.exe.buffs.bss.appendNTimesAssumeCapacity({}, next_aligned - prev_len);
            const offset = self.exe.buffs.bss.items.len;
            try self.offsets.putNoClobber(utils.alloc, .{ .file = @truncate(i), .section = .bss }, offset);
            self.exe.buffs.bss.appendNTimesAssumeCapacity({}, unit.program.bss_block.buffer_len);
        }
    }
}

fn mergeSymbols(self: *Linker) LinkerError!void {
    for (self.comp_units, 0..) |unit, i| {
        for (unit.objfile.buffs.symtab.items[1..]) |sym| {
            if (sym.info.bind == .LOCAL) {
                const is_data = sym.shndx == unit.objfile.sections.data.ind;
                const sh_offset = self.offsets.get(.{
                    .file = @truncate(i),
                    .section = switch (sym.info.type) {
                        .FUNC => .text,
                        .OBJECT => if (is_data) .data else .bss,
                        else => continue,
                    },
                }).?;
                const sh_address = switch (sym.info.type) {
                    .FUNC => self.exe.sections.text.vaddr,
                    .OBJECT => if (is_data) self.exe.sections.data.vaddr else self.exe.sections.bss.vaddr,
                    else => unreachable,
                };
                const sym_address = sh_address + sh_offset + sym.value;
                const sym_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.strtab.items[sym.name..], 0);
                try self.locals.putNoClobber(utils.alloc, sym_name, .{
                    .vaddr = sym_address,
                    .shn = switch (sym.info.type) {
                        .FUNC => .text,
                        .OBJECT => if (is_data) .data else .bss,
                        else => unreachable,
                    },
                    .size = @truncate(sym.size),
                });
            } else if (sym.info.bind == .GLOBAL) {
                const is_data = sym.shndx == unit.objfile.sections.data.ind;
                const sh_offset = self.offsets.get(.{
                    .file = @truncate(i),
                    .section = switch (sym.info.type) {
                        .FUNC => .text,
                        .OBJECT => if (is_data) .data else .bss,
                        else => continue,
                    },
                }).?;
                const sh_address = switch (sym.info.type) {
                    .FUNC => self.exe.sections.text.vaddr,
                    .OBJECT => if (is_data) self.exe.sections.data.vaddr else self.exe.sections.bss.vaddr,
                    else => unreachable,
                };
                const sym_address = sh_address + sh_offset + sym.value;
                const sym_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.strtab.items[sym.name..], 0);
                try self.globals.putNoClobber(utils.alloc, sym_name, .{
                    .vaddr = sym_address,
                    .shn = switch (sym.info.type) {
                        .FUNC => .text,
                        .OBJECT => if (is_data) .data else .bss,
                        else => unreachable,
                    },
                    .size = @truncate(sym.size),
                });

                if (unit.program.flags.has_entry and std.mem.eql(u8, sym_name, unit.program.entry)) {
                    self.exe.entry.?.vaddr = sym_address;
                }
            }
        }
    }

    for (self.comp_units) |unit| {
        for (unit.objfile.buffs.symtab.items[1..]) |symbol| {
            if (symbol.shndx == elf.SHN_UNDEF) {
                const sym_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.strtab.items[symbol.name..], 0);
                const is_global = self.globals.contains(sym_name);
                const is_import = self.dyn_funcs.contains(sym_name) or self.dyn_objects.contains(sym_name);
                if (!is_global and !is_import) {
                    utils.printSrcFileErrorFmt("unable to resolve external symbol '{s}'", .{sym_name}, unit.program.file_name);
                    return LinkerError.LinkingFailed;
                }
            }
        }
    }
}

fn patchRelocations(self: *Linker) void {
    for (self.comp_units, 0..) |unit, i| {
        for (unit.objfile.buffs.relatext.items) |rela| {
            const sym = unit.objfile.buffs.symtab.items[rela.info.sym];
            const sym_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.strtab.items[sym.name..], 0);
            const sym_addr: u64 = if (self.locals.get(sym_name)) |symbol|
                symbol.vaddr
            else if (self.globals.get(sym_name)) |symbol|
                symbol.vaddr
            else if (self.dyn_funcs.get(sym_name)) |symbol|
                symbol
            else if (self.dyn_objects.get(sym_name)) |symbol|
                symbol.vaddr
            else
                unreachable;
            const addend = rela.addend;
            const shn_offset = self.offsets.get(.{ .file = @truncate(i), .section = .text }).?;
            const text_offset = shn_offset + rela.offset;
            const reloc_vaddr = self.exe.sections.text.vaddr + text_offset;
            const r_type: elf.R_X86_64 = @enumFromInt(rela.info.type);
            switch (r_type) {
                .@"64" => {
                    const r_value: u64 = sym_addr +% @as(u64, @bitCast(addend));
                    self.exe.patchTextRelocation(text_offset, u64, r_value);
                },
                .@"32" => {
                    const r_value: u32 = @truncate(sym_addr +% @as(u64, @bitCast(addend)));
                    self.exe.patchTextRelocation(text_offset, u32, r_value);
                },
                .@"32S" => {
                    // TODO: Implement
                },
                .PC32, .PLT32 => {
                    const r_value: i32 = @truncate(@as(i64, @bitCast(sym_addr -% reloc_vaddr +% @as(u64, @bitCast(addend)))));
                    self.exe.patchTextRelocation(text_offset, i32, r_value);
                },
                else => unreachable,
            }
        }
    }
}

fn elf_hash(name: []const u8) u32 {
    var h: u32 = 0;
    var g: u32 = undefined;
    for (name) |c| {
        h = (h << 4) + c;
        g = h & 0xF0000000;
        if (g > 0) {
            h ^= g >> 24;
        }
        h &= ~g;
    }
    return h;
}

fn calcHashSection(self: *Linker) void {
    const nbucket: u32 = @truncate(self.exe.buffs.dynsym.items.len);
    const hash = &self.exe.buffs.hash;
    hash.appendSliceAssumeCapacity(&.{ nbucket, nbucket });
    hash.appendNTimesAssumeCapacity(0, hash.capacity - 2);

    var bucket: []u32 = hash.items[2 .. 2 + nbucket];
    var chain: []u32 = hash.items[2 + nbucket ..];

    for (self.exe.buffs.dynsym.items, 0..) |sym, i| {
        const sym_name: []const u8 = std.mem.sliceTo(self.exe.buffs.dynstr.items[sym.name..], 0);
        const x = elf_hash(sym_name);
        const y = x % nbucket;
        if (bucket[y] == 0) {
            bucket[y] = @truncate(i);
        } else {
            var ind: u32 = bucket[y];
            while (chain[ind] != 0) {
                ind = chain[ind];
            }
            chain[ind] = @truncate(i);
        }
    }

    if (!self.flags.quiet) {
        std.debug.print("hash:\n", .{});
        std.debug.print("{d:4} {d:4}\n", .{ hash.items[0], hash.items[1] });
        var i: usize = 0;
        const chain_start = (hash.items.len - 2) / 2 + 2;
        while (i < nbucket) : (i += 1) {
            std.debug.print("{d:4} {d:4}\n", .{ hash.items[i + 2], hash.items[chain_start + i] });
        }
    }
}

fn linkDynamic(self: *Linker) void {
    const dynamic = &self.exe.buffs.dynamic;
    for (self.dyn_libs.items) |lib| {
        const lib_name = self.exe.appendDynstrName(lib);
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_NEEDED, .d_val = lib_name });
    }

    const runpath_name = self.exe.buffs.dynstr.items.len;
    for (self.dyn_runpath.items) |path| {
        self.exe.buffs.dynstr.appendSliceAssumeCapacity(path);
        self.exe.buffs.dynstr.appendAssumeCapacity(':');
    }
    self.exe.buffs.dynstr.items[self.exe.buffs.dynstr.items.len - 1] = 0;

    dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_HASH, .d_val = self.exe.sections.hash.vaddr });
    dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_STRTAB, .d_val = self.exe.sections.dynstr.vaddr });
    dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_SYMTAB, .d_val = self.exe.sections.dynsym.vaddr });
    dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_STRSZ, .d_val = self.exe.sections.dynstr.size });
    dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_SYMENT, .d_val = @sizeOf(elf.Elf64.Sym) });
    dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_DEBUG, .d_val = 0 });
    if (self.exe.has_plt) {
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_PLTGOT, .d_val = self.exe.sections.gotplt.vaddr });
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_PLTRELSZ, .d_val = self.exe.sections.relaplt.size });
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_PLTREL, .d_val = elf.DT_RELA });
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_JMPREL, .d_val = self.exe.sections.relaplt.vaddr });
    }
    if (self.exe.has_copyobj) {
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_RELA, .d_val = self.exe.sections.reladyn.vaddr });
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_RELASZ, .d_val = self.exe.sections.reladyn.size });
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_RELAENT, .d_val = @sizeOf(elf.Elf64.Rela) });
    }
    if (self.dyn_runpath.items.len > 0) {
        dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_RUNPATH, .d_val = runpath_name });
    }
    dynamic.appendAssumeCapacity(.{ .d_tag = elf.DT_NULL, .d_val = 0 });
}

fn incInd(ind: *u8) u8 {
    const prev = ind.*;
    ind.* += 1;
    return prev;
}

fn linkDebugInfo(self: *Linker, ind: *u8) std.mem.Allocator.Error!void {
    const secs = self.exe.sections;
    const buffs = self.exe.buffs;

    var text_addresses: std.ArrayList(u64) = try .initCapacity(utils.alloc, self.comp_units.len);
    defer text_addresses.deinit(utils.alloc);

    _ = text_addresses.addManyAsSliceAssumeCapacity(self.comp_units.len);

    var offs_iter = self.offsets.iterator();
    while (offs_iter.next()) |offset| {
        if (offset.key_ptr.section == .text) {
            text_addresses.items[offset.key_ptr.file] = secs.text.vaddr + offset.value_ptr.*;
        }
    }

    var dstr_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer dstr_map.deinit(utils.alloc);

    var dlstr_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer dlstr_map.deinit(utils.alloc);

    var dstr_size: usize = 0;
    var dlstr_size: usize = 0;
    for (self.comp_units) |unit| {
        var dstr_local: usize = 0;
        const dstr_buf = unit.objfile.buffs.debug_str.items;
        while (dstr_local < dstr_buf.len) {
            const slice: []const u8 = std.mem.sliceTo(dstr_buf[dstr_local..], 0);
            dstr_local += slice.len + 1;

            const res = try dstr_map.getOrPut(utils.alloc, slice);
            if (!res.found_existing) {
                res.value_ptr.* = dstr_size;
                try buffs.debug_str.appendSlice(utils.alloc, slice);
                try buffs.debug_str.append(utils.alloc, 0);
                dstr_size = buffs.debug_str.items.len;
            }
        }

        var dlstr_local: usize = 0;
        const dlstr_buf = unit.objfile.buffs.debug_line_str.items;
        while (dlstr_local < dlstr_buf.len) {
            const slice: []const u8 = std.mem.sliceTo(dlstr_buf[dlstr_local..], 0);
            dlstr_local += slice.len + 1;

            const res = try dlstr_map.getOrPut(utils.alloc, slice);
            if (!res.found_existing) {
                res.value_ptr.* = dlstr_size;
                try buffs.debug_line_str.appendSlice(utils.alloc, slice);
                try buffs.debug_line_str.append(utils.alloc, 0);
                dlstr_size = buffs.debug_line_str.items.len;
            }
        }
    }

    try buffs.debug_abrrev.appendSlice(utils.alloc, self.comp_units[0].objfile.buffs.debug_abbrev.items);

    var dline_size: usize = 0;
    var dinfo_size: usize = 0;
    for (self.comp_units) |unit| {
        dline_size += unit.objfile.buffs.debug_line.items.len;
        dinfo_size += unit.objfile.buffs.debug_info.items.len;
    }
    buffs.debug_line = try .initCapacity(utils.alloc, dline_size);
    buffs.debug_info = try .initCapacity(utils.alloc, dinfo_size);

    for (self.comp_units, 0..) |unit, i| {
        const dl_offset = buffs.debug_line.items.len;
        buffs.debug_line.appendSliceAssumeCapacity(unit.objfile.buffs.debug_line.items);

        for (unit.objfile.buffs.reladebug_line.items) |rela| {
            const sym = unit.objfile.buffs.symtab.items[rela.info.sym];
            const sym_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.strtab.items[sym.name..], 0);
            if (std.mem.eql(u8, sym_name, ".debug_line_str")) {
                const str_offset: u32 = @intCast(rela.addend);
                const str_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.debug_line_str.items[str_offset..], 0);
                const dlstr_offset = dlstr_map.get(str_name).?;
                std.mem.writeInt(u32, @ptrCast(buffs.debug_line.items[dl_offset + rela.offset ..]), @truncate(dlstr_offset), .little);
            } else if (std.mem.eql(u8, sym_name, ".text")) {
                std.mem.writeInt(u64, @ptrCast(buffs.debug_line.items[dl_offset + rela.offset ..]), text_addresses.items[i], .little);
            }
        }

        const di_offset = buffs.debug_info.items.len;
        buffs.debug_info.appendSliceAssumeCapacity(unit.objfile.buffs.debug_info.items);

        for (unit.objfile.buffs.reladebug_info.items) |rela| {
            const sym = unit.objfile.buffs.symtab.items[rela.info.sym];
            const sym_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.strtab.items[sym.name..], 0);
            if (std.mem.eql(u8, sym_name, ".debug_str")) {
                const str_offset: u32 = @intCast(rela.addend);
                const str_name: []const u8 = std.mem.sliceTo(unit.objfile.buffs.debug_str.items[str_offset..], 0);
                const dstr_offset = dstr_map.get(str_name).?;
                std.mem.writeInt(u32, @ptrCast(buffs.debug_info.items[di_offset + rela.offset ..]), @truncate(dstr_offset), .little);
            } else if (std.mem.eql(u8, sym_name, ".debug_line")) {
                std.mem.writeInt(u32, @ptrCast(buffs.debug_info.items[di_offset + rela.offset ..]), @truncate(dl_offset), .little);
            } else if (std.mem.eql(u8, sym_name, ".text")) {
                std.mem.writeInt(u64, @ptrCast(buffs.debug_info.items[di_offset + rela.offset ..]), text_addresses.items[i], .little);
            } else {
                const found_sym = self.locals.get(sym_name) orelse self.globals.get(sym_name) orelse unreachable;
                std.mem.writeInt(u64, @ptrCast(buffs.debug_info.items[di_offset + rela.offset ..]), found_sym.vaddr, .little);
            }
        }
    }

    secs.debug_line.ind = incInd(ind);
    secs.debug_line.offset = secs.bss.offset;
    secs.debug_line.size = buffs.debug_line.items.len;
    secs.debug_line.vaddr = 0;
    secs.debug_line_str.ind = incInd(ind);
    secs.debug_line_str.offset = secs.debug_line.offset + secs.debug_line.size;
    secs.debug_line_str.size = buffs.debug_line_str.items.len;
    secs.debug_line_str.vaddr = 0;
    secs.debug_info.ind = incInd(ind);
    secs.debug_info.offset = secs.debug_line_str.offset + secs.debug_line_str.size;
    secs.debug_info.size = buffs.debug_info.items.len;
    secs.debug_info.vaddr = 0;
    secs.debug_abrrev.ind = incInd(ind);
    secs.debug_abrrev.offset = secs.debug_info.offset + secs.debug_info.size;
    secs.debug_abrrev.size = buffs.debug_abrrev.items.len;
    secs.debug_abrrev.vaddr = 0;
    secs.debug_str.ind = incInd(ind);
    secs.debug_str.offset = secs.debug_abrrev.offset + secs.debug_abrrev.size;
    secs.debug_str.size = buffs.debug_str.items.len;
    secs.debug_str.vaddr = 0;
}

fn shdrTable(self: *Linker, ind: *u8) LinkerError!void {
    const secs = self.exe.sections;
    const buffs = self.exe.buffs;

    try buffs.strtab.append(utils.alloc, 0);
    try buffs.symtab.append(utils.alloc, elf.Elf64.Sym{ .name = 0, .info = .{ .bind = .LOCAL, .type = .NOTYPE }, .other = .{ .visibility = .DEFAULT }, .shndx = 0, .value = 0, .size = 0 });

    secs.symtab.ind = incInd(ind);
    secs.symtab.vaddr = 0;
    secs.symtab.offset = std.mem.alignForward(usize, secs.debug_str.offset + secs.debug_str.size, 0x8);

    var l_iter = self.locals.iterator();
    while (l_iter.next()) |sym| {
        const shn_ind: u8 = switch (sym.value_ptr.shn) {
            .text => secs.text.ind,
            .data => secs.data.ind,
            .bss => secs.bss.ind,
        };
        try buffs.symtab.append(utils.alloc, .{
            .name = try self.exe.appendStrtabName(sym.key_ptr.*),
            .info = .{ .bind = .LOCAL, .type = switch (sym.value_ptr.shn) {
                .text => .FUNC,
                .data, .bss => .OBJECT,
            } },
            .other = .{ .visibility = .DEFAULT },
            .shndx = shn_ind,
            .value = sym.value_ptr.vaddr,
            .size = sym.value_ptr.size,
        });
    }
    if (self.exe.has_dynamic) {
        try buffs.symtab.append(utils.alloc, .{
            .name = try self.exe.appendStrtabName("_DYNAMIC"),
            .info = .{ .bind = .LOCAL, .type = .OBJECT },
            .other = .{ .visibility = .DEFAULT },
            .shndx = secs.dynamic.ind,
            .value = secs.dynamic.vaddr,
            .size = 0,
        });
        if (self.exe.has_copyobj or self.exe.has_plt) {
            try buffs.symtab.append(utils.alloc, .{
                .name = try self.exe.appendStrtabName("_GLOBAL_OFFSET_TABLE"),
                .info = .{ .bind = .LOCAL, .type = .OBJECT },
                .other = .{ .visibility = .DEFAULT },
                .shndx = if (secs.gotplt.ind > 0) secs.gotplt.ind else secs.bss.ind,
                .value = secs.gotplt.vaddr,
                .size = 0,
            });
        }
    }

    self.exe.symtab_info = @truncate(buffs.symtab.items.len);

    var g_iter = self.globals.iterator();
    while (g_iter.next()) |sym| {
        const shn_ind: u8 = switch (sym.value_ptr.shn) {
            .text => secs.text.ind,
            .data => secs.data.ind,
            .bss => secs.bss.ind,
        };
        try buffs.symtab.append(utils.alloc, .{
            .name = try self.exe.appendStrtabName(sym.key_ptr.*),
            .info = .{ .bind = .GLOBAL, .type = switch (sym.value_ptr.shn) {
                .text => .FUNC,
                .data, .bss => .OBJECT,
            } },
            .other = .{ .visibility = .DEFAULT },
            .shndx = shn_ind,
            .value = sym.value_ptr.vaddr,
            .size = sym.value_ptr.size,
        });
    }
    if (self.exe.has_dynamic) {
        for (buffs.dynsym.items[1..]) |sym| {
            const sym_name: []const u8 = std.mem.sliceTo(buffs.dynstr.items[sym.name..], 0);
            var sym_copy = sym;
            sym_copy.name = try self.exe.appendStrtabName(sym_name);
            try buffs.symtab.append(utils.alloc, sym_copy);
        }
    }

    secs.symtab.size = buffs.symtab.items.len * @sizeOf(elf.Elf64.Sym);

    secs.strtab.ind = incInd(ind);
    secs.strtab.offset = secs.symtab.offset + secs.symtab.size;
    secs.strtab.size = buffs.strtab.items.len;
    secs.strtab.vaddr = 0;
}

fn shstrtabLoad(self: *Linker, ind: *u8) LinkerError!void {
    const secs = self.exe.sections;
    try self.exe.buffs.shstrtab.append(utils.alloc, 0);

    if (self.exe.has_plt) {
        secs.plt.name = try self.exe.appendShstrtabName(".plt");
    }
    secs.text.name = try self.exe.appendShstrtabName(".text");
    if (self.exe.has_dynamic) {
        secs.interp.name = try self.exe.appendShstrtabName(".interp");
        secs.hash.name = try self.exe.appendShstrtabName(".hash");
        secs.dynsym.name = try self.exe.appendShstrtabName(".dynsym");
        secs.dynstr.name = try self.exe.appendShstrtabName(".dynstr");
        if (self.exe.has_copyobj) {
            secs.reladyn.name = try self.exe.appendShstrtabName(".rela.dyn");
        }
        if (self.exe.has_plt) {
            secs.relaplt.name = try self.exe.appendShstrtabName(".rela.plt");
        }
        secs.dynamic.name = try self.exe.appendShstrtabName(".dynamic");
        if (self.exe.has_plt) {
            secs.gotplt.name = try self.exe.appendShstrtabName(".got.plt");
        }
    }
    if (self.exe.has_data) {
        secs.data.name = try self.exe.appendShstrtabName(".data");
    }
    if (self.exe.has_bss) {
        secs.bss.name = try self.exe.appendShstrtabName(".bss");
    }
    if (self.flags.debug) {
        secs.debug_line.name = try self.exe.appendShstrtabName(".debug_line");
        secs.debug_line_str.name = try self.exe.appendShstrtabName(".debug_line_str");
        secs.debug_info.name = try self.exe.appendShstrtabName(".debug_info");
        secs.debug_abrrev.name = try self.exe.appendShstrtabName(".debug_abbrev");
        secs.debug_str.name = try self.exe.appendShstrtabName(".debug_str");
    }

    secs.symtab.name = try self.exe.appendShstrtabName(".symtab");
    secs.strtab.name = try self.exe.appendShstrtabName(".strtab");
    secs.shstrtab.name = try self.exe.appendShstrtabName(".shstrtab");

    secs.shstrtab.ind = incInd(ind);
    secs.shstrtab.vaddr = 0;
    secs.shstrtab.size = self.exe.buffs.shstrtab.items.len;
    secs.shstrtab.offset = secs.strtab.offset + secs.strtab.size;
}

fn calcSectionsInfo(self: *Linker) LinkerError!void {
    const secs = self.exe.sections;
    const phdrs = self.exe.phdrs;
    const buffs = self.exe.buffs;

    const funcs = self.dyn_funcs.count();
    const objects = self.dyn_objects.count();

    var ind: u8 = 1;
    var vaddress: u64 = 0x400000;

    const phdr_count: u64 = if (self.exe.has_dynamic) 6 else if (self.exe.has_data) 3 else 2;

    phdrs.phdr = .{
        .type = .PHDR,
        .flags = .{ .R = true },
        .offset = @sizeOf(elf.Elf64.Ehdr),
        .vaddr = vaddress + @sizeOf(elf.Elf64.Ehdr),
        .paddr = vaddress + @sizeOf(elf.Elf64.Ehdr),
        .filesz = phdr_count * @sizeOf(elf.Elf64.Phdr),
        .memsz = phdr_count * @sizeOf(elf.Elf64.Phdr),
        .@"align" = 0x8,
    };

    secs.plt.offset = std.mem.alignForward(u64, phdrs.phdr.offset + phdrs.phdr.filesz, 0x10);
    if (self.exe.has_plt) {
        secs.plt.ind = incInd(&ind);
        secs.plt.size = (funcs + 1) * 16;
        secs.plt.vaddr = vaddress + secs.plt.offset;
    }

    var text_size: usize = 0;
    for (self.comp_units) |unit| {
        if (unit.program.flags.has_code) {
            const tsize = unit.objfile.buffs.text.items.len;
            text_size = std.mem.alignForward(usize, text_size, 0x10);
            text_size += tsize;
        }
    }

    secs.text.ind = incInd(&ind);
    secs.text.offset = secs.plt.offset + secs.plt.size;
    secs.text.size = text_size;
    secs.text.vaddr = vaddress + secs.text.offset;

    phdrs.rx = .{
        .type = .LOAD,
        .flags = .{ .R = true, .X = true },
        .offset = 0,
        .vaddr = vaddress,
        .paddr = vaddress,
        .filesz = secs.text.offset + secs.text.size,
        .memsz = secs.text.offset + secs.text.size,
        .@"align" = 0x1000,
    };

    var bss_size: usize = 0;

    if (self.exe.has_dynamic) {
        secs.interp.ind = incInd(&ind);
        // secs.interp.offset = std.mem.alignForward(u64, secs.text.offset + secs.text.size, 0x1000);
        secs.interp.offset = secs.text.offset + secs.text.size;
        vaddress += 0x1000;
        try buffs.interp.appendSlice(utils.alloc, "/lib64/ld-linux-x86-64.so.2");
        try buffs.interp.append(utils.alloc, 0);
        secs.interp.size = buffs.interp.items.len;
        secs.interp.vaddr = vaddress + secs.interp.offset;

        phdrs.interp = .{
            .type = .INTERP,
            .flags = .{ .R = true },
            .offset = secs.interp.offset,
            .vaddr = secs.interp.vaddr,
            .paddr = secs.interp.vaddr,
            .filesz = secs.interp.size,
            .memsz = secs.interp.size,
            .@"align" = 0x1,
        };

        secs.hash.ind = incInd(&ind);
        secs.hash.offset = std.mem.alignForward(u64, secs.interp.offset + secs.interp.size, 0x8);
        secs.hash.size = 2 * (funcs + objects + 1 + 1) * @sizeOf(u32);
        secs.hash.vaddr = vaddress + secs.hash.offset;

        secs.dynsym.ind = incInd(&ind);
        secs.dynsym.offset = std.mem.alignForward(u64, secs.hash.offset + secs.hash.size, 0x8);
        secs.dynsym.size = (funcs + objects + 1) * @sizeOf(elf.Elf64.Sym);
        secs.dynsym.vaddr = vaddress + secs.dynsym.offset;

        var dynstr_size: usize = 1;
        var dynfuncs_iter = self.dyn_funcs.iterator();
        while (dynfuncs_iter.next()) |sym| {
            dynstr_size += sym.key_ptr.len + 1;
        }
        var objgot: usize = 0;
        var dynobjects_iter = self.dyn_objects.iterator();
        while (dynobjects_iter.next()) |sym| {
            dynstr_size += sym.key_ptr.len + 1;
            switch (sym.value_ptr.info.section) {
                .wdata => {
                    objgot += 1;
                    bss_size = std.mem.alignForward(usize, bss_size, 0x8);
                    bss_size += sym.value_ptr.info.size;
                },
                .rodata => {}, // TODO: put in .got
            }
        }
        for (self.dyn_libs.items) |lib| {
            dynstr_size += lib.len + 1;
        }
        for (self.dyn_runpath.items) |path| {
            dynstr_size += path.len + 1;
        }

        secs.dynstr.ind = incInd(&ind);
        secs.dynstr.offset = secs.dynsym.offset + secs.dynsym.size;
        secs.dynstr.size = dynstr_size;
        secs.dynstr.vaddr = vaddress + secs.dynstr.offset;

        secs.reladyn.offset = std.mem.alignForward(u64, secs.dynstr.offset + secs.dynstr.size, 0x8);
        secs.reladyn.size = objects * @sizeOf(elf.Elf64.Rela);
        if (self.exe.has_copyobj) {
            secs.reladyn.ind = incInd(&ind);
            secs.reladyn.vaddr = vaddress + secs.reladyn.offset;
        }

        secs.relaplt.offset = std.mem.alignForward(u64, secs.reladyn.offset + secs.reladyn.size, 0x8);
        secs.relaplt.size = funcs * @sizeOf(elf.Elf64.Rela);
        if (self.exe.has_plt) {
            secs.relaplt.ind = incInd(&ind);
            secs.relaplt.vaddr = vaddress + secs.relaplt.offset;
        }

        phdrs.r = .{
            .type = .LOAD,
            .flags = .{ .R = true },
            .offset = secs.interp.offset,
            .vaddr = secs.interp.vaddr,
            .paddr = secs.interp.vaddr,
            .filesz = secs.relaplt.offset + secs.relaplt.size - secs.interp.offset,
            .memsz = secs.relaplt.offset + secs.relaplt.size - secs.interp.offset,
            .@"align" = 0x1000,
        };

        secs.dynamic.ind = incInd(&ind);
        secs.dynamic.offset = std.mem.alignForward(u64, secs.relaplt.offset + secs.relaplt.size, 0x8);
        vaddress += 0x1000;
        secs.dynamic.size = (7 + self.dyn_libs.items.len) * @sizeOf(elf.Elf64_Dyn);
        if (self.exe.has_plt) {
            secs.dynamic.size += 4 * @sizeOf(elf.Elf64_Dyn);
        }
        if (self.exe.has_copyobj) {
            secs.dynamic.size += 3 * @sizeOf(elf.Elf64_Dyn);
        }
        if (self.dyn_runpath.items.len > 0) {
            secs.dynamic.size += @sizeOf(elf.Elf64_Dyn);
        }
        secs.dynamic.vaddr = vaddress + secs.dynamic.offset;
        phdrs.dynamic = .{
            .type = .DYNAMIC,
            .flags = .{ .R = true, .W = true },
            .offset = secs.dynamic.offset,
            .vaddr = secs.dynamic.vaddr,
            .paddr = secs.dynamic.vaddr,
            .filesz = secs.dynamic.size,
            .memsz = secs.dynamic.size,
            .@"align" = 0x8,
        };

        secs.gotplt.offset = std.mem.alignForward(u64, secs.dynamic.offset + secs.dynamic.size, 0x8);
        if (self.exe.has_plt) {
            secs.gotplt.ind = incInd(&ind);
            secs.gotplt.size = (3 + funcs) * 8;
            secs.gotplt.vaddr = vaddress + secs.gotplt.offset;
        }
    } else {
        // secs.dynamic.offset = std.mem.alignForward(u64, secs.text.offset + secs.text.size, 0x1000);
        secs.dynamic.offset = secs.text.offset + secs.text.size;
        vaddress += 0x1000;
        secs.dynamic.vaddr = vaddress + secs.dynamic.offset;
        secs.gotplt.offset = secs.dynamic.offset;
    }

    secs.data.offset = std.mem.alignForward(u64, secs.gotplt.offset + secs.gotplt.size, 0x8);
    var data_size: usize = 0;
    for (self.comp_units) |unit| {
        if (unit.program.flags.has_data) {
            const dsize = unit.objfile.buffs.data.items.len;
            data_size = std.mem.alignForward(usize, data_size, 0x8);
            data_size += dsize;
        }
        if (unit.program.flags.has_bss) {
            const bsize = unit.program.bss_block.buffer_len;
            bss_size = std.mem.alignForward(usize, bss_size, 0x8);
            bss_size += bsize;
        }
    }
    secs.data.size = data_size;
    if (self.exe.has_data) {
        secs.data.ind = incInd(&ind);
        secs.data.vaddr = vaddress + secs.data.offset;
    }

    secs.bss.offset = secs.data.offset + secs.data.size;
    secs.bss.size = bss_size;
    if (self.exe.has_bss or self.exe.has_copyobj) {
        secs.bss.ind = incInd(&ind);
        secs.bss.vaddr = std.mem.alignForward(u64, vaddress + secs.bss.offset, 0x8);
    }

    phdrs.rw = .{
        .type = .LOAD,
        .flags = .{ .R = true, .W = true },
        .offset = secs.dynamic.offset,
        .vaddr = secs.dynamic.vaddr,
        .paddr = secs.dynamic.vaddr,
        .filesz = secs.data.offset + secs.data.size - secs.dynamic.offset,
        .memsz = if (secs.bss.size > 0) secs.bss.vaddr + secs.bss.size - secs.dynamic.vaddr else secs.data.offset + secs.data.size - secs.dynamic.offset,
        .@"align" = 0x1000,
    };

    buffs.bss = try .initCapacity(utils.alloc, bss_size);

    if (self.exe.has_dynamic) {
        buffs.dynsym = try .initCapacity(utils.alloc, self.exe.sections.dynsym.size / @sizeOf(elf.Elf64.Sym));
        buffs.dynsym.appendAssumeCapacity(elf.Elf64.Sym{ .name = 0, .info = .{ .bind = .LOCAL, .type = .NOTYPE }, .other = .{ .visibility = .DEFAULT }, .shndx = 0, .value = 0, .size = 0 });
        buffs.dynstr = try .initCapacity(utils.alloc, self.exe.sections.dynstr.size);
        buffs.dynstr.appendAssumeCapacity(0);

        if (self.exe.has_plt) {
            buffs.plt = try .initCapacity(utils.alloc, self.exe.sections.plt.size);
            buffs.gotplt = try .initCapacity(utils.alloc, self.exe.sections.gotplt.size / @sizeOf(u64));
            buffs.relaplt = try .initCapacity(utils.alloc, self.exe.sections.relaplt.size / @sizeOf(elf.Elf64.Rela));
            self.linkPlt();
        }

        if (self.exe.has_copyobj) {
            buffs.reladyn = try .initCapacity(utils.alloc, self.exe.sections.reladyn.size / @sizeOf(elf.Elf64.Rela));
            self.linkGot();
        }
    }

    buffs.text = try .initCapacity(utils.alloc, self.exe.sections.text.size);
    buffs.data = try .initCapacity(utils.alloc, self.exe.sections.data.size);
    try self.mergeTextDataBss();

    try self.mergeSymbols();
    self.patchRelocations();

    if (self.exe.has_dynamic) {
        buffs.hash = try .initCapacity(utils.alloc, self.exe.sections.hash.size / @sizeOf(u32));
        self.calcHashSection();

        buffs.dynamic = try .initCapacity(utils.alloc, self.exe.sections.dynamic.size);
        self.linkDynamic();
    }

    if (self.exe.has_debug) {
        try self.linkDebugInfo(&ind);
    } else {
        secs.debug_str.offset = secs.bss.offset;
    }

    if (self.exe.has_shtable) {
        try self.shdrTable(&ind);
        try self.shstrtabLoad(&ind);
    } else {
        secs.shstrtab.offset = secs.debug_str.offset;
    }

    if (!self.flags.quiet) {
        self.printBuffers();
        self.printDynstr();
        self.printDynsym();
        self.printRelas();
        self.printFuncsObjects();
        self.printSymbols();
        self.printStrtab();
        self.printSymtab();
        secs.print();
        phdrs.print();
    }
}

fn linkExe(self: *Linker) LinkerError!void {
    if (self.exe.has_dynamic) {
        var dyn_libs: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
        defer dyn_libs.deinit(utils.alloc);

        for (self.comp_units) |unit| {
            if (unit.program.flags.has_shared) {
                var imp_iter = unit.program.imports.iterator();
                while (imp_iter.next()) |import| {
                    const ind = import.value_ptr.*;
                    if (ind > 0) {
                        const lib_name = unit.program.shared_libs.items[ind];
                        const res = try dyn_libs.getOrPut(utils.alloc, lib_name);
                        if (!res.found_existing) {
                            res.value_ptr.* = .empty;
                        }
                        _ = try res.value_ptr.getOrPut(utils.alloc, import.key_ptr.*);
                    }
                }
            }
        }

        var lib_iter = dyn_libs.iterator();
        while (lib_iter.next()) |lib| {
            defer lib.value_ptr.deinit(utils.alloc);

            const lib_name = lib.key_ptr.*;
            const lib_fullname = try resolveLibFileName(lib_name);
            defer utils.alloc.free(lib_fullname);
            // std.debug.print("Try to find library: '{s}' -> '{s}'\n", .{ lib_name, lib_fullname });
            var dyn_lib = try self.findLib(lib_fullname);
            defer dyn_lib.close();

            try self.dyn_libs.append(utils.alloc, dyn_lib.resolved_name);
            // std.debug.print("Found library '{s}'\n", .{dyn_lib.resolved_name});

            var sym_iter = lib.value_ptr.iterator();
            while (sym_iter.next()) |sym| {
                const sym_name = sym.key_ptr.*;
                const opt_syminfo = dyn_lib.lookup(sym_name);
                if (opt_syminfo) |syminfo| {
                    switch (syminfo) {
                        .func => {
                            try self.dyn_funcs.putNoClobber(utils.alloc, sym_name, undefined);
                            self.exe.has_plt = true;
                        },
                        .obj => {
                            try self.dyn_objects.putNoClobber(utils.alloc, sym_name, .{ .info = syminfo.obj, .vaddr = undefined });
                            if (syminfo.obj.section == .wdata) {
                                self.exe.has_copyobj = true;
                            }
                        },
                    }
                } else {
                    utils.printErrorFmt("imported symbol '{s}' is not found in '{s}' library", .{ sym_name, lib_name });
                    return LinkerError.LinkingFailed;
                }
            }
        }
    }

    try self.calcSectionsInfo();
}

pub fn linkObjects(self: *Linker) LinkerError!void {
    var with_code = false;
    for (self.comp_units) |unit| {
        if (unit.program.flags.has_entry) {
            if (self.exe.entry == null) {
                self.exe.entry = .{ .name = unit.program.entry, .vaddr = undefined };
            } else {
                utils.printError("multiple entry point definition");
                return LinkerError.LinkingFailed;
            }
        }
        if (unit.program.flags.has_data) {
            self.exe.has_data = true;
        }
        if (unit.program.flags.has_code) {
            with_code = true;
        }
        if (unit.program.flags.has_shared) {
            self.exe.has_dynamic = true;
        }
        if (unit.program.flags.has_bss) {
            self.exe.has_bss = true;
        }
    }

    if (self.exe.entry == null) {
        utils.printError("none of source files contains entry point definition");
        return LinkerError.LinkingFailed;
    } else if (!with_code) {
        utils.printError("none of source files contains executable code block");
        return LinkerError.LinkingFailed;
    }

    try self.linkExe();
    try self.writeExe();
}

pub fn writeExe(self: *Linker) LinkerError!void {
    const secs = self.exe.sections;
    const buffs = self.exe.buffs;

    const shtable = std.mem.alignForward(usize, secs.shstrtab.offset + secs.shstrtab.size, 0x8);
    const file_size = shtable + @as(usize, (secs.shstrtab.ind + 1)) * @sizeOf(elf.Elf64.Shdr);

    const file_buffer = try utils.alloc.alloc(u8, file_size);
    defer utils.alloc.free(file_buffer);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(utils.io, self.exe.output_name, .{});
    try file.setPermissions(utils.io, std.Io.File.Permissions.executable_file);
    defer file.close(utils.io);

    var file_writer = file.writer(utils.io, file_buffer);
    const writer = &file_writer.interface;

    try writer.writeStruct(elf.Elf64.Ehdr{
        .ident = [_]u8{ elf.MAGIC[0], elf.MAGIC[1], elf.MAGIC[2], elf.MAGIC[3], elf.ELFCLASS64, elf.ELFDATA2LSB, 1, @intFromEnum(elf.OSABI.GNU), 0, 0, 0, 0, 0, 0, 0, 0 },
        .type = elf.ET.EXEC,
        .machine = elf.EM.X86_64,
        .version = 1,
        .entry = self.exe.entry.?.vaddr,
        .phoff = @sizeOf(elf.Elf64.Ehdr),
        .shoff = if (self.exe.has_shtable) shtable else 0,
        .flags = 0,
        .ehsize = @sizeOf(elf.Elf64.Ehdr),
        .phentsize = @sizeOf(elf.Elf64.Phdr),
        .phnum = @as(u16, if (self.exe.has_dynamic) 6 else if (self.exe.has_data) 3 else 2),
        .shentsize = if (self.exe.has_shtable) @sizeOf(elf.Elf64.Shdr) else 0,
        .shnum = if (self.exe.has_shtable) secs.shstrtab.ind + 1 else 0,
        .shstrndx = secs.shstrtab.ind,
    }, .little);

    try writer.writeStruct(self.exe.phdrs.phdr, .little);
    if (self.exe.has_dynamic) {
        try writer.writeStruct(self.exe.phdrs.interp, .little);
    }
    try writer.writeStruct(self.exe.phdrs.rx, .little);
    if (self.exe.has_dynamic) {
        try writer.writeStruct(self.exe.phdrs.r, .little);
    }
    if (self.exe.has_dynamic or self.exe.has_data) {
        try writer.writeStruct(self.exe.phdrs.rw, .little);
    }
    if (self.exe.has_dynamic) {
        try writer.writeStruct(self.exe.phdrs.dynamic, .little);
    }

    var padding: usize = 0;
    if (self.exe.has_plt) {
        padding = secs.plt.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.plt.items);
    }
    padding = secs.text.offset - writer.end;
    _ = try writer.splatByte(0, padding);
    _ = try writer.write(buffs.text.items);

    if (self.exe.has_dynamic) {
        padding = secs.interp.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.interp.items);

        padding = secs.hash.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        for (buffs.hash.items) |int| {
            try writer.writeInt(u32, int, .little);
        }

        padding = secs.dynsym.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        for (buffs.dynsym.items) |sym| {
            try writer.writeStruct(sym, .little);
        }

        padding = secs.dynstr.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.dynstr.items);

        if (self.exe.has_copyobj) {
            padding = secs.reladyn.offset - writer.end;
            _ = try writer.splatByte(0, padding);
            for (buffs.reladyn.items) |rela| {
                try writer.writeStruct(rela, .little);
            }
        }

        if (self.exe.has_plt) {
            padding = secs.relaplt.offset - writer.end;
            _ = try writer.splatByte(0, padding);
            for (buffs.relaplt.items) |rela| {
                try writer.writeStruct(rela, .little);
            }
        }

        padding = secs.dynamic.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        for (buffs.dynamic.items) |dyn| {
            try writer.writeStruct(dyn, .little);
        }

        if (self.exe.has_plt) {
            padding = secs.gotplt.offset - writer.end;
            _ = try writer.splatByte(0, padding);
            for (buffs.gotplt.items) |addr| {
                try writer.writeInt(u64, addr, .little);
            }
        }
    }

    if (self.exe.has_data) {
        padding = secs.data.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.data.items);
    }

    if (self.exe.has_debug) {
        _ = try writer.write(buffs.debug_line.items);
        _ = try writer.write(buffs.debug_line_str.items);
        _ = try writer.write(buffs.debug_info.items);
        _ = try writer.write(buffs.debug_abrrev.items);
        _ = try writer.write(buffs.debug_str.items);
    }

    if (self.exe.has_shtable) {
        padding = secs.symtab.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        for (buffs.symtab.items) |sym| {
            try writer.writeStruct(sym, .little);
        }

        padding = secs.strtab.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.strtab.items);

        padding = secs.shstrtab.offset - writer.end;
        _ = try writer.splatByte(0, padding);
        _ = try writer.write(buffs.shstrtab.items);

        padding = shtable - writer.end;
        _ = try writer.splatByte(0, padding);

        try writer.writeStruct(elf.Elf64.Shdr{
            .name = 0,
            .type = .NULL,
            .addr = 0,
            .addralign = 0,
            .entsize = 0,
            .flags = .{ .shf = .{} },
            .info = 0,
            .link = 0,
            .offset = 0,
            .size = 0,
        }, .little);
        if (self.exe.has_plt) {
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.plt.name,
                .type = .PROGBITS,
                .addr = secs.plt.vaddr,
                .addralign = 0x10,
                .entsize = 0x10,
                .flags = .{ .shf = .{ .ALLOC = true, .EXECINSTR = true } },
                .info = 0,
                .link = 0,
                .offset = secs.plt.offset,
                .size = secs.plt.size,
            }, .little);
        }
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.text.name,
            .type = .PROGBITS,
            .addr = secs.text.vaddr,
            .addralign = 0x10,
            .entsize = 0x10,
            .flags = .{ .shf = .{ .ALLOC = true, .EXECINSTR = true } },
            .info = 0,
            .link = 0,
            .offset = secs.text.offset,
            .size = secs.text.size,
        }, .little);
        if (self.exe.has_dynamic) {
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.interp.name,
                .type = .PROGBITS,
                .addr = secs.interp.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{ .ALLOC = true } },
                .info = 0,
                .link = 0,
                .offset = secs.interp.offset,
                .size = secs.interp.size,
            }, .little);
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.hash.name,
                .type = .HASH,
                .addr = secs.hash.vaddr,
                .addralign = 0x8,
                .entsize = 0,
                .flags = .{ .shf = .{ .ALLOC = true } },
                .info = 0,
                .link = secs.dynsym.ind,
                .offset = secs.hash.offset,
                .size = secs.hash.size,
            }, .little);
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.dynsym.name,
                .type = .DYNSYM,
                .addr = secs.dynsym.vaddr,
                .addralign = 0x8,
                .entsize = @sizeOf(elf.Elf64.Sym),
                .flags = .{ .shf = .{ .ALLOC = true } },
                .info = 1,
                .link = secs.dynstr.ind,
                .offset = secs.dynsym.offset,
                .size = secs.dynsym.size,
            }, .little);
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.dynstr.name,
                .type = .STRTAB,
                .addr = secs.dynstr.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{ .ALLOC = true } },
                .info = 0,
                .link = 0,
                .offset = secs.dynstr.offset,
                .size = secs.dynstr.size,
            }, .little);
            if (self.exe.has_copyobj) {
                try writer.writeStruct(elf.Elf64.Shdr{
                    .name = secs.reladyn.name,
                    .type = .RELA,
                    .addr = secs.reladyn.vaddr,
                    .addralign = 0x8,
                    .entsize = @sizeOf(elf.Elf64.Rela),
                    .flags = .{ .shf = .{ .ALLOC = true } },
                    .info = 0,
                    .link = secs.dynsym.ind,
                    .offset = secs.reladyn.offset,
                    .size = secs.reladyn.size,
                }, .little);
            }
            if (self.exe.has_plt) {
                try writer.writeStruct(elf.Elf64.Shdr{
                    .name = secs.relaplt.name,
                    .type = .RELA,
                    .addr = secs.relaplt.vaddr,
                    .addralign = 0x8,
                    .entsize = @sizeOf(elf.Elf64.Rela),
                    .flags = .{ .shf = .{ .ALLOC = true, .INFO_LINK = true } },
                    .info = secs.gotplt.ind,
                    .link = secs.dynsym.ind,
                    .offset = secs.relaplt.offset,
                    .size = secs.relaplt.size,
                }, .little);
            }
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.dynamic.name,
                .type = .DYNAMIC,
                .addr = secs.dynamic.vaddr,
                .addralign = 0x8,
                .entsize = @sizeOf(elf.Elf64_Dyn),
                .flags = .{ .shf = .{ .ALLOC = true, .WRITE = true } },
                .info = 0,
                .link = secs.dynstr.ind,
                .offset = secs.dynamic.offset,
                .size = secs.dynamic.size,
            }, .little);
            if (self.exe.has_plt) {
                try writer.writeStruct(elf.Elf64.Shdr{
                    .name = secs.gotplt.name,
                    .type = .PROGBITS,
                    .addr = secs.gotplt.vaddr,
                    .addralign = 0x8,
                    .entsize = @sizeOf(u64),
                    .flags = .{ .shf = .{ .ALLOC = true, .WRITE = true } },
                    .info = 0,
                    .link = 0,
                    .offset = secs.gotplt.offset,
                    .size = secs.gotplt.size,
                }, .little);
            }
        }

        if (self.exe.has_data) {
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.data.name,
                .type = .PROGBITS,
                .addr = secs.data.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{ .ALLOC = true, .WRITE = true } },
                .info = 0,
                .link = 0,
                .offset = secs.data.offset,
                .size = secs.data.size,
            }, .little);
        }
        if (self.exe.has_bss) {
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.bss.name,
                .type = .NOBITS,
                .addr = secs.bss.vaddr,
                .addralign = 0x8,
                .entsize = 0,
                .flags = .{ .shf = .{ .ALLOC = true, .WRITE = true } },
                .info = 0,
                .link = 0,
                .offset = secs.bss.offset,
                .size = secs.bss.size,
            }, .little);
        }
        if (self.exe.has_debug) {
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.debug_line.name,
                .type = .PROGBITS,
                .addr = secs.debug_line.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{} },
                .info = 0,
                .link = 0,
                .offset = secs.debug_line.offset,
                .size = secs.debug_line.size,
            }, .little);
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.debug_line_str.name,
                .type = .PROGBITS,
                .addr = secs.debug_line_str.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{} },
                .info = 0,
                .link = 0,
                .offset = secs.debug_line_str.offset,
                .size = secs.debug_line_str.size,
            }, .little);
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.debug_info.name,
                .type = .PROGBITS,
                .addr = secs.debug_info.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{} },
                .info = 0,
                .link = 0,
                .offset = secs.debug_info.offset,
                .size = secs.debug_info.size,
            }, .little);
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.debug_abrrev.name,
                .type = .PROGBITS,
                .addr = secs.debug_abrrev.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{} },
                .info = 0,
                .link = 0,
                .offset = secs.debug_abrrev.offset,
                .size = secs.debug_abrrev.size,
            }, .little);
            try writer.writeStruct(elf.Elf64.Shdr{
                .name = secs.debug_str.name,
                .type = .PROGBITS,
                .addr = secs.debug_str.vaddr,
                .addralign = 0x1,
                .entsize = 0,
                .flags = .{ .shf = .{} },
                .info = 0,
                .link = 0,
                .offset = secs.debug_str.offset,
                .size = secs.debug_str.size,
            }, .little);
        }
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.symtab.name,
            .type = .SYMTAB,
            .addr = secs.symtab.vaddr,
            .addralign = 0x8,
            .entsize = @sizeOf(elf.Elf64.Sym),
            .flags = .{ .shf = .{} },
            .info = self.exe.symtab_info,
            .link = secs.strtab.ind,
            .offset = secs.symtab.offset,
            .size = secs.symtab.size,
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.strtab.name,
            .type = .STRTAB,
            .addr = secs.strtab.vaddr,
            .addralign = 0x1,
            .entsize = 0,
            .flags = .{ .shf = .{} },
            .info = 0,
            .link = 0,
            .offset = secs.strtab.offset,
            .size = secs.strtab.size,
        }, .little);
        try writer.writeStruct(elf.Elf64.Shdr{
            .name = secs.shstrtab.name,
            .type = .STRTAB,
            .addr = secs.shstrtab.vaddr,
            .addralign = 0x1,
            .entsize = 0,
            .flags = .{ .shf = .{} },
            .info = 0,
            .link = 0,
            .offset = secs.shstrtab.offset,
            .size = secs.shstrtab.size,
        }, .little);
    }

    try writer.flush();
}

pub fn deinit(self: *Linker) void {
    for (self.dyn_libs.items) |lib| {
        utils.alloc.free(lib);
    }
    self.dyn_libs.deinit(utils.alloc);
    self.dyn_funcs.deinit(utils.alloc);
    self.dyn_objects.deinit(utils.alloc);
    self.dyn_runpath.deinit(utils.alloc);
    self.offsets.deinit(utils.alloc);
    self.locals.deinit(utils.alloc);
    self.globals.deinit(utils.alloc);
    self.exe.deinit();
}
