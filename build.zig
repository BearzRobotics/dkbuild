const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    mod.addImport("toml", toml_dep.module("toml"));

    for ([_][]const u8{ "x86_64", "aarch64", "riscv64" }) |arch| {
        mod.addAnonymousImport(b.fmt("profile_{s}", .{arch}), .{
            .root_source_file = b.path(b.fmt("profiles/{s}.toml", .{arch})),
        });
    }

    const exe = b.addExecutable(.{ .name = "dkbuild", .root_module = mod });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
