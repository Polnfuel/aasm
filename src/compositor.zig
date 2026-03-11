const std = @import("std");
const parser = @import("parser");
const codegen = @import("codegen");
const datagen = @import("datagen");

const elf = std.elf;

fn writeU16(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), number: u16) !void {
    try buffer.append(allocator, @truncate(number));
    try buffer.append(allocator, @truncate(number >> 8));
}

fn writeU32(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), number: u32) !void {
    try buffer.append(allocator, @truncate(number));
    try buffer.append(allocator, @truncate(number >> 8));
    try buffer.append(allocator, @truncate(number >> 16));
    try buffer.append(allocator, @truncate(number >> 24));
}

fn writeU64(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), number: u64) !void {
    try buffer.append(allocator, @truncate(number));
    try buffer.append(allocator, @truncate(number >> 8));
    try buffer.append(allocator, @truncate(number >> 16));
    try buffer.append(allocator, @truncate(number >> 24));
    try buffer.append(allocator, @truncate(number >> 32));
    try buffer.append(allocator, @truncate(number >> 40));
    try buffer.append(allocator, @truncate(number >> 48));
    try buffer.append(allocator, @truncate(number >> 56));
}

pub fn genELF(allocator: std.mem.Allocator, file_name: []const u8) !void {
    const data_len: usize = datagen.data_buffer.items.len;
    const data_virt_address: u64 = codegen.data_virt_address;
    const code_len: usize = codegen.code_buffer.items.len;
    const code_virt_address: u64 = 0x402000;

    var elf_hdr: elf.Elf64_Ehdr = elf.Elf64_Ehdr{
        .e_ident = undefined,
        .e_type = elf.ET.EXEC,
        .e_machine = elf.EM.X86_64,
        .e_version = 1,
        .e_entry = code_virt_address + parser.program.entry.addr,
        .e_ehsize = 64,
        .e_phoff = 64,
        .e_shoff = 0,
        .e_flags = 0,
        .e_phentsize = 56,
        .e_phnum = 2,
        .e_shentsize = undefined,
        .e_shnum = 0,
        .e_shstrndx = elf.SHN_UNDEF,
    };

    var data_phdr: elf.Elf64_Phdr = elf.Elf64_Phdr{
        .p_type = elf.PT_LOAD,
        .p_offset = undefined,
        .p_vaddr = data_virt_address,
        .p_paddr = undefined,
        .p_filesz = data_len,
        .p_memsz = data_len,
        .p_flags = elf.PF_R | elf.PF_W,
        .p_align = 0x1000,
    };

    var code_phdr: elf.Elf64_Phdr = elf.Elf64_Phdr{
        .p_type = elf.PT_LOAD,
        .p_offset = undefined,
        .p_vaddr = code_virt_address,
        .p_paddr = undefined,
        .p_filesz = code_len,
        .p_memsz = code_len,
        .p_flags = elf.PF_R | elf.PF_X,
        .p_align = 0x1000,
    };

    elf_hdr.e_ident[0] = elf.MAGIC[0];
    elf_hdr.e_ident[1] = elf.MAGIC[1];
    elf_hdr.e_ident[2] = elf.MAGIC[2];
    elf_hdr.e_ident[3] = elf.MAGIC[3];
    elf_hdr.e_ident[4] = elf.ELFCLASS64;
    elf_hdr.e_ident[5] = elf.ELFDATA2LSB;
    elf_hdr.e_ident[6] = 1;
    elf_hdr.e_ident[7] = @intFromEnum(elf.OSABI.GNU);
    elf_hdr.e_ident[8] = 0; // check
    elf_hdr.e_ident[9] = 0;
    elf_hdr.e_ident[10] = 0;
    elf_hdr.e_ident[11] = 0;
    elf_hdr.e_ident[12] = 0;
    elf_hdr.e_ident[13] = 0;
    elf_hdr.e_ident[14] = 0;
    elf_hdr.e_ident[15] = 0;

    data_phdr.p_offset = 0x1000;
    code_phdr.p_offset = 0x2000;

    //0-63          64  B - Elf hdr
    //64-119        56  B - Pro hdr - data
    //120-176       56  B - Pro hdr - code
    //177-4095            - 1 padding
    //4096-dlen     96  B - data buffer
    //    -8191           - 2 padding
    //8192-clen     198 B - code buffer

    var buffer: std.ArrayList(u8) = try std.ArrayList(u8).initCapacity(allocator, 10000);
    defer buffer.deinit(allocator);

    // write ELF Header
    for (elf_hdr.e_ident) |byte| {
        try buffer.append(allocator, byte);
    }
    try writeU16(allocator, &buffer, @intFromEnum(elf_hdr.e_type));
    try writeU16(allocator, &buffer, @intFromEnum(elf_hdr.e_machine));
    try writeU32(allocator, &buffer, elf_hdr.e_version);
    try writeU64(allocator, &buffer, elf_hdr.e_entry);
    try writeU64(allocator, &buffer, elf_hdr.e_phoff);
    try writeU64(allocator, &buffer, elf_hdr.e_shoff);
    try writeU32(allocator, &buffer, elf_hdr.e_flags);
    try writeU16(allocator, &buffer, elf_hdr.e_ehsize);
    try writeU16(allocator, &buffer, elf_hdr.e_phentsize);
    try writeU16(allocator, &buffer, elf_hdr.e_phnum);
    try writeU16(allocator, &buffer, elf_hdr.e_shentsize);
    try writeU16(allocator, &buffer, elf_hdr.e_shnum);
    try writeU16(allocator, &buffer, elf_hdr.e_shstrndx);

    // write Data Program Header
    try writeU32(allocator, &buffer, data_phdr.p_type);
    try writeU32(allocator, &buffer, data_phdr.p_flags);
    try writeU64(allocator, &buffer, data_phdr.p_offset);
    try writeU64(allocator, &buffer, data_phdr.p_vaddr);
    try writeU64(allocator, &buffer, data_phdr.p_paddr);
    try writeU64(allocator, &buffer, data_phdr.p_filesz);
    try writeU64(allocator, &buffer, data_phdr.p_memsz);
    try writeU64(allocator, &buffer, data_phdr.p_align);

    // write Code Program Header
    try writeU32(allocator, &buffer, code_phdr.p_type);
    try writeU32(allocator, &buffer, code_phdr.p_flags);
    try writeU64(allocator, &buffer, code_phdr.p_offset);
    try writeU64(allocator, &buffer, code_phdr.p_vaddr);
    try writeU64(allocator, &buffer, code_phdr.p_paddr);
    try writeU64(allocator, &buffer, code_phdr.p_filesz);
    try writeU64(allocator, &buffer, code_phdr.p_memsz);
    try writeU64(allocator, &buffer, code_phdr.p_align);

    // write 1 padding
    for (0..(data_phdr.p_offset - buffer.items.len)) |_| {
        try buffer.append(allocator, undefined);
    }

    // write Data Buffer
    try buffer.appendSlice(allocator, datagen.data_buffer.items);

    // write 2 padding
    for (0..(code_phdr.p_offset - buffer.items.len)) |_| {
        try buffer.append(allocator, undefined);
    }

    // write Code Buffer
    try buffer.appendSlice(allocator, codegen.code_buffer.items);

    var path_buffer: [200]u8 = undefined;
    const exe_folder = try std.fs.selfExeDirPath(&path_buffer);

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ exe_folder, file_name });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    _ = try file.write(buffer.items);
}
