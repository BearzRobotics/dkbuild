//! Python packages (PyPI), vendored at fetch time (SPEC.md 7.4).
//!
//! A recipe with the `pydeps` option keeps the pinned list in
//! files/python.lock, one file per line:
//!
//!     <name> <version> <sha256> <url>
//!
//! (`dkbuild python-lock` writes it from a uv.lock, pylock.toml or pinned
//! requirements file: a pure-Python wheel where there is one, else the
//! source distribution). The store, cache/python/, holds each file once under
//! its own name (the URL's last component), checked against the lock. Before
//! the build the source tree gets .dkpython/, links into the store, and the
//! environment makes it pip's and uv's only package source, offline. Nothing
//! from a package runs here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fetch = @import("fetch.zig");

pub const lock_name = "python.lock";

pub const Pkg = struct {
    name: []const u8,
    version: []const u8,
    sha256: []const u8,
    url: []const u8,

    pub fn file(p: Pkg) []const u8 {
        return p.url[(std.mem.lastIndexOfScalar(u8, p.url, '/') orelse 0) + 1 ..];
    }
};

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

fn validName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '+' or c == '!')) return false;
    return true;
}

/// Parses a python.lock. `#` starts a comment; blank lines are skipped.
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
        const p: Pkg = .{ .name = f.next() orelse "", .version = f.next() orelse "", .sha256 = f.next() orelse "", .url = f.next() orelse "" };
        if (!validName(p.name) or !validName(p.version) or !isHex64(p.sha256) or f.next() != null or
            !std.mem.startsWith(u8, p.url, "https://") or !validName(p.file()))
        {
            message.* = try std.fmt.allocPrint(arena, "python.lock line {d}: expected `<name> <version> <sha256> <https url>`", .{n});
            return error.BadLock;
        }
        try out.append(arena, p);
    }
    return out.items;
}

pub fn listPath(arena: Allocator, cache: []const u8, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/pydeps/{s}.list", .{ cache, key });
}

/// The sha256 (hex) of the lock's bytes: its list is named by it, so an
/// edited lock fetches again.
pub fn lockKey(arena: Allocator, data: []const u8) ![]const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.allocPrint(arena, "{x}", .{&h});
}

/// Downloads what the store lacks of the lock at `lock_path`, checking each
/// file against the lock, then writes cache/pydeps/<key>.list (a copy of the
/// lock; its presence means the fetch is complete).
pub fn fetchLock(arena: Allocator, io: std.Io, cache: []const u8, lock_path: []const u8, message: *[]const u8) fetch.Error!fetch.Status {
    const data = std.Io.Dir.cwd().readFileAlloc(io, lock_path, arena, .limited(1 << 22)) catch {
        message.* = try std.fmt.allocPrint(arena, "python: cannot read {s}", .{lock_path});
        return error.DownloadFailed;
    };
    const key = try lockKey(arena, data);
    const out_path = try listPath(arena, cache, key);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const pkgs = parse(arena, data, message) catch return error.DownloadFailed;
    const store = try std.fmt.allocPrint(arena, "{s}/python", .{cache});
    const dir = try std.fmt.allocPrint(arena, "{s}/pydeps", .{cache});
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, key });
    for ([_][]const u8{ store, tmp }) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return error.DownloadFailed;
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const Todo = struct { file: []const u8, url: []const u8, part: []const u8, sha: []const u8 };
    var todo: std.ArrayList(Todo) = .empty;
    for (pkgs) |p| {
        const store_file = try std.fs.path.join(arena, &.{ store, p.file() });
        if (std.Io.Dir.cwd().access(io, store_file, .{})) |_| {
            // already there (another lock, or python-lock): still checked,
            // since two different files must not share a name
            const got = fetch.hashFile(io, store_file) catch return error.DownloadFailed;
            if (std.mem.eql(u8, &got, p.sha256)) continue;
            message.* = try std.fmt.allocPrint(arena, "python: {s} in the store does not match python.lock (lock {s}, store {s})", .{ p.file(), p.sha256, &got });
            return error.DownloadFailed;
        } else |_| {}
        try todo.append(arena, .{ .file = p.file(), .url = p.url, .part = try std.fmt.allocPrint(arena, "{s}/dl-{d}", .{ tmp, todo.items.len }), .sha = p.sha256 });
    }
    if (todo.items.len > 0) {
        var cfg: std.ArrayList(u8) = .empty;
        for (todo.items) |t| try cfg.appendSlice(arena, try std.fmt.allocPrint(arena, "url = \"{s}\"\noutput = \"{s}\"\n", .{ t.url, t.part }));
        const cfgp = try std.fmt.allocPrint(arena, "{s}/curl.cfg", .{tmp});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgp, .data = cfg.items }) catch return error.DownloadFailed;
        const r = std.process.run(arena, io, .{ .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "3", "--parallel", "--parallel-max", "8", "-K", cfgp } }) catch return error.DownloadFailed;
        if (!(r.term == .exited and r.term.exited == 0)) {
            message.* = try std.fmt.allocPrint(arena, "python: downloads failed: {s}", .{std.mem.trim(u8, r.stderr, "\n ")});
            return error.DownloadFailed;
        }
        for (todo.items) |t| {
            const got = fetch.hashFile(io, t.part) catch return error.DownloadFailed;
            if (!std.mem.eql(u8, &got, t.sha)) {
                message.* = try std.fmt.allocPrint(arena, "python: {s} does not match python.lock (lock {s}, got {s})", .{ t.file, t.sha, &got });
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

/// The shell lines that make `.dkpython/` in the source's top directory:
/// links to the store as the sandbox sees it (/dkdeps/python).
pub fn layScript(arena: Allocator, pkgs: []const Pkg) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "mkdir -p .dkpython\n");
    for (pkgs) |p|
        try s.appendSlice(arena, try std.fmt.allocPrint(arena, "ln -sfn '/dkdeps/python/{0s}' '.dkpython/{0s}'\n", .{p.file()}));
    return s.items;
}

/// The build environment: pip and uv find packages only in .dkpython, never
/// on an index; builds use the installed build tools (no isolation, which
/// would download them). DKBUILD_PYTHON names the directory for other tools.
pub const env =
    \\export DKBUILD_PYTHON="$srcdir/.dkpython"
    // (pip reads PIP_NO_BUILD_ISOLATION=0 as --no-build-isolation)
    \\export PIP_NO_INDEX=1 PIP_FIND_LINKS="$srcdir/.dkpython" PIP_NO_BUILD_ISOLATION=0 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
    \\export UV_OFFLINE=1 UV_NO_INDEX=1 UV_FIND_LINKS="$srcdir/.dkpython" UV_NO_BUILD_ISOLATION=1 UV_NO_CACHE=1 UV_PYTHON_DOWNLOADS=never
    \\
;

test "parse: lines, comments, file names" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var msg: []const u8 = "";
    const h = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2";
    const lock = "# made by dkbuild python-lock\n" ++
        "django 5.2.8 " ++ h ++ " https://files.pythonhosted.org/packages/ab/cd/django-5.2.8-py3-none-any.whl\n" ++
        "#   sdist; build-system: setuptools\n\n" ++
        "lxml 6.0.2 " ++ h ++ " https://files.pythonhosted.org/packages/ef/01/lxml-6.0.2.tar.gz\n";
    const pkgs = try parse(a, lock, &msg);
    try std.testing.expectEqual(@as(usize, 2), pkgs.len);
    try std.testing.expectEqualStrings("django-5.2.8-py3-none-any.whl", pkgs[0].file());
    try std.testing.expectEqualStrings("lxml-6.0.2.tar.gz", pkgs[1].file());
    try std.testing.expect(std.mem.indexOf(u8, try layScript(a, pkgs), "'/dkdeps/python/lxml-6.0.2.tar.gz' '.dkpython/lxml-6.0.2.tar.gz'") != null);
}

test "parse: rejects http, bad sha and odd file names" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var msg: []const u8 = "";
    const h = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2";
    try std.testing.expectError(error.BadLock, parse(a, "x 1.0 " ++ h ++ " http://e.org/x-1.0.tar.gz\n", &msg));
    try std.testing.expectError(error.BadLock, parse(a, "x 1.0 nothex https://e.org/x-1.0.tar.gz\n", &msg));
    try std.testing.expectError(error.BadLock, parse(a, "x 1.0 " ++ h ++ " https://e.org/x'1.tar.gz\n", &msg));
    try std.testing.expectError(error.BadLock, parse(a, "x 1.0 " ++ h ++ "\n", &msg));
}
