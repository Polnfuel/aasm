const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const with_llvm = b.option(bool, "llvm", "Use LLVM backend") orelse false;
    const exe_name = b.option([]const u8, "name", "Specify output name") orelse "aasm";
    const test_filter = b.option([]const []const u8, "test-filter", "Filter strings for tests") orelse &.{};

    const utils = b.addModule("utils", .{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const cli_args = b.addModule("CliArgs", .{
        .root_source_file = b.path("src/CliArgs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
        },
    });

    utils.addImport("CliArgs", cli_args);

    const token_type = b.addModule("TokenType", .{
        .root_source_file = b.path("src/TokenType.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const lexer = b.addModule("lexer", .{
        .root_source_file = b.path("src/Lexer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "TokenType", .module = token_type },
        },
    });

    const program = b.addModule("Program", .{
        .root_source_file = b.path("src/Program.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "Lexer", .module = lexer },
        },
    });

    utils.addImport("Program", program);
    lexer.addImport("Program", program);

    const const_expr_eval = b.addModule("ConstExprEval", .{
        .root_source_file = b.path("src/ConstExprEval.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "Lexer", .module = lexer },
            .{ .name = "Program", .module = program },
        },
    });

    const addr_expr_eval = b.addModule("AddrExprEval", .{
        .root_source_file = b.path("src/AddrExprEval.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "Lexer", .module = lexer },
            .{ .name = "Program", .module = program },
        },
    });

    const parser = b.addModule("Parser", .{
        .root_source_file = b.path("src/Parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "Lexer", .module = lexer },
            .{ .name = "Program", .module = program },
            .{ .name = "ConstExprEval", .module = const_expr_eval },
            .{ .name = "AddrExprEval", .module = addr_expr_eval },
        },
    });

    const_expr_eval.addImport("Parser", parser);
    addr_expr_eval.addImport("Parser", parser);

    const codegen = b.addModule("Codegen", .{
        .root_source_file = b.path("src/Codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "Lexer", .module = lexer },
            .{ .name = "Program", .module = program },
        },
    });

    const objfile = b.addModule("ObjFileElf", .{
        .root_source_file = b.path("src/ObjFileElf.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "Program", .module = program },
        },
    });

    const linker = b.addModule("Linker", .{
        .root_source_file = b.path("src/Linker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "ObjFileElf", .module = objfile },
        },
    });

    const assembler = b.addModule("Assembler", .{
        .root_source_file = b.path("src/Assembler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "utils", .module = utils },
            .{ .name = "CliArgs", .module = cli_args },
            .{ .name = "Program", .module = program },
            .{ .name = "Lexer", .module = lexer },
            .{ .name = "Parser", .module = parser },
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
            .{ .name = "utils", .module = utils },
            .{ .name = "CliArgs", .module = cli_args },
            .{ .name = "Assembler", .module = assembler },
        },
    });

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = main_module,
    });

    if (with_llvm) {
        exe.use_llvm = true;
    }

    b.installArtifact(exe);

    const codegen_test = b.addTest(.{
        .root_module = b.addModule("codgentest", .{
            .root_source_file = b.path("test/codegen.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "CliArgs", .module = cli_args },
                .{ .name = "Program", .module = program },
                .{ .name = "Lexer", .module = lexer },
                .{ .name = "Parser", .module = parser },
                .{ .name = "Codegen", .module = codegen },
            },
        }),
        .filters = test_filter,
    });

    const run_codgen_test = b.addRunArtifact(codegen_test);

    const parser_test = b.addTest(.{
        .root_module = b.addModule("parsetest", .{
            .root_source_file = b.path("test/parser.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "utils", .module = utils },
                .{ .name = "CliArgs", .module = cli_args },
                .{ .name = "Program", .module = program },
                .{ .name = "Lexer", .module = lexer },
                .{ .name = "Parser", .module = parser },
            },
        }),
        .filters = test_filter,
    });

    const run_parser_test = b.addRunArtifact(parser_test);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_codgen_test.step);
    test_step.dependOn(&run_parser_test.step);
}
