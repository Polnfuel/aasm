const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const datagen = b.addModule("datagen", .{
        .root_source_file = b.path("src/datagen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parser", .module = parser },
        },
    });

    const codegen = b.addModule("codegen", .{
        .root_source_file = b.path("src/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lexer", .module = lexer },
            .{ .name = "parser", .module = parser },
            .{ .name = "datagen", .module = datagen },
        },
    });

    const compositor = b.addModule("compositor", .{
        .root_source_file = b.path("src/compositor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codegen", .module = codegen },
            .{ .name = "datagen", .module = datagen },
            .{ .name = "parser", .module = parser },
        },
    });

    const exe = b.addExecutable(.{
        .name = "aasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lexer", .module = lexer },
                .{ .name = "parser", .module = parser },
                .{ .name = "datagen", .module = datagen },
                .{ .name = "codegen", .module = codegen },
                .{ .name = "compositor", .module = compositor },
            },
        }),
    });

    exe.use_llvm = true;

    b.installArtifact(exe);

    const inst4 = b.addInstallFile(b.path("test-asm/long.asm"), "bin/long.asm");
    const install_step = b.getInstallStep();
    install_step.dependOn(&inst4.step);
}
