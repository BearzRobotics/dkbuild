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

/// What stays in a main package and is nothing its libraries read when they run: programs, documentation, what
/// only a build against it uses, shell completion and desktop entries, the files of its services, and modules for
/// scripting languages (a binding built on the library, not part of it).
const not_for_libraries = [_][]const u8{
    "usr/bin",                  "usr/sbin",                "bin",                      "sbin",
    "usr/include",              "usr/share/aclocal",       "usr/share/gir-1.0",        "usr/share/vala",
    "usr/lib/cmake",            "usr/lib/pkgconfig",       "usr/share/pkgconfig",      "usr/share/licenses",
    "usr/share/man",            "usr/share/doc",           "usr/share/info",           "usr/share/gtk-doc",
    "usr/share/examples",       "usr/share/locale",        "usr/share/bash-completion", "usr/share/zsh",
    "usr/share/fish",           "etc/bash_completion.d",   "usr/share/applications",   "usr/share/metainfo",
    "usr/share/appdata",        "usr/share/pixmaps",       "usr/share/icons/hicolor",  "etc/dinit.d",
    "usr/lib/dinit.d",          "etc/init.d",              "usr/lib/systemd",          "etc/logrotate.d",
    "etc/cron*",                "etc/pam.d",               "usr/lib/pam.d",            "etc/sysusers.d",
    "usr/lib/sysusers.d",       "etc/tmpfiles.d",          "usr/lib/tmpfiles.d",       "usr/lib/python3*/site-packages",
    "usr/lib/perl5/vendor_perl", "usr/lib/ruby*/vendor_ruby",
};

/// Could the libraries of a package need the file at `path` (no leading '/') when they run? Everything that is not
/// in `not_for_libraries`: schemas and other data, configuration, plugins, type libraries, helper programs.
pub fn forLibraries(path: []const u8) bool {
    // libtool's archives, and static libraries and headers a recipe left outside the usual places
    for ([_][]const u8{ ".la", ".a", ".h" }) |end| if (std.mem.endsWith(u8, path, end)) return false;
    for (not_for_libraries) |pat| if (covers(pat, path)) return false;
    return true;
}

/// The first (by name) file or link under `destdir`, a main package after the split, that its libraries could need;
/// null when there is none. A package whose -libs is split off then has no need of it.
pub fn neededByLibraries(arena: Allocator, io: std.Io, destdir: []const u8) !?[]const u8 {
    var d = try Dir.cwd().openDir(io, destdir, .{ .iterate = true });
    defer d.close(io);
    var w = try d.walk(arena);
    defer w.deinit();
    var first: ?[]const u8 = null;
    while (try w.next(io)) |e| {
        if (e.kind == .directory or !forLibraries(e.path)) continue;
        if (first == null or std.mem.lessThan(u8, e.path, first.?)) first = try arena.dupe(u8, e.path);
    }
    return first;
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
    // The directories made in a subpackage, with the package's own: given their modes afterwards (one without
    // owner write could not be moved into).
    var made = std.StringHashMap([]const u8).init(arena); // new directory -> the one in destdir
    for (files.items, regular.items) |f, is_regular| {
        const idx = owner(subs, f, is_regular) orelse continue;
        if (!split_libs and std.mem.eql(u8, subs[idx].name, "libs")) continue;
        const dest = try std.fs.path.join(arena, &.{ out, subs[idx].name, f });
        if (std.fs.path.dirname(dest)) |parent| try Dir.cwd().createDirPath(io, parent);
        try made.put(try std.fs.path.join(arena, &.{ out, subs[idx].name }), "");
        var above = std.fs.path.dirname(f);
        while (above) |p| : (above = std.fs.path.dirname(p)) try made.put(try std.fs.path.join(arena, &.{ out, subs[idx].name, p }), p);
        try d.rename(f, Dir.cwd(), dest, io);
        counts[idx] += 1;
        var parent = std.fs.path.dirname(f);
        while (parent) |p| : (parent = std.fs.path.dirname(p)) try emptied.put(p, {});
    }

    // Each gets the mode the package gave that directory, before the emptied ones go; deepest first.
    {
        var names: std.ArrayList([]const u8) = .empty;
        var it = made.keyIterator();
        while (it.next()) |k| try names.append(arena, k.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn longer(_: void, a: []const u8, b: []const u8) bool {
                return a.len > b.len;
            }
        }.longer);
        for (names.items) |n| {
            const from = made.get(n).?;
            const st = try d.statFile(io, if (from.len == 0) "." else from, .{});
            try Dir.cwd().setFilePermissions(io, n, st.permissions, .{});
        }
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

test "folders made in a subpackage keep the modes the package gave them (BC-12)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest/etc/secret");
    try tmp.dir.createDirPath(io, "out");
    try tmp.dir.writeFile(io, .{ .sub_path = "dest/etc/secret/key.conf", .data = "k" });
    try tmp.dir.setFilePermissions(io, "dest/etc/secret", .fromMode(0o700), .{});
    try tmp.dir.setFilePermissions(io, "dest/etc", .fromMode(0o750), .{});
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const subs = [_]recipe.Subpackage{.{ .name = "conf", .summary = "c", .paths = &.{"/etc/secret"} }};
    _ = try run(a, io, try std.fs.path.join(a, &.{ base, "dest" }), try std.fs.path.join(a, &.{ base, "out" }), &subs);
    for ([_]struct { p: []const u8, mode: u32 }{ .{ .p = "out/conf/etc", .mode = 0o750 }, .{ .p = "out/conf/etc/secret", .mode = 0o700 } }) |want| {
        const s = try tmp.dir.statFile(io, want.p, .{});
        try std.testing.expectEqual(want.mode, @as(u32, s.permissions.toMode()) & 0o7777);
    }
}

test "what a library could need from its main package" {
    for ([_][]const u8{
        "usr/share/glib-2.0/schemas/org.gtk.Settings.gschema.xml", "usr/lib/sane/libsane-x.so.1",
        "usr/lib/girepository-1.0/Gtk-4.0.typelib",                "usr/libexec/qmi-proxy",
        "etc/sane.d/dll.conf",                                     "usr/lib/udev/rules.d/49-sane.rules",
        "usr/share/openal/hrtf/Default HRTF.mhr",                  "usr/share/terminfo/x/xterm",
        "usr/lib/python3.14/encodings/__init__.py",                "usr/share/icons/Adwaita/index.theme",
    }) |p| try std.testing.expect(forLibraries(p));
    for ([_][]const u8{
        "usr/bin/tool",                       "usr/sbin/daemon",                                 "usr/share/licenses/x/COPYING",
        "usr/lib/libx.la",                    "usr/share/gir-1.0/X-1.0.gir",                     "usr/share/applications/x.desktop",
        "etc/dinit.d/saned",                  "usr/lib/tmpfiles.d/x.conf",                       "etc/cron.d/x",
        "usr/lib/python3.14/site-packages/x.py", "usr/share/locale/de/LC_MESSAGES/x.mo",        "usr/share/icons/hicolor/48x48/apps/x.png",
    }) |p| try std.testing.expect(!forLibraries(p));
}

test "neededByLibraries looks at files and links, not at empty folders" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "d/usr/bin");
    try tmp.dir.createDirPath(io, "d/var/lib/x");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/usr/bin/x", .data = "x" });
    const dest = try tmp.dir.realPathFileAlloc(io, "d", a);
    try std.testing.expectEqual(@as(?[]const u8, null), try neededByLibraries(a, io, dest));
    try tmp.dir.createDirPath(io, "d/usr/share/x");
    try tmp.dir.symLink(io, "../../bin/x", "d/usr/share/x/z", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "d/usr/share/x/b", .data = "x" });
    try std.testing.expectEqualStrings("usr/share/x/b", (try neededByLibraries(a, io, dest)).?);
}
