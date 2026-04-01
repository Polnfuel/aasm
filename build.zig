const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const with_llvm = b.option(bool, "llvm", "Use LLVM backend") orelse false;

    const buffers = b.addModule("stdbuffers", .{
        .root_source_file = b.path("src/stdbuffers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const cliparser = b.addModule("cli", .{
        .root_source_file = b.path("src/cliparser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    const lexer = b.addModule("lexer", .{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    const parser = b.addModule("parser", .{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    const program = b.addModule("program", .{
        .root_source_file = b.path("src/program.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "parser", .module = parser },
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    lexer.addImport("program", program);
    parser.addImport("program", program);

    const datagen = b.addModule("datagen", .{
        .root_source_file = b.path("src/datagen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = parser },
            .{ .name = "program", .module = program },
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    program.addImport("datagen", datagen);

    const codegen = b.addModule("codegen", .{
        .root_source_file = b.path("src/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "parser", .module = parser },
            .{ .name = "program", .module = program },
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    program.addImport("codegen", codegen);

    const assembler = b.addModule("assembler", .{
        .root_source_file = b.path("src/assembler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "parser", .module = parser },
            .{ .name = "program", .module = program },
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    const main_module = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cli", .module = cliparser },
            .{ .name = "assembler", .module = assembler },
            .{ .name = "stdbuffers", .module = buffers },
        },
    });

    const exe = b.addExecutable(.{
        .name = "aasm",
        .root_module = main_module,
    });

    if (with_llvm) {
        exe.use_llvm = true;
    }

    if (optimize == .ReleaseFast) {
        exe.root_module.error_tracing = false;
        exe.root_module.omit_frame_pointer = true;
        exe.root_module.strip = true;
        exe.root_module.stack_protector = false;
        exe.root_module.stack_check = false;
    }

    b.installArtifact(exe);

    const inst1 = b.addInstallFile(b.path("test-asm/long.asm"), "bin/long.asm");
    const inst2 = b.addInstallFile(b.path("test-asm/print.asm"), "bin/print.asm");
    const install_step = b.getInstallStep();
    install_step.dependOn(&inst1.step);
    install_step.dependOn(&inst2.step);
}
