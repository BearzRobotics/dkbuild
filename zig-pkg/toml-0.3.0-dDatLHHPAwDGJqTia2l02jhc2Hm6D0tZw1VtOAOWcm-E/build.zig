//! toml-zig build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Manual pages (Markdown, read by dkman and dkde-help): share/man/manN/NAME.N.md.
    // The section N is the number in the file name.
    if (b.option(bool, "man", "Install the manual pages (default: on)") orelse true) {
        const pages = [_][]const u8{ "toml-parse.1.md", "toml-syntax.5.md", "toml-zig.3.md" };
        for (pages) |page| {
            const stem = page[0 .. page.len - ".md".len];
            const section = stem[std.mem.lastIndexOfScalar(u8, stem, '.').? + 1 ..];
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                b.path(b.fmt("docs/manpages/{s}", .{page})),
                .{ .custom = b.fmt("share/man/man{s}", .{section}) },
                page,
            ).step);
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as @import("toml").
    const mod = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit and conformance tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Checks that the code in docs/manpages/toml-syntax.5.md parses.
    const guide_mod = b.createModule(.{
        .root_source_file = b.path("src/guide_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "toml", .module = mod }},
    });
    guide_mod.addAnonymousImport("toml-syntax.5.md", .{ .root_source_file = b.path("docs/manpages/toml-syntax.5.md") });
    const guide_test = b.addTest(.{ .root_module = guide_mod });
    test_step.dependOn(&b.addRunArtifact(guide_test).step);

    // Baseline benchmark; always built ReleaseFast so numbers are comparable.
    const bench_step = b.step("bench", "Run the parse/write benchmark (ReleaseFast)");
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("toml", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    const bench_exe = b.addExecutable(.{ .name = "toml-bench", .root_module = bench_mod });
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    // A command line parser for comparing builds with `poop` (see the file).
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("bench/parse_file.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cli_mod.addImport("toml", bench_mod.import_table.get("toml").?);
    const cli_exe = b.addExecutable(.{ .name = "toml-parse", .root_module = cli_mod });
    const cli_step = b.step("cli", "Build zig-out/bin/toml-parse for comparing with poop");
    cli_step.dependOn(&b.addInstallArtifact(cli_exe, .{}).step);
    // Compile (not run) both benchmark programs with the tests, so that they
    // cannot stop building unnoticed.
    test_step.dependOn(&bench_exe.step);
    test_step.dependOn(&cli_exe.step);

    // The official conformance suite, from a local checkout (it is not vendored).
    const conformance_step = b.step("conformance", "Run toml-test; needs -Dsuite=PATH/toml-test/tests");
    const conformance_mod = b.createModule(.{
        .root_source_file = b.path("test/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "toml", .module = mod }},
    });
    const conformance_exe = b.addExecutable(.{ .name = "toml-conformance", .root_module = conformance_mod });
    test_step.dependOn(&conformance_exe.step);
    if (b.option([]const u8, "suite", "The tests/ directory of a toml-test checkout")) |suite| {
        const run = b.addRunArtifact(conformance_exe);
        run.addArg(suite);
        run.has_side_effects = true;
        conformance_step.dependOn(&run.step);
    } else {
        conformance_step.dependOn(&b.addFail("pass -Dsuite=PATH/toml-test/tests").step);
    }
}
