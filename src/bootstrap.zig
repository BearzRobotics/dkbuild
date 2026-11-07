//! `dkbuild bootstrap-root`: unpack the build machine image into a directory
//! (SPEC.md 9.2, stage 0).
//!
//! The image is the DKRescue system. It can be given as the live ISO (whose
//! `/live/rootfs.sfs` is read with xorriso), as that squashfs, or as a root
//! tarball. Unpacking needs no privileges: the files end up owned by the
//! current user, which is exactly what a user namespace that maps this user to
//! root shows to a build. Special files (device nodes, setuid bits, file
//! capabilities) are not kept, and builds don't need them.
//!
//! The unpacked root is then checked: the tools a build needs must be there,
//! and it must run its own programs inside a user namespace.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const basepkg = @import("basepkg.zig");

pub const Kind = enum { iso, squashfs, tarball };

pub const Error = error{
    /// The destination exists and `--force` was not given.
    Exists,
    /// A needed program (xorriso, unsquashfs, tar, unshare) is not installed.
    ToolMissing,
    /// A program ran and failed; its output was printed.
    ToolFailed,
    /// The image could not be read.
    BadImage,
    /// The unpacked root is missing something a build needs.
    Incomplete,
} || Allocator.Error;

/// Offset of the "CD001" signature of an ISO 9660 volume descriptor.
const iso_magic_offset = 0x8001;

/// Decides what `head` (the first bytes of the image) and `iso_sig` (the five
/// bytes at `iso_magic_offset`, if the file is that long) say the file is.
pub fn classify(head: []const u8, iso_sig: ?[]const u8) Kind {
    if (std.mem.startsWith(u8, head, "hsqs")) return .squashfs;
    if (iso_sig) |sig| if (std.mem.eql(u8, sig, "CD001")) return .iso;
    return .tarball;
}

pub fn detect(io: std.Io, path: []const u8) Error!Kind {
    var file = Dir.cwd().openFile(io, path, .{}) catch return error.BadImage;
    defer file.close(io);
    var buf: [64]u8 = undefined;
    var reader = file.reader(io, &buf);
    var head: [4]u8 = undefined;
    reader.interface.readSliceAll(&head) catch return error.BadImage;
    var sig: [5]u8 = undefined;
    const have_sig = blk: {
        reader.seekTo(iso_magic_offset) catch break :blk false;
        reader.interface.readSliceAll(&sig) catch break :blk false;
        break :blk true;
    };
    return classify(&head, if (have_sig) &sig else null);
}

/// A tool a build needs in the build machine, and whether its absence is fatal.
pub const Tool = struct { name: []const u8, required: bool };

pub const tools = [_]Tool{
    .{ .name = "apk", .required = true },
    .{ .name = "clang", .required = true },
    .{ .name = "ld.lld", .required = true },
    .{ .name = "llvm-ar", .required = true },
    .{ .name = "make", .required = true },
    .{ .name = "sh", .required = true },
    .{ .name = "sed", .required = true },
    .{ .name = "tar", .required = true },
    .{ .name = "xz", .required = true },
    .{ .name = "zig", .required = false },
    .{ .name = "python3", .required = false },
    .{ .name = "cmake", .required = false },
    .{ .name = "ninja", .required = false },
    .{ .name = "meson", .required = false },
    .{ .name = "git", .required = false },
    .{ .name = "scdoc", .required = false },
    .{ .name = "bash", .required = false },
    .{ .name = "dinit", .required = false },
};

const search_dirs = [_][]const u8{ "usr/bin", "bin", "usr/sbin", "sbin" };

fn hasTool(arena: Allocator, io: std.Io, root: []const u8, name: []const u8) bool {
    for (search_dirs) |d| {
        const p = std.fs.path.join(arena, &.{ root, d, name }) catch return false;
        // Don't follow links: a tool is often a link with an absolute target
        // (zig -> /opt/zig-0.17.0/zig) that only resolves inside the root.
        if (Dir.cwd().statFile(io, p, .{ .follow_symlinks = false })) |_| return true else |_| {}
    }
    return false;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Runs `argv`; prints its output and fails if it does not exit with 0.
fn run(arena: Allocator, io: std.Io, argv: []const []const u8) Error!void {
    const res = std.process.run(arena, io, .{ .argv = argv }) catch |err| switch (err) {
        error.FileNotFound => {
            say("error: '{s}' is not installed\n", .{argv[0]});
            return error.ToolMissing;
        },
        else => {
            say("error: cannot run '{s}': {s}\n", .{ argv[0], @errorName(err) });
            return error.ToolFailed;
        },
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        say("error: {s} failed:\n{s}{s}\n", .{ argv[0], res.stdout, res.stderr });
        return error.ToolFailed;
    }
}

pub const Options = struct {
    /// Where scratch files go (a 1 GB squashfs is read out of the ISO).
    /// Not /tmp: that is often a small tmpfs.
    work_dir: []const u8,
    /// The project root, where the base-image package is written.
    root: []const u8,
    force: bool = false,
};

/// Unpacks `image` into `dest` and checks the result.
pub fn bootstrapRoot(arena: Allocator, io: std.Io, image: []const u8, dest: []const u8, opts: Options) Error!void {
    const kind = detect(io, image) catch |err| {
        say("error: cannot read the image {s}\n", .{image});
        return err;
    };
    say("image: {s} ({s})\n", .{ image, @tagName(kind) });

    if (Dir.cwd().access(io, dest, .{})) |_| {
        if (!opts.force) {
            say("error: {s} already exists (--force replaces it)\n", .{dest});
            return error.Exists;
        }
        Dir.cwd().deleteTree(io, dest) catch {};
    } else |_| {}
    Dir.cwd().createDirPath(io, opts.work_dir) catch return error.BadImage;

    var staged: ?[]const u8 = null;
    defer if (staged) |s| Dir.cwd().deleteFile(io, s) catch {};

    switch (kind) {
        .iso => {
            const sfs = try std.fmt.allocPrint(arena, "{s}/bootstrap-rootfs.sfs", .{opts.work_dir});
            Dir.cwd().deleteFile(io, sfs) catch {};
            staged = sfs;
            say("reading /live/rootfs.sfs from the ISO\n", .{});
            try run(arena, io, &.{ "xorriso", "-osirrox", "on", "-indev", image, "-extract", "/live/rootfs.sfs", sfs });
            say("unpacking into {s}\n", .{dest});
            try run(arena, io, &.{ "unsquashfs", "-no-xattrs", "-f", "-d", dest, sfs });
        },
        .squashfs => {
            say("unpacking into {s}\n", .{dest});
            try run(arena, io, &.{ "unsquashfs", "-no-xattrs", "-f", "-d", dest, image });
        },
        .tarball => {
            Dir.cwd().createDirPath(io, dest) catch return error.BadImage;
            say("unpacking into {s}\n", .{dest});
            try run(arena, io, &.{ "tar", "-xpf", image, "-C", dest, "--no-same-owner" });
        },
    }
    try check(arena, io, dest);
    // Describe the image to apk, so packages built on it can be installed (7.3).
    const abs = Dir.cwd().realPathFileAlloc(io, dest, arena) catch return error.Incomplete;
    basepkg.ensure(arena, io, opts.root, abs, true) catch return error.Incomplete;
}

/// Checks an unpacked root; prints one line per tool and the functional check.
pub fn check(arena: Allocator, io: std.Io, root: []const u8) Error!void {
    var missing_required = false;
    for (tools) |t| {
        const found = hasTool(arena, io, root, t.name);
        if (!found and t.required) missing_required = true;
        say("  {s:<8} {s}\n", .{ t.name, if (found) "ok" else if (t.required) "MISSING" else "absent (optional)" });
    }
    if (missing_required) {
        say("error: the image lacks tools a build needs (marked MISSING)\n", .{});
        return error.Incomplete;
    }

    // The root must run its own programs from an unprivileged user namespace,
    // which is how every build runs.
    const abs = Dir.cwd().realPathFileAlloc(io, root, arena) catch return error.Incomplete;
    const res = std.process.run(arena, io, .{ .argv = &.{
        "unshare", "--user", "--map-root-user", "chroot", abs, "/bin/sh", "-c", "apk --version; clang -dumpmachine",
    } }) catch |err| {
        say("error: cannot run the root in a user namespace ({s}); is 'unshare' installed?\n", .{@errorName(err)});
        return error.ToolMissing;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        say("error: the root does not run inside a user namespace:\n{s}{s}\n", .{ res.stdout, res.stderr });
        say("(user namespaces must be enabled: CONFIG_USER_NS, and not a chroot-ed shell)\n", .{});
        return error.Incomplete;
    }
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, res.stdout, "\n"), '\n');
    while (lines.next()) |l| say("  runs: {s}\n", .{l});
    say("ok: {s} is a usable build machine\n", .{root});
}

test "classify tells squashfs, ISO and tarball apart" {
    try std.testing.expectEqual(Kind.squashfs, classify("hsqs", null));
    try std.testing.expectEqual(Kind.iso, classify("\x00\x00\x00\x00", "CD001"));
    try std.testing.expectEqual(Kind.tarball, classify("\xfd7zX", null));
    try std.testing.expectEqual(Kind.tarball, classify("\xfd7zX", "xxxxx"));
}
