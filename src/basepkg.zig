//! Describes the base image to apk (SPEC.md 7.3, stage 1).
//!
//! The DKRescue root was built by hand, so apk has no database for it and
//! cannot tell that, say, `so:libc.so` is already there. Installing an in-tree
//! package that needs it would fail. So the image is described as one package,
//! `dkrescue-base`, whose only job is to *provide* every shared library
//! (`so:`), command (`cmd:`) and pkg-config name (`pc:`) found in the image.
//! Installing it first gives apk the facts it needs; it adds no files but a
//! note about itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const scan = @import("scan.zig");
const sandbox = @import("sandbox.zig");

pub const name = "dkrescue-base";
pub const file_name = "dkrescue-base-1-r0.apk";
/// Where the package lives, relative to the project root.
pub const dir = "rootfs/dkrescue-base";

pub const Error = error{BasePackageFailed} || Allocator.Error;

/// Builds the package if it is missing (or `force`). `dkr` is the absolute path
/// of the unpacked image.
pub fn ensure(arena: Allocator, io: std.Io, root: []const u8, dkr: []const u8, force: bool) Error!void {
    const apk_rel = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, dir, file_name });
    if (!force) {
        if (Dir.cwd().access(io, apk_rel, .{})) |_| return else |_| {}
    }
    std.debug.print("describing the base image to apk ({s})\n", .{dkr});

    const res = scan.scanTree(arena, io, dkr) catch |err| {
        std.debug.print("error: scanning {s}: {s}\n", .{ dkr, @errorName(err) });
        return error.BasePackageFailed;
    };

    const base_rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, dir });
    const files_rel = try std.fmt.allocPrint(arena, "{s}/files/usr/share/{s}", .{ base_rel, name });
    Dir.cwd().createDirPath(io, files_rel) catch return error.BasePackageFailed;
    const out_rel = try std.fmt.allocPrint(arena, "{s}/out", .{base_rel});
    Dir.cwd().createDirPath(io, out_rel) catch return error.BasePackageFailed;

    // Versions: sonames get 0, everything else the package's version, as for
    // every other package (apk only picks a provider for versioned provides).
    var provides: std.ArrayList(u8) = .empty;
    for (res.provides) |pv| {
        if (provides.items.len > 0) try provides.append(arena, ' ');
        try provides.appendSlice(arena, pv);
        try provides.appendSlice(arena, if (std.mem.startsWith(u8, pv, "so:")) "=0" else "=1");
    }
    Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/README", .{files_rel}),
        .data = "This package stands for the DKRescue image the build runs on.\nIt provides what the image contains; see `apk info -P dkrescue-base`.\n",
    }) catch return error.BasePackageFailed;

    const files_abs = Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/files", .{base_rel}), arena) catch return error.BasePackageFailed;
    const out_abs = Dir.cwd().realPathFileAlloc(io, out_rel, arena) catch return error.BasePackageFailed;

    // apk runs inside the image itself, in a throwaway layer.
    const sb_rel = try std.fmt.allocPrint(arena, "{s}/sb", .{base_rel});
    var sb: [3][]const u8 = undefined;
    for ([_][]const u8{ "upper", "work", "merged" }, 0..) |sub, k| {
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sb_rel, sub });
        Dir.cwd().deleteTree(io, rel) catch {};
        Dir.cwd().createDirPath(io, rel) catch return error.BasePackageFailed;
        sb[k] = Dir.cwd().realPathFileAlloc(io, rel, arena) catch return error.BasePackageFailed;
    }
    defer {
        sandbox.makeRemovable(io, sb[1]);
        Dir.cwd().deleteTree(io, sb_rel) catch {};
    }

    const argv = [_][]const u8{
        "/usr/bin/apk",     "mkpkg",
        "--info",           "name:" ++ name,
        "--info",           "version:1-r0",
        "--info",           "arch:x86_64",
        "--info",           "description:The DKRescue image, described to apk",
        "--info",           "license:MIT",
        "--info",           try std.fmt.allocPrint(arena, "provides:{s}", .{provides.items}),
        "--files",          "/files",
        "--output",         "/out/" ++ file_name,
    };
    var log: std.ArrayList(u8) = .empty;
    const ok = sandbox.run(arena, io, .{
        .lower = dkr,
        .upper = sb[0],
        .work = sb[1],
        .merged = sb[2],
        .binds = &.{
            .{ .src = files_abs, .dst = "/files", .read_only = true },
            .{ .src = out_abs, .dst = "/out" },
        },
        .env = &.{ "PATH=/usr/bin:/bin", "HOME=/root" },
        .argv = &argv,
    }, &log) catch false;
    if (!ok) {
        std.debug.print("error: apk mkpkg failed for {s}:\n{s}\n", .{ name, log.items });
        return error.BasePackageFailed;
    }
    // Keep the finished package where the build looks for it.
    const final_rel = apk_rel;
    Dir.cwd().rename(try std.fmt.allocPrint(arena, "{s}/{s}", .{ out_rel, file_name }), Dir.cwd(), final_rel, io) catch return error.BasePackageFailed;
    std.debug.print("  {s}: {d} provides\n", .{ name, res.provides.len });
}
