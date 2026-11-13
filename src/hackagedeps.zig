//! Haskell packages (Hackage), vendored at fetch time (SPEC.md 7.4).
//!
//! Haskell projects keep no lockfile with checksums, and Hackage lets an
//! author revise a released package's .cabal file. So a recipe with the
//! `hackagedeps` option keeps the pinned list itself, files/hackage.lock, one
//! package per line:
//!
//!     <name> <version> <tarball sha256> <revision> <revised .cabal sha256 or ->
//!
//! (`dkbuild hackage-lock` writes it from a cabal freeze file). The store,
//! cache/hackage/, holds each tarball once (<name>-<version>.tar.gz) and each
//! revised .cabal (<name>-<version>-r<n>.cabal), downloaded from Hackage and
//! checked against the lock. Before the build the source tree gets
//! .dkhackage/, a cabal `file+noindex` repository of links into the store
//! (a revision's .cabal beside its tarball, which cabal-install reads instead
//! of the tarball's), and CABAL_DIR's config makes it the only repository.
//! Nothing from a package runs here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fetch = @import("fetch.zig");

pub const lock_name = "hackage.lock";

pub const Pkg = struct {
    name: []const u8,
    version: []const u8,
    sha256: []const u8,
    revision: u32,
    cabal_sha256: ?[]const u8,

    pub fn tarball(p: Pkg, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}-{s}.tar.gz", .{ p.name, p.version });
    }
    pub fn cabalFile(p: Pkg, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}-{s}-r{d}.cabal", .{ p.name, p.version, p.revision });
    }
};

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

fn validName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_')) return false;
    return true;
}

/// Parses a hackage.lock. `#` starts a comment; blank lines are skipped.
/// On a bad line, `message` says which.
pub fn parse(arena: Allocator, text: []const u8, message: *[]const u8) ![]Pkg {
    var out: std.ArrayList(Pkg) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const name = f.next() orelse "";
        const version = f.next() orelse "";
        const sha = f.next() orelse "";
        const rev_s = f.next() orelse "";
        const csha = f.next() orelse "";
        const rev = std.fmt.parseInt(u32, rev_s, 10) catch {
            message.* = try std.fmt.allocPrint(arena, "hackage.lock line {d}: expected `<name> <version> <sha256> <revision> <cabal sha256|->`", .{n});
            return error.BadLock;
        };
        if (!validName(name) or !validName(version) or !isHex64(sha) or f.next() != null or
            (rev == 0 and !std.mem.eql(u8, csha, "-")) or (rev > 0 and !isHex64(csha)))
        {
            message.* = try std.fmt.allocPrint(arena, "hackage.lock line {d}: expected `<name> <version> <sha256> <revision> <cabal sha256|->` (revision 0 takes -)", .{n});
            return error.BadLock;
        }
        try out.append(arena, .{ .name = name, .version = version, .sha256 = sha, .revision = rev, .cabal_sha256 = if (rev > 0) csha else null });
    }
    return out.items;
}

pub fn listPath(arena: Allocator, cache: []const u8, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/hackagedeps/{s}.list", .{ cache, key });
}

/// The sha256 (hex) of the lock's bytes: its list is named by it, so an
/// edited lock fetches again.
pub fn lockKey(arena: Allocator, data: []const u8) ![]const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.allocPrint(arena, "{x}", .{&h});
}

/// Downloads what the store lacks of the lock at `lock_path`, checking each
/// file against the lock, then writes cache/hackagedeps/<key>.list (a copy of
/// the lock; its presence means the fetch is complete).
pub fn fetchLock(arena: Allocator, io: std.Io, cache: []const u8, lock_path: []const u8, message: *[]const u8) fetch.Error!fetch.Status {
    const data = std.Io.Dir.cwd().readFileAlloc(io, lock_path, arena, .limited(1 << 22)) catch {
        message.* = try std.fmt.allocPrint(arena, "hackage: cannot read {s}", .{lock_path});
        return error.DownloadFailed;
    };
    const key = try lockKey(arena, data);
    const out_path = try listPath(arena, cache, key);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const pkgs = parse(arena, data, message) catch return error.DownloadFailed;
    const store = try std.fmt.allocPrint(arena, "{s}/hackage", .{cache});
    const dir = try std.fmt.allocPrint(arena, "{s}/hackagedeps", .{cache});
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, key });
    for ([_][]const u8{ store, tmp }) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return error.DownloadFailed;
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const Todo = struct { file: []const u8, url: []const u8, part: []const u8, sha: []const u8 };
    var todo: std.ArrayList(Todo) = .empty;
    for (pkgs) |p| {
        const base = "https://hackage.haskell.org/package";
        const files = [_]?struct { file: []const u8, url: []const u8, sha: []const u8 }{
            .{ .file = try p.tarball(arena), .url = try std.fmt.allocPrint(arena, "{s}/{s}-{s}/{s}-{s}.tar.gz", .{ base, p.name, p.version, p.name, p.version }), .sha = p.sha256 },
            if (p.cabal_sha256) |cs| .{ .file = try p.cabalFile(arena), .url = try std.fmt.allocPrint(arena, "{s}/{s}-{s}/revision/{d}.cabal", .{ base, p.name, p.version, p.revision }), .sha = cs } else null,
        };
        for (files) |maybe| {
            const f = maybe orelse continue;
            if (std.Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ store, f.file }), .{})) |_| continue else |_| {}
            try todo.append(arena, .{ .file = f.file, .url = f.url, .part = try std.fmt.allocPrint(arena, "{s}/dl-{d}", .{ tmp, todo.items.len }), .sha = f.sha });
        }
    }
    if (todo.items.len > 0) {
        var cfg: std.ArrayList(u8) = .empty;
        for (todo.items) |t| try cfg.appendSlice(arena, try std.fmt.allocPrint(arena, "url = \"{s}\"\noutput = \"{s}\"\n", .{ t.url, t.part }));
        const cfgp = try std.fmt.allocPrint(arena, "{s}/curl.cfg", .{tmp});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgp, .data = cfg.items }) catch return error.DownloadFailed;
        const r = std.process.run(arena, io, .{ .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "3", "--parallel", "--parallel-max", "8", "-K", cfgp } }) catch return error.DownloadFailed;
        if (!(r.term == .exited and r.term.exited == 0)) {
            message.* = try std.fmt.allocPrint(arena, "hackage: downloads failed: {s}", .{std.mem.trim(u8, r.stderr, "\n ")});
            return error.DownloadFailed;
        }
        for (todo.items) |t| {
            const got = fetch.hashFile(io, t.part) catch return error.DownloadFailed;
            if (!std.mem.eql(u8, &got, t.sha)) {
                message.* = try std.fmt.allocPrint(arena, "hackage: {s} does not match hackage.lock (lock {s}, got {s})", .{ t.file, t.sha, &got });
                return error.DownloadFailed;
            }
            std.Io.Dir.cwd().rename(t.part, std.Io.Dir.cwd(), try std.fs.path.join(arena, &.{ store, t.file }), io) catch return error.DownloadFailed;
        }
    }
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{out_path});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = data }) catch return error.DownloadFailed;
    std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), out_path, io) catch return error.DownloadFailed;
    return .downloaded;
}

/// The shell lines that make `.dkhackage/` in the source's top directory:
/// links to the store as the sandbox sees it (/dkdeps/hackage).
pub fn layScript(arena: Allocator, pkgs: []const Pkg) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "mkdir -p .dkhackage\n");
    for (pkgs) |p| {
        const tb = try p.tarball(arena);
        try s.appendSlice(arena, try std.fmt.allocPrint(arena, "ln -sfn '/dkdeps/hackage/{0s}' '.dkhackage/{0s}'\n", .{tb}));
        if (p.cabal_sha256 != null)
            try s.appendSlice(arena, try std.fmt.allocPrint(arena, "ln -sfn '/dkdeps/hackage/{s}' '.dkhackage/{s}-{s}.cabal'\n", .{ try p.cabalFile(arena), p.name, p.version }));
    }
    return s.items;
}

/// The build environment: a private CABAL_DIR whose only repository is
/// .dkhackage, offline; DKBUILD_HACKAGE for builds that unpack the tarballs
/// themselves (Setup.hs, Hadrian's bootstrap).
pub const env =
    \\export CABAL_DIR=/tmp/cabal DKBUILD_HACKAGE="$srcdir/.dkhackage"
    \\mkdir -p /tmp/cabal
    \\printf 'repository dkbuild\n  url: file+noindex://%s\n\nactive-repositories: dkbuild\noffline: True\njobs: %s\n' "$srcdir/.dkhackage" "$jobs" > /tmp/cabal/config
    \\
;

test "parse: a lock with a revision, a comment and a blank line" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var msg: []const u8 = "";
    const lock =
        \\# made by dkbuild hackage-lock
        \\aeson 2.2.3.0 5ec5a3d0e9e64bb7b9cf3cd8e64ee5f1e2a3a2e3e4b5c6d7e8f9a0b1c2d3e4f5 2 011fa2d67d7a821aa5ec5c825adc919bb067d42dde8fac7c6e5db23239a58866
        \\
        \\parsec 3.1.18.0 a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2 0 -
        \\
    ;
    const pkgs = try parse(a, lock, &msg);
    try std.testing.expectEqual(@as(usize, 2), pkgs.len);
    try std.testing.expectEqualStrings("aeson", pkgs[0].name);
    try std.testing.expectEqual(@as(u32, 2), pkgs[0].revision);
    try std.testing.expectEqualStrings("aeson-2.2.3.0-r2.cabal", try pkgs[0].cabalFile(a));
    try std.testing.expect(pkgs[1].cabal_sha256 == null);
}

test "parse: revision 0 must not name a .cabal, a revision must" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var msg: []const u8 = "";
    const h = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2";
    try std.testing.expectError(error.BadLock, parse(a, "x 1.0 " ++ h ++ " 0 " ++ h ++ "\n", &msg));
    try std.testing.expectError(error.BadLock, parse(a, "x 1.0 " ++ h ++ " 1 -\n", &msg));
    try std.testing.expectError(error.BadLock, parse(a, "x 1.0 nothex 0 -\n", &msg));
}

test "layScript: tarball links, and the revision's .cabal under cabal's name" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const s = try layScript(a, &.{.{ .name = "aeson", .version = "2.2.3.0", .sha256 = "", .revision = 2, .cabal_sha256 = "x" }});
    try std.testing.expect(std.mem.indexOf(u8, s, "'/dkdeps/hackage/aeson-2.2.3.0.tar.gz' '.dkhackage/aeson-2.2.3.0.tar.gz'") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "'/dkdeps/hackage/aeson-2.2.3.0-r2.cabal' '.dkhackage/aeson-2.2.3.0.cabal'") != null);
}
