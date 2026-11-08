//! Rebuild decisions (SPEC.md 7.2).
//!
//! Each built package gets a record next to it in repo/<arch>/<name>.dkhash:
//! the version it was built as, a hash of its own inputs (recipe, patches,
//! files, architecture profile), a hash of what was in its build root, and a
//! hash of what it produced (`output`). Own inputs changing under the same
//! version-release is an error; its build root changing means a rebuild.
//!
//! The build root is hashed by the *outputs* of the packages laid into it, not
//! by their recipes: when a dependency is rebuilt and comes out identical (a
//! new build tool, a comment), nothing above it is rebuilt (early cutoff). A
//! build that is not reproducible (it embeds a date, say) just never cuts off:
//! its dependents rebuild, as they would without this.

const std = @import("std");
const recipe = @import("recipe.zig");
const tree = @import("tree.zig");
const fetch = @import("fetch.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hex = [64]u8;

pub const Record = struct {
    /// `<version>-r<release>`
    version: []const u8,
    inputs: Hex,
    deps: Hex,
    /// What the build produced (`outputHash`); absent in records from before it.
    output: ?Hex = null,
    /// The part of it a package building against it can see (`outputHash`).
    interface: ?Hex = null,
};

/// What a build produced, two ways (outputHash).
pub const Produced = struct { output: Hex, interface: Hex };

pub const Decision = enum {
    /// Never built, or built as another version: build it.
    build,
    /// Same version, same inputs, same dependencies, package present.
    up_to_date,
    /// Same version, same inputs, but built against different dependencies.
    rebuild_deps,
    /// Same version-release but the recipe's own inputs changed.
    unchanged_release,
};

pub fn decide(rec: ?Record, version: []const u8, inputs: Hex, deps: Hex, package_exists: bool) Decision {
    const r = rec orelse return .build;
    if (!package_exists or !std.mem.eql(u8, r.version, version)) return .build;
    if (!std.mem.eql(u8, &r.inputs, &inputs)) return .unchanged_release;
    if (!std.mem.eql(u8, &r.deps, &deps)) return .rebuild_deps;
    return .up_to_date;
}

pub fn format(arena: Allocator, r: Record) Allocator.Error![]const u8 {
    const base = try std.fmt.allocPrint(arena, "version: {s}\ninputs: {s}\ndeps: {s}\n", .{ r.version, &r.inputs, &r.deps });
    const o = r.output orelse return base;
    const with_output = try std.fmt.allocPrint(arena, "{s}output: {s}\n", .{ base, &o });
    const i = r.interface orelse return with_output;
    return std.fmt.allocPrint(arena, "{s}interface: {s}\n", .{ with_output, &i });
}

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!?Record {
    var version: ?[]const u8 = null;
    var inputs: ?Hex = null;
    var deps: ?Hex = null;
    var output: ?Hex = null;
    var interface: ?Hex = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const key = line[0..colon];
        const val = line[colon + 2 ..];
        if (std.mem.eql(u8, key, "version")) version = try arena.dupe(u8, val);
        if (std.mem.eql(u8, key, "inputs") and val.len == 64) inputs = val[0..64].*;
        if (std.mem.eql(u8, key, "deps") and val.len == 64) deps = val[0..64].*;
        if (std.mem.eql(u8, key, "output") and val.len == 64) output = val[0..64].*;
        if (std.mem.eql(u8, key, "interface") and val.len == 64) interface = val[0..64].*;
    }
    return .{ .version = version orelse return null, .inputs = inputs orelse return null, .deps = deps orelse return null, .output = output, .interface = interface };
}

fn hashFileInto(h: *Sha256, arena: Allocator, io: std.Io, path: []const u8, label: []const u8) !void {
    const data = Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    // Label and length first, so moving bytes between files changes the hash.
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, data.len, .little);
    h.update(label);
    h.update("\x00");
    h.update(&len);
    h.update(data);
}

/// Hash of a recipe's own inputs: package.toml, everything under patches/ and
/// files/ (names and contents, sorted), and the architecture profile.
pub fn ownHash(arena: Allocator, io: std.Io, root: []const u8, name: []const u8, arch: []const u8) !Hex {
    var h = Sha256.init(.{});
    const base = try recipe.dirPath(arena, root, name);
    try hashFileInto(&h, arena, io, try std.fs.path.join(arena, &.{ base, "package.toml" }), "package.toml");
    try hashFileInto(&h, arena, io, try std.fmt.allocPrint(arena, "{s}/profiles/{s}.toml", .{ root, arch }), "profile");

    for ([_][]const u8{ "patches", "files", "scripts" }) |sub| {
        const dir_path = try std.fs.path.join(arena, &.{ base, sub });
        var d = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var w = try d.walk(arena);
        defer w.deinit();
        while (try w.next(io)) |e| {
            if (e.kind == .file) try names.append(arena, try arena.dupe(u8, e.path));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |n| {
            try hashFileInto(&h, arena, io, try std.fs.path.join(arena, &.{ dir_path, n }), try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, n }));
        }
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// One package a build made: its name and the directory holding its files.
pub const Part = struct { name: []const u8, dir: []const u8 };

/// Hashes of what a build produced. `output`: for each package, every path with
/// its type, permission bits and contents (file data, link target), in sorted
/// order; timestamps and owners are left out, so an identical rebuild hashes
/// the same. `interface`: the same, except that a shared library in /usr/lib
/// counts as its soname and exported symbols, not its code: what a program
/// built against it can see. A library whose ELF can't be read counts whole.
pub fn outputHash(arena: Allocator, io: std.Io, parts: []const Part) !Produced {
    const Entry = struct { path: []const u8, kind: std.Io.File.Kind };
    var h = Sha256.init(.{});
    var hi = Sha256.init(.{});
    for (parts) |p| {
        for ([_]*Sha256{ &h, &hi }) |x| {
            x.update("package\x00");
            x.update(p.name);
            x.update("\x00");
        }
        var d = Dir.cwd().openDir(io, p.dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var entries: std.ArrayList(Entry) = .empty;
        var w = try d.walk(arena);
        defer w.deinit();
        while (try w.next(io)) |e| try entries.append(arena, .{ .path = try arena.dupe(u8, e.path), .kind = e.kind });
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lt);
        for (entries.items) |e| {
            var line: []const u8 = "o";
            var iface: ?[]const u8 = null;
            switch (e.kind) {
                .sym_link => {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const n = try d.readLink(io, e.path, &buf);
                    line = try std.fmt.allocPrint(arena, "l {s}", .{buf[0..n]});
                },
                .directory, .file => {
                    const st = try d.statFile(io, e.path, .{ .follow_symlinks = false });
                    const mode = st.permissions.toMode() & 0o7777;
                    if (e.kind == .directory) {
                        line = try std.fmt.allocPrint(arena, "d {o}", .{mode});
                    } else {
                        const full = try std.fs.path.join(arena, &.{ p.dir, e.path });
                        line = try std.fmt.allocPrint(arena, "f {o} {s}", .{ mode, &(try fetch.hashFile(io, full)) });
                        if (isSharedLibPath(e.path)) {
                            if (try sharedLibInterface(arena, io, full)) |si| iface = try std.fmt.allocPrint(arena, "s {o} {s}", .{ mode, si });
                        }
                    }
                },
                else => {},
            }
            for ([_]*Sha256{ &h, &hi }) |x| {
                x.update(e.path);
                x.update("\x00");
            }
            h.update(line);
            hi.update(iface orelse line);
            h.update("\n");
            hi.update("\n");
        }
    }
    return .{ .output = std.fmt.bytesToHex(h.finalResult(), .lower), .interface = std.fmt.bytesToHex(hi.finalResult(), .lower) };
}

/// A shared library's file (not its links): in usr/lib, named *.so or *.so.*.
fn isSharedLibPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "usr/lib/")) return false;
    const base = std.fs.path.basename(path);
    return std.mem.endsWith(u8, base, ".so") or std.mem.indexOf(u8, base, ".so.") != null;
}

/// The interface of a 64-bit little-endian ELF shared object: its soname and
/// its exported symbols (defined, global or weak, default or protected
/// visibility; with type, and size for data, whose size is part of the ABI),
/// sorted. Null when the file is not such an object: then it counts whole.
fn sharedLibInterface(arena: Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const data = Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch return null;
    return elfInterface(arena, data);
}

fn elfInterface(arena: Allocator, data: []const u8) Allocator.Error!?[]const u8 {
    const rd = struct {
        fn int(comptime T: type, d: []const u8, off: usize) ?T {
            if (off + @sizeOf(T) > d.len) return null;
            return std.mem.readInt(T, d[off..][0..@sizeOf(T)], .little);
        }
        fn cstr(d: []const u8, off: usize) ?[]const u8 {
            if (off >= d.len) return null;
            const end = std.mem.indexOfScalarPos(u8, d, off, 0) orelse return null;
            return d[off..end];
        }
    };
    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF") or data[4] != 2 or data[5] != 1) return null;
    if ((rd.int(u16, data, 16) orelse return null) != 3) return null; // ET_DYN
    const shoff = rd.int(u64, data, 0x28) orelse return null;
    const shentsize = rd.int(u16, data, 0x3A) orelse return null;
    const shnum = rd.int(u16, data, 0x3C) orelse return null;
    if (shentsize < 64) return null;
    var syms: std.ArrayList([]const u8) = .empty;
    var soname: []const u8 = "";
    var found_dynsym = false;
    var k: usize = 0;
    while (k < shnum) : (k += 1) {
        const sh = shoff + k * shentsize;
        const typ = rd.int(u32, data, sh + 4) orelse return null;
        if (typ != 11 and typ != 6) continue; // SHT_DYNSYM, SHT_DYNAMIC
        const off = rd.int(u64, data, sh + 0x18) orelse return null;
        const size = rd.int(u64, data, sh + 0x20) orelse return null;
        const link = rd.int(u32, data, sh + 0x28) orelse return null;
        const strsh = shoff + @as(u64, link) * shentsize;
        const stroff = rd.int(u64, data, strsh + 0x18) orelse return null;
        if (off + size > data.len) return null;
        if (typ == 6) {
            var e: u64 = 0;
            while (e + 16 <= size) : (e += 16) {
                const tag = rd.int(i64, data, off + e) orelse break;
                if (tag == 0) break;
                if (tag == 14) soname = rd.cstr(data, stroff + (rd.int(u64, data, off + e + 8) orelse 0)) orelse ""; // DT_SONAME
            }
            continue;
        }
        found_dynsym = true;
        var s: u64 = 24;
        while (s + 24 <= size) : (s += 24) {
            const y = off + s;
            const info = data[y + 4];
            const other = data[y + 5];
            const shndx = rd.int(u16, data, y + 6) orelse 0;
            const bind = info >> 4;
            const styp = info & 0xf;
            const vis = other & 3;
            if (shndx == 0) continue; // undefined: imported, not exported
            if (bind != 1 and bind != 2 and bind != 10) continue; // GLOBAL, WEAK, GNU_UNIQUE
            if (vis != 0 and vis != 3) continue; // DEFAULT, PROTECTED
            const name = rd.cstr(data, stroff + (rd.int(u32, data, y) orelse 0)) orelse continue;
            const ssize = rd.int(u64, data, y + 16) orelse 0;
            try syms.append(arena, if (styp == 1 or styp == 6)
                try std.fmt.allocPrint(arena, "{s} {d} {d}", .{ name, styp, ssize }) // data, TLS: size matters
            else
                try std.fmt.allocPrint(arena, "{s} {d}", .{ name, styp }));
        }
    }
    if (!found_dynsym) return null;
    std.mem.sort([]const u8, syms.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var hh = Sha256.init(.{});
    hh.update(soname);
    for (syms.items) |y| {
        hh.update("\n");
        hh.update(y);
    }
    return try std.fmt.allocPrint(arena, "{s} {s}", .{ soname, &std.fmt.bytesToHex(hh.finalResult(), .lower) });
}

/// Hash of a build root: the packages laid into it from repo/ (`tree.needs`),
/// each by name and by what it produced (`produced`, from the records; null
/// for one never built, or recorded before outputs were). The tools the build
/// runs (its `hostdeps`, and what they need) count by their whole output: a
/// changed compiler changes what it makes. Everything else counts by its
/// interface: a change inside a library's code does not rebuild what links
/// against it. The build tools of those packages are not in a build root, so
/// they are not part of this.
pub fn buildRootHash(arena: Allocator, t: tree.Tree, produced: []const ?Produced, idx: usize) !Hex {
    const members = try arena.dupe(usize, try t.needs(arena, idx));
    const tools = try t.needsOf(arena, idx, &.{t.recipes[idx].hostdeps});
    std.mem.sort(usize, members, t, struct {
        fn lt(tt: tree.Tree, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, tt.recipes[a].name, tt.recipes[b].name);
        }
    }.lt);
    var h = Sha256.init(.{});
    for (members) |m| {
        const is_tool = std.mem.indexOfScalar(usize, tools, m) != null;
        h.update(t.recipes[m].name);
        h.update(if (is_tool) " tool " else " lib ");
        if (produced[m]) |p| h.update(if (is_tool) &p.output else &p.interface) else h.update("none");
        h.update("\n");
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

// ---- tests ----

fn hx(c: u8) Hex {
    return @as(Hex, @splat(c));
}

test "decide: new, unchanged, dependency change, recipe change without a release" {
    const rec: Record = .{ .version = "1.0-r1", .inputs = hx('a'), .deps = hx('b') };
    try std.testing.expectEqual(Decision.build, decide(null, "1.0-r1", hx('a'), hx('b'), true));
    try std.testing.expectEqual(Decision.build, decide(rec, "1.0-r1", hx('a'), hx('b'), false));
    try std.testing.expectEqual(Decision.build, decide(rec, "1.0-r2", hx('z'), hx('b'), true));
    try std.testing.expectEqual(Decision.up_to_date, decide(rec, "1.0-r1", hx('a'), hx('b'), true));
    try std.testing.expectEqual(Decision.rebuild_deps, decide(rec, "1.0-r1", hx('a'), hx('c'), true));
    try std.testing.expectEqual(Decision.unchanged_release, decide(rec, "1.0-r1", hx('z'), hx('b'), true));
}

test "records round-trip and bad records are rejected" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const rec: Record = .{ .version = "2.03.35-r1", .inputs = hx('1'), .deps = hx('2') };
    const back = (try parse(a, try format(a, rec))).?;
    try std.testing.expectEqualStrings("2.03.35-r1", back.version);
    try std.testing.expectEqualSlices(u8, &rec.inputs, &back.inputs);
    try std.testing.expectEqualSlices(u8, &rec.deps, &back.deps);
    try std.testing.expect((try parse(a, "version: 1\ninputs: short\ndeps: x\n")) == null);
    try std.testing.expect((try parse(a, "")) == null);
}

test "buildRootHash: outputs of what is in the build root; a dependency's build tools don't count" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const R = @import("recipe.zig").Recipe;
    const mk = struct {
        fn f(name: []const u8, host: []const []const u8, build: []const []const u8) R {
            return .{ .name = name, .version = "1", .release = 1, .summary = "s", .license = "MIT", .source = &.{}, .install = "x", .hostdeps = host, .builddeps = build };
        }
    }.f;
    // app builds against lib; lib builds against base and with the tool rsync.
    const t: tree.Tree = .{ .recipes = &.{ mk("app", &.{}, &.{"lib"}), mk("lib", &.{"rsync"}, &.{"base"}), mk("rsync", &.{}, &.{}), mk("base", &.{}, &.{}), mk("other", &.{}, &.{}) } };
    const pr = struct {
        fn f(c: u8) ?Produced {
            return .{ .output = hx(c), .interface = hx(c) };
        }
    }.f;
    const out = [_]?Produced{ pr('a'), pr('b'), pr('c'), pr('d'), pr('e') };
    const h1 = try buildRootHash(a, t, &out, 0);
    var o2 = out;
    o2[2] = pr('z'); // lib's build tool: not in app's build root
    o2[4] = pr('z'); // unrelated
    o2[0] = pr('z'); // app itself
    try std.testing.expectEqualSlices(u8, &h1, &(try buildRootHash(a, t, &o2, 0)));
    o2[3] = pr('z'); // base: lib's dependency, laid into app's root with lib
    try std.testing.expect(!std.mem.eql(u8, &h1, &(try buildRootHash(a, t, &o2, 0))));
    var o3 = out;
    o3[1] = null; // lib never built (or recorded before outputs)
    try std.testing.expect(!std.mem.eql(u8, &h1, &(try buildRootHash(a, t, &o3, 0))));
    // A library's code changing (same interface) does not count; its interface does.
    var o4 = out;
    o4[1] = .{ .output = hx('y'), .interface = hx('b') };
    try std.testing.expectEqualSlices(u8, &h1, &(try buildRootHash(a, t, &o4, 0)));
    o4[1] = .{ .output = hx('y'), .interface = hx('y') };
    try std.testing.expect(!std.mem.eql(u8, &h1, &(try buildRootHash(a, t, &o4, 0))));
}

test "buildRootHash: a tool counts by its whole output" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const R = @import("recipe.zig").Recipe;
    const t: tree.Tree = .{ .recipes = &.{
        .{ .name = "app", .version = "1", .release = 1, .summary = "s", .license = "MIT", .source = &.{}, .install = "x", .hostdeps = &.{"cc"} },
        R{ .name = "cc", .version = "1", .release = 1, .summary = "s", .license = "MIT", .source = &.{}, .install = "x" },
    } };
    const before = [_]?Produced{ null, .{ .output = hx('a'), .interface = hx('i') } };
    const after = [_]?Produced{ null, .{ .output = hx('b'), .interface = hx('i') } };
    try std.testing.expect(!std.mem.eql(u8, &(try buildRootHash(a, t, &before, 0)), &(try buildRootHash(a, t, &after, 0))));
}

test "elfInterface: not ELF, or not a shared object, counts whole" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    try std.testing.expect((try elfInterface(st.allocator(), "not an elf file at all, just text")) == null);
}

test "outputHash: contents, modes and links count; nothing else" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "p/usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "p/usr/bin/x", .data = "hello" });
    try tmp.dir.symLink(io, "x", "p/usr/bin/y", .{});
    const base = try tmp.dir.realPathFileAlloc(io, "p", a);
    const parts = [_]Part{.{ .name = "pkg", .dir = base }};
    const h1 = (try outputHash(a, io, &parts)).output;
    try std.testing.expectEqualSlices(u8, &h1, &(try outputHash(a, io, &parts)).output);
    try tmp.dir.writeFile(io, .{ .sub_path = "p/usr/bin/x", .data = "hellp" });
    const h2 = try outputHash(a, io, &parts);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2.output));
    // Not a shared library: the interface is the whole file too.
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2.interface));
    const renamed = [_]Part{.{ .name = "pkg-libs", .dir = base }};
    try std.testing.expect(!std.mem.eql(u8, &h2.output, &(try outputHash(a, io, &renamed)).output));
}

test "elfInterface reads a real shared library's soname and exports (when the host has one)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    const data = Dir.cwd().readFileAlloc(io, "/usr/lib/x86_64-linux-gnu/libz.so.1", a, .limited(1 << 24)) catch return error.SkipZigTest;
    const got = (try elfInterface(a, data)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, got, "libz.so.1 "));
}
