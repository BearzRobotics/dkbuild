//! Subpackage splitting (SPEC.md 5.7). Every file in `$pkgdir` ends up in
//! exactly one package: the first subpackage with a matching path, or the
//! main package.

const std = @import("std");
const recipe = @import("recipe.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

/// The subpackages every recipe gets unless it redefines them by name.
pub const defaults = [_]recipe.Subpackage{
    .{
        .name = "devel",
        .summary = "Headers and development files",
        .paths = &.{ "/usr/include", "/usr/lib/*.so", "/usr/lib/pkgconfig", "/usr/share/pkgconfig", "/usr/lib/cmake", "/usr/share/aclocal" },
    },
    .{
        .name = "static",
        .summary = "Static libraries",
        .paths = &.{"/usr/lib/*.a"},
    },
    .{
        .name = "doc",
        .summary = "Manual pages and documentation",
        .paths = &.{ "/usr/share/man", "/usr/share/doc", "/usr/share/info" },
    },
    // Only made when the package also ships programs (see `run`); a package that is
    // just a library keeps its libraries in the main package.
    .{
        .name = "libs",
        .summary = "Shared libraries",
        .paths = &.{ "/usr/lib/*.so.*", "/usr/lib/*.so" },
    },
};

/// Declared subpackages first, in order, then the defaults they didn't replace.
pub fn merge(arena: Allocator, declared: []const recipe.Subpackage) Allocator.Error![]const recipe.Subpackage {
    var list: std.ArrayList(recipe.Subpackage) = .empty;
    try list.appendSlice(arena, declared);
    outer: for (defaults) |d| {
        for (declared) |x| if (std.mem.eql(u8, x.name, d.name)) continue :outer;
        try list.append(arena, d);
    }
    return list.items;
}

/// Does `pattern` match `path`? Both without a leading '/'. `*` matches any
/// run of characters inside one path component.
pub fn glob(pattern: []const u8, path: []const u8) bool {
    var p = std.mem.splitScalar(u8, pattern, '/');
    var s = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const pc = p.next();
        const sc = s.next();
        if (pc == null or sc == null) return pc == null and sc == null;
        if (!globComponent(pc.?, sc.?)) return false;
    }
}

fn globComponent(pat: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (ni < name.len) {
        if (pi < pat.len and pat[pi] == '*') {
            star = pi;
            mark = ni;
            pi += 1;
        } else if (pi < pat.len and pat[pi] == name[ni]) {
            pi += 1;
            ni += 1;
        } else if (star) |s| {
            pi = s + 1;
            mark += 1;
            ni = mark;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

/// True when `pattern` matches `path` itself or a directory above it.
pub fn covers(pattern: []const u8, path: []const u8) bool {
    const pat = std.mem.trim(u8, pattern, "/");
    var end: usize = 0;
    while (true) {
        const next = std.mem.indexOfScalarPos(u8, path, end, '/');
        const prefix = path[0 .. next orelse path.len];
        if (glob(pat, prefix)) return true;
        if (next == null) return false;
        end = next.? + 1;
    }
}

/// Index of the first subpackage that claims `path`. A "*.so" pattern means the
/// development symlink (libfoo.so -> libfoo.so.1), so it does not claim a regular
/// file (gettext's libgettextlib-0.24.so, which programs load at run time) unless
/// the subpackage is "libs", the one that holds libraries. A path without a
/// '*' names its file exactly and claims it either way (libedit's readline
/// linker scripts, PostgreSQL's pltcl.so).
fn owner(subs: []const recipe.Subpackage, path: []const u8, is_regular: bool) ?usize {
    for (subs, 0..) |sp, i| {
        for (sp.paths) |pat| {
            if (!covers(pat, path)) continue;
            if (is_regular and std.mem.endsWith(u8, pat, ".so") and std.mem.indexOfScalar(u8, pat, '*') != null and !std.mem.eql(u8, sp.name, "libs")) continue;
            return i;
        }
    }
    return null;
}

/// Does the tree hold programs (as opposed to being only a library)?
fn hasPrograms(files: []const []const u8) bool {
    for (files) |f| {
        for ([_][]const u8{ "usr/bin/", "usr/sbin/", "bin/", "sbin/" }) |pre| {
            if (std.mem.startsWith(u8, f, pre)) return true;
        }
    }
    return false;
}

pub const Moved = struct { name: []const u8, files: usize };

/// Moves files out of `destdir` into `<out>/<sub.name>/`. Returns how many
/// files each subpackage got; subpackages that got none have no directory.
pub fn run(arena: Allocator, io: std.Io, destdir: []const u8, out: []const u8, subs: []const recipe.Subpackage) ![]const Moved {
    var d = try Dir.cwd().openDir(io, destdir, .{ .iterate = true });
    defer d.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    // Regular files (not symlinks), same order as `files`: see the "*.so" rule below.
    var regular: std.ArrayList(bool) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    {
        var w = try d.walk(arena);
        defer w.deinit();
        while (try w.next(io)) |e| {
            const copy = try arena.dupe(u8, e.path);
            if (e.kind == .directory) try dirs.append(arena, copy) else {
                try files.append(arena, copy);
                try regular.append(arena, e.kind == .file);
            }
        }
    }

    // Directories that held a file moved out (and their parents): only these
    // may be removed afterwards. A directory a package installs empty on
    // purpose (/sys and /tmp in base-files, /var/empty for sshd) stays.
    var emptied = std.StringHashMap(void).init(arena);
    const counts = try arena.alloc(usize, subs.len);
    @memset(counts, 0);
    const split_libs = hasPrograms(files.items);
    for (files.items, regular.items) |f, is_regular| {
        const idx = owner(subs, f, is_regular) orelse continue;
        if (!split_libs and std.mem.eql(u8, subs[idx].name, "libs")) continue;
        const dest = try std.fs.path.join(arena, &.{ out, subs[idx].name, f });
        if (std.fs.path.dirname(dest)) |parent| try Dir.cwd().createDirPath(io, parent);
        try d.rename(f, Dir.cwd(), dest, io);
        counts[idx] += 1;
        var parent = std.fs.path.dirname(f);
        while (parent) |p| : (parent = std.fs.path.dirname(p)) try emptied.put(p, {});
    }

    // Remove the directories the moves emptied, deepest first.
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn longer(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.longer);
    for (dirs.items) |dn| if (emptied.contains(dn)) d.deleteDir(io, dn) catch {};

    var result: std.ArrayList(Moved) = .empty;
    for (subs, counts) |sp, c| {
        if (c > 0 or sp.empty) {
            if (c == 0) try Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ out, sp.name }));
            try result.append(arena, .{ .name = sp.name, .files = c });
        }
    }
    return result.items;
}

test "glob matches within components only" {
    try std.testing.expect(glob("usr/lib/*.a", "usr/lib/libz.a"));
    try std.testing.expect(!glob("usr/lib/*.a", "usr/lib/sub/libz.a"));
    try std.testing.expect(glob("usr/lib/*.so", "usr/lib/libz.so"));
    try std.testing.expect(!glob("usr/lib/*.so", "usr/lib/libz.so.1"));
    try std.testing.expect(glob("usr/lib/lib*.so.*", "usr/lib/libz.so.1.2"));
    try std.testing.expect(!glob("usr/include", "usr/include/x.h"));
}

test "covers matches a path or any directory above it" {
    try std.testing.expect(covers("/usr/include", "usr/include/zstd.h"));
    try std.testing.expect(covers("/usr/share/man", "usr/share/man/man1/zstd.1"));
    try std.testing.expect(covers("/usr/lib/*.a", "usr/lib/libzstd.a"));
    try std.testing.expect(!covers("/usr/lib/*.a", "usr/lib/libzstd.so.1"));
    try std.testing.expect(!covers("/usr/include", "usr/bin/zstd"));
}

test "declared subpackages replace defaults of the same name and come first" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const declared = [_]recipe.Subpackage{
        .{ .name = "devel", .summary = "mine", .paths = &.{"/usr/include"} },
        .{ .name = "tools", .summary = "t", .paths = &.{"/usr/bin/x"} },
    };
    const m = try merge(a, &declared);
    try std.testing.expectEqual(@as(usize, 5), m.len);
    try std.testing.expectEqualStrings("devel", m[0].name);
    try std.testing.expectEqualStrings("mine", m[0].summary);
    try std.testing.expectEqualStrings("tools", m[1].name);
    try std.testing.expectEqualStrings("static", m[2].name);
    try std.testing.expectEqualStrings("doc", m[3].name);
    try std.testing.expectEqualStrings("libs", m[4].name);
}

test "owner: .so patterns claim symlinks, and real .so files go to libs" {
    const subs = [_]recipe.Subpackage{
        .{ .name = "devel", .summary = "", .paths = &.{"/usr/lib/*.so"} },
        .{ .name = "libs", .summary = "", .paths = &.{ "/usr/lib/*.so.*", "/usr/lib/*.so" } },
    };
    try std.testing.expectEqual(@as(?usize, 0), owner(&subs, "usr/lib/libz.so", false));
    try std.testing.expectEqual(@as(?usize, 1), owner(&subs, "usr/lib/libgettextlib-0.24.so", true));
    try std.testing.expectEqual(@as(?usize, 1), owner(&subs, "usr/lib/libz.so.1", false));
    try std.testing.expect(hasPrograms(&.{ "usr/bin/msgfmt", "usr/lib/x.so.1" }));
    try std.testing.expect(!hasPrograms(&.{ "usr/lib/x.so.1", "usr/include/x.h" }));
}

test "owner: an exact .so path claims a regular file" {
    const subs = [_]recipe.Subpackage{
        .{ .name = "readline", .summary = "", .paths = &.{"/usr/lib/libreadline.so"} },
        .{ .name = "devel", .summary = "", .paths = &.{"/usr/lib/*.so"} },
        .{ .name = "libs", .summary = "", .paths = &.{ "/usr/lib/*.so.*", "/usr/lib/*.so" } },
    };
    try std.testing.expectEqual(@as(?usize, 0), owner(&subs, "usr/lib/libreadline.so", true));
    try std.testing.expectEqual(@as(?usize, 2), owner(&subs, "usr/lib/libgettextlib-0.24.so", true));
}

test "run removes only the directories moves emptied; empty ones a package made stay" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest/usr/include");
    try tmp.dir.writeFile(io, .{ .sub_path = "dest/usr/include/x.h", .data = "int x;" });
    try tmp.dir.createDirPath(io, "dest/sys");
    try tmp.dir.createDirPath(io, "dest/var/empty");
    try tmp.dir.createDirPath(io, "out");
    const dest = try tmp.dir.realPathFileAlloc(io, "dest", a);
    const out = try tmp.dir.realPathFileAlloc(io, "out", a);
    const moved = try run(a, io, dest, out, try merge(a, &.{}));
    try std.testing.expectEqual(@as(usize, 1), moved.len);
    try std.testing.expectEqualStrings("devel", moved[0].name);
    // The header moved to -devel, and the directories it left are gone ...
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "dest/usr/include", .{}));
    // ... but the empty directories the package installed on purpose stay.
    try tmp.dir.access(io, "dest/sys", .{});
    try tmp.dir.access(io, "dest/var/empty", .{});
}
