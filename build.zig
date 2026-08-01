const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const with_llvm = b.option(bool, "llvm", "Use LLVM backend") orelse false;

    const errprint = b.addModule("errprint", .{
        .root_source_file = b.path("src/errprint.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const cli_args = b.addModule("CliArgs", .{
        .root_source_file = b.path("src/CliArgs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
        },
    });

    const lexer = b.addModule("lexer", .{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
        },
    });

    const parser = b.addModule("Parser", .{
        .root_source_file = b.path("src/Parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
            .{ .name = "lexer", .module = lexer },
        },
    });

    const program = b.addModule("Program", .{
        .root_source_file = b.path("src/Program.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "Parser", .module = parser },
        },
    });

    parser.addImport("Program", program);

    const datagen = b.addModule("datagen", .{
        .root_source_file = b.path("src/datagen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
            .{ .name = "Program", .module = program },
        },
    });

    program.addImport("datagen", datagen);

    const codegen = b.addModule("Codegen", .{
        .root_source_file = b.path("src/Codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
            .{ .name = "lexer", .module = lexer },
            .{ .name = "Program", .module = program },
        },
    });

    program.addImport("Codegen", codegen);

    const objfile = b.addModule("ObjFileElf", .{
        .root_source_file = b.path("src/ObjFileElf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "Program", .module = program },
        },
    });

    const linker = b.addModule("Linker", .{
        .root_source_file = b.path("src/Linker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
            .{ .name = "ObjFileElf", .module = objfile },
        },
    });

    const assembler = b.addModule("Assembler", .{
        .root_source_file = b.path("src/Assembler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
            .{ .name = "CliArgs", .module = cli_args },
            .{ .name = "Program", .module = program },
            .{ .name = "lexer", .module = lexer },
            .{ .name = "Parser", .module = parser },
            .{ .name = "datagen", .module = datagen },
            .{ .name = "Codegen", .module = codegen },
            .{ .name = "ObjFileElf", .module = objfile },
            .{ .name = "Linker", .module = linker },
        },
    });

    linker.addImport("Assembler", assembler);

    const main_module = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "errprint", .module = errprint },
            .{ .name = "CliArgs", .module = cli_args },
            .{ .name = "Assembler", .module = assembler },
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

    const mod_tests = b.addTest(.{
        .root_module = codegen,
        .filters = b.args orelse &.{},
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
