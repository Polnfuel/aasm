const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const with_llvm = b.option(bool, "llvm", "Use LLVM backend") orelse false;

    const lexer = b.addModule("lexer", .{
        .root_source_file = b.path("src/lexer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const parser = b.addModule("parser", .{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
        },
    });

    const object = b.addModule("object", .{
        .root_source_file = b.path("src/object.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "parser", .module = parser },
        },
    });

    parser.addImport("object", object);

    const datagen = b.addModule("datagen", .{
        .root_source_file = b.path("src/datagen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = parser },
        },
    });

    object.addImport("datagen", datagen);

    const codegen = b.addModule("codegen", .{
        .root_source_file = b.path("src/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "parser", .module = parser },
        },
    });

    object.addImport("codegen", codegen);

    const main_module = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "object", .module = object },
        },
    });

    const exe = b.addExecutable(.{
        .name = "aasm",
        .root_module = main_module,
    });

    if (with_llvm) {
        exe.use_llvm = true;
    }

    b.installArtifact(exe);

    const inst4 = b.addInstallFile(b.path("test-asm/long.asm"), "bin/long.asm");
    const install_step = b.getInstallStep();
    install_step.dependOn(&inst4.step);
}
