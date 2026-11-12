//! Dart packages (pub), vendored at fetch time (SPEC.md 7.4).
//!
//! The store, cache/pub/, holds each package archive once
//! (<name>-<version>.tar.gz, as pub.dev serves it). At fetch time every
//! pubspec.lock in the source is read, and each hosted package it locks is
//! downloaded from pub.dev unless the store has it, checked against the
//! lockfile's sha256 (pub records the archive's). Before a build the archives
//! are unpacked into a pub cache in the source tree (.dkpub), as pub lays out
//! its own, with the hashes pub keeps beside them, so `dart pub get --offline
//! --enforce-lockfile` finds every package. Nothing from a package runs here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fetch = @import("fetch.zig");

pub fn listPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/pubdeps/{s}.list", .{ cache, tarball_sha256 });
}

pub const no_lockfile = "pub: the source has no pubspec.lock";

pub const Pkg = struct { name: []const u8, version: []const u8, sha256: []const u8 };

/// The hosted packages of one pubspec.lock (pub.dev or another hosted
/// repository's URL is not checked: pub.dev's archive URL is used). Path and
/// SDK packages need nothing; git packages are counted as missing.
pub fn collect(arena: Allocator, text: []const u8, out: *std.ArrayList(Pkg), missing: *usize) !void {
    var in_packages = false;
    var name: ?[]const u8 = null;
    var source: []const u8 = "";
    var version: []const u8 = "";
    var sha: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (true) {
        const raw = lines.next();
        const line = if (raw) |r| std.mem.trimEnd(u8, r, "\r") else "";
        const is_entry = raw != null and line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ';
        const top = raw != null and line.len > 0 and line[0] != ' ';
        if (raw == null or is_entry or top) {
            // finish the previous entry
            if (name) |n| {
                if (std.mem.eql(u8, source, "hosted")) {
                    if (sha.len == 64) try out.append(arena, .{ .name = n, .version = version, .sha256 = sha }) else missing.* += 1;
                } else if (std.mem.eql(u8, source, "git")) missing.* += 1;
            }
            name = null;
            source = "";
            version = "";
            sha = "";
            if (raw == null) break;
            if (top) {
                in_packages = std.mem.eql(u8, line, "packages:");
                continue;
            }
            if (in_packages) name = std.mem.trimEnd(u8, std.mem.trim(u8, line, " "), ":");
            continue;
        }
        if (!in_packages or name == null) continue;
        const t = std.mem.trim(u8, line, " ");
        if (std.mem.startsWith(u8, t, "source: ")) source = std.mem.trim(u8, t["source: ".len..], "\" ");
        if (std.mem.startsWith(u8, t, "version: ")) version = std.mem.trim(u8, t["version: ".len..], "\" ");
        if (std.mem.startsWith(u8, t, "sha256: ")) sha = std.mem.trim(u8, t["sha256: ".len..], "\" ");
    }
}

/// For recipes with the `pubdeps` option: every hosted package of every
/// pubspec.lock in the source, downloaded into the store unless it is there,
/// each checked against its sha256; their list to cache/pubdeps/<sha>.list
/// ("<name> <version> <sha256>" lines).
pub fn fetchPubDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) fetch.Error!fetch.Status {
    const out_path = try listPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const dir = try std.fmt.allocPrint(arena, "{s}/pubdeps", .{cache});
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, tarball_sha256 });
    std.Io.Dir.cwd().createDirPath(io, tmp) catch return error.DownloadFailed;
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const tarball = try fetch.cachePath(arena, cache, tarball_sha256);
    const find = try std.fmt.allocPrint(arena, "set -e; mkdir -p '{0s}/src'; tar -xf '{1s}' -C '{0s}/src'; " ++
        "find '{0s}/src' -name pubspec.lock -not -path '*/.dart_tool/*' > '{0s}/locks'", .{ tmp, tarball });
    const r1 = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", find } }) catch return error.DownloadFailed;
    if (!(r1.term == .exited and r1.term.exited == 0)) {
        message.* = try std.fmt.allocPrint(arena, "pub: cannot unpack the source: {s}", .{std.mem.trim(u8, r1.stderr, "\n ")});
        return error.DownloadFailed;
    }
    const locks = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/locks", .{tmp}), arena, .limited(1 << 20)) catch return error.DownloadFailed;
    var pkgs: std.ArrayList(Pkg) = .empty;
    var missing: usize = 0;
    var nlocks: usize = 0;
    var it = std.mem.tokenizeScalar(u8, locks, '\n');
    while (it.next()) |lp| {
        nlocks += 1;
        const text = std.Io.Dir.cwd().readFileAlloc(io, lp, arena, .limited(1 << 24)) catch return error.DownloadFailed;
        collect(arena, text, &pkgs, &missing) catch return error.DownloadFailed;
    }
    if (nlocks == 0) {
        message.* = no_lockfile;
        return error.DownloadFailed;
    }
    if (missing > 0) {
        message.* = try std.fmt.allocPrint(arena, "pub: {d} locked package(s) are git sources or have no sha256; they cannot be vendored", .{missing});
        return error.DownloadFailed;
    }
    const store = try std.fmt.allocPrint(arena, "{s}/pub", .{cache});
    std.Io.Dir.cwd().createDirPath(io, store) catch return error.DownloadFailed;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var list: std.ArrayList(u8) = .empty;
    const Todo = struct { file: []const u8, url: []const u8, part: []const u8, sha: []const u8 };
    var todo: std.ArrayList(Todo) = .empty;
    for (pkgs.items) |p| {
        const file = try std.fmt.allocPrint(arena, "{s}-{s}.tar.gz", .{ p.name, p.version });
        if (seen.contains(file)) continue;
        try seen.put(arena, file, {});
        try list.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} {s} {s}\n", .{ p.name, p.version, p.sha256 }));
        if (std.Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ store, file }), .{})) |_| continue else |_| {}
        try todo.append(arena, .{
            .file = file,
            .url = try std.fmt.allocPrint(arena, "https://pub.dev/api/archives/{s}", .{file}),
            .part = try std.fmt.allocPrint(arena, "{s}/dl-{d}", .{ tmp, todo.items.len }),
            .sha = p.sha256,
        });
    }
    if (todo.items.len > 0) {
        var cfg: std.ArrayList(u8) = .empty;
        for (todo.items) |t| try cfg.appendSlice(arena, try std.fmt.allocPrint(arena, "url = \"{s}\"\noutput = \"{s}\"\n", .{ t.url, t.part }));
        const cfgp = try std.fmt.allocPrint(arena, "{s}/curl.cfg", .{tmp});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgp, .data = cfg.items }) catch return error.DownloadFailed;
        const r2 = std.process.run(arena, io, .{ .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "3", "--parallel", "--parallel-max", "12", "-K", cfgp } }) catch return error.DownloadFailed;
        if (!(r2.term == .exited and r2.term.exited == 0)) {
            message.* = try std.fmt.allocPrint(arena, "pub: downloads failed: {s}", .{std.mem.trim(u8, r2.stderr, "\n ")});
            return error.DownloadFailed;
        }
        for (todo.items) |t| {
            const got = fetch.hashFile(io, t.part) catch return error.DownloadFailed;
            if (!std.mem.eql(u8, &got, t.sha)) {
                message.* = try std.fmt.allocPrint(arena, "pub: {s} does not match its sha256 (lock {s}, got {s})", .{ t.file, t.sha, &got });
                return error.DownloadFailed;
            }
            std.Io.Dir.cwd().rename(t.part, std.Io.Dir.cwd(), try std.fs.path.join(arena, &.{ store, t.file }), io) catch return error.DownloadFailed;
        }
    }
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{out_path});
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.DownloadFailed;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = list.items }) catch return error.DownloadFailed;
    std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), out_path, io) catch return error.DownloadFailed;
    return .downloaded;
}

test "collect: hosted packages with sha256; sdk and path entries skipped" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const lock =
        \\# Generated by pub
        \\packages:
        \\  args:
        \\    dependency: transitive
        \\    description:
        \\      name: args
        \\      sha256: "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04"
        \\      url: "https://pub.dev"
        \\    source: hosted
        \\    version: "2.7.0"
        \\  local_thing:
        \\    dependency: "direct main"
        \\    description:
        \\      path: "../local_thing"
        \\      relative: true
        \\    source: path
        \\    version: "1.0.0"
        \\  meta:
        \\    dependency: "direct main"
        \\    description:
        \\      name: meta
        \\      sha256: "e3641ec5d63ebf0d9b41bd43201a66e3fc79a65db5f61fc181f04cd27aab950c"
        \\      url: "https://pub.dev"
        \\    source: hosted
        \\    version: "1.16.0"
        \\sdks:
        \\  dart: ">=3.6.0 <4.0.0"
        \\
    ;
    var pkgs: std.ArrayList(Pkg) = .empty;
    var missing: usize = 0;
    try collect(a, lock, &pkgs, &missing);
    try std.testing.expectEqual(@as(usize, 2), pkgs.items.len);
    try std.testing.expectEqual(@as(usize, 0), missing);
    try std.testing.expectEqualStrings("args", pkgs.items[0].name);
    try std.testing.expectEqualStrings("2.7.0", pkgs.items[0].version);
    try std.testing.expectEqualStrings("meta", pkgs.items[1].name);
}
