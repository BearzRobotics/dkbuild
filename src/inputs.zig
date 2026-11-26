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
    /// The build script with dkbuild's macros expanded (build.scriptHash): a
    /// change to a macro (`%configure`) rebuilds what uses it.
    script: ?Hex = null,
    /// Which `ownHash` `inputs` is: 1, before links and executable bits counted; 2 since.
    scheme: u8 = 2,
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
    const base = try std.fmt.allocPrint(arena, "version: {s}\ninputs: {s}\ndeps: {s}\nscheme: {d}\n", .{ r.version, &r.inputs, &r.deps, r.scheme });
    const o = r.output orelse return base;
    const with_output = try std.fmt.allocPrint(arena, "{s}output: {s}\n", .{ base, &o });
    const i = r.interface orelse return with_output;
    const with_interface = try std.fmt.allocPrint(arena, "{s}interface: {s}\n", .{ with_output, &i });
    const sc = r.script orelse return with_interface;
    return std.fmt.allocPrint(arena, "{s}script: {s}\n", .{ with_interface, &sc });
}

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!?Record {
    var version: ?[]const u8 = null;
    var inputs: ?Hex = null;
    var deps: ?Hex = null;
    var output: ?Hex = null;
    var interface: ?Hex = null;
    var script: ?Hex = null;
    var scheme: u8 = 1; // records from before it have no line
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
        if (std.mem.eql(u8, key, "script") and val.len == 64) script = val[0..64].*;
        if (std.mem.eql(u8, key, "scheme")) scheme = std.fmt.parseInt(u8, val, 10) catch 1;
    }
    return .{ .version = version orelse return null, .inputs = inputs orelse return null, .deps = deps orelse return null, .output = output, .interface = interface, .script = script, .scheme = scheme };
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
/// Symbolic links (with their targets) and executable bits count too: both change what is built. A recipe with
/// neither hashes as it did before they counted.
pub fn ownHash(arena: Allocator, io: std.Io, root: []const u8, name: []const u8, arch: []const u8) !Hex {
    return ownHashAs(arena, io, root, name, arch, true);
}

/// The hash as records of scheme 1 hold it.
fn ownHashWithout(arena: Allocator, io: std.Io, root: []const u8, name: []const u8, arch: []const u8) !Hex {
    return ownHashAs(arena, io, root, name, arch, false);
}

/// A record made before links and modes counted is compared the old way: if that matches, its `inputs` become
/// today's `own`, so that nothing is rebuilt or called edited just for the change of scheme.
pub fn adopt(arena: Allocator, io: std.Io, root: []const u8, name: []const u8, arch: []const u8, own: Hex, rec: *Record) !void {
    if (rec.scheme >= 2) return;
    const old = try ownHashWithout(arena, io, root, name, arch);
    if (std.mem.eql(u8, &old, &rec.inputs)) rec.inputs = own;
}

fn ownHashAs(arena: Allocator, io: std.Io, root: []const u8, name: []const u8, arch: []const u8, with_modes: bool) !Hex {
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
        var links: std.ArrayList([]const u8) = .empty;
        while (try w.next(io)) |e| {
            if (e.kind == .file) try names.append(arena, try arena.dupe(u8, e.path));
            if (e.kind == .sym_link) try links.append(arena, try arena.dupe(u8, e.path));
        }
        if (with_modes) {
            std.mem.sort([]const u8, links.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (links.items) |n| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const len = try d.readLink(io, n, &buf);
                // NUL cannot be in a path or a target, so these cannot run into one another
                for ([_][]const u8{ "link", sub, n, buf[0..len] }) |part| {
                    h.update(part);
                    h.update("\x00");
                }
            }
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |n| {
            try hashFileInto(&h, arena, io, try std.fs.path.join(arena, &.{ dir_path, n }), try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub, n }));
            if (with_modes and (try d.statFile(io, n, .{ .follow_symlinks = false })).permissions.toMode() & 0o111 != 0) {
                for ([_][]const u8{ "executable", sub, n }) |part| {
                    h.update(part);
                    h.update("\x00");
                }
            }
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
            if (off > d.len or d.len - off < @sizeOf(T)) return null;
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
    // Symbol versions, where the library has them: which version each dynamic symbol is, and their names.
    var versym: ?u64 = null;
    var versions: std.AutoHashMapUnmanaged(u16, []const u8) = .empty;
    {
        var k2: usize = 0;
        while (k2 < shnum) : (k2 += 1) {
            const sh = shoff +| @as(u64, k2) * shentsize;
            const typ = rd.int(u32, data, sh +| 4) orelse return null;
            const off = rd.int(u64, data, sh +| 0x18) orelse return null;
            if (typ == 0x6fffffff) versym = off; // SHT_GNU_versym
            if (typ != 0x6ffffffd) continue; // SHT_GNU_verdef
            const link = rd.int(u32, data, sh +| 0x28) orelse return null;
            const stroff = rd.int(u64, data, (shoff +| @as(u64, link) * shentsize) +| 0x18) orelse return null;
            var at = off;
            var n: usize = 0;
            while (n < 4096) : (n += 1) {
                const ndx = rd.int(u16, data, at +| 4) orelse break;
                const aux = rd.int(u32, data, at +| 12) orelse break;
                const name_off = rd.int(u32, data, at +| aux) orelse break;
                try versions.put(arena, ndx, rd.cstr(data, stroff +| name_off) orelse "");
                const next = rd.int(u32, data, at +| 16) orelse break;
                if (next == 0) break;
                at +|= next;
            }
        }
    }
    var syms: std.ArrayList([]const u8) = .empty;
    var soname: []const u8 = "";
    var found_dynsym = false;
    var k: usize = 0;
    while (k < shnum) : (k += 1) {
        const sh = shoff +| @as(u64, k) * shentsize; // saturating, as below: the file chose these
        const typ = rd.int(u32, data, sh +| 4) orelse return null;
        if (typ != 11 and typ != 6) continue; // SHT_DYNSYM, SHT_DYNAMIC
        const off = rd.int(u64, data, sh +| 0x18) orelse return null;
        const size = rd.int(u64, data, sh +| 0x20) orelse return null;
        const link = rd.int(u32, data, sh +| 0x28) orelse return null;
        const strsh = shoff +| @as(u64, link) * shentsize;
        const stroff = rd.int(u64, data, strsh +| 0x18) orelse return null;
        if (off > data.len or size > data.len - off) return null;
        if (typ == 6) {
            var e: u64 = 0;
            while (e + 16 <= size) : (e += 16) {
                const tag = rd.int(i64, data, off + e) orelse break;
                if (tag == 0) break;
                if (tag == 14) soname = rd.cstr(data, stroff +| (rd.int(u64, data, off + e + 8) orelse 0)) orelse ""; // DT_SONAME
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
            const name = rd.cstr(data, stroff +| (rd.int(u32, data, y) orelse 0)) orelse continue;
            const ssize = rd.int(u64, data, y + 16) orelse 0;
            // "@@V" for the version programs link against, "@V" for one kept for old programs; nothing for an
            // unversioned symbol, so that libraries without versions have the interface they had
            var version: []const u8 = "";
            if (versym) |vs| if (rd.int(u16, data, vs +| ((s / 24) * 2))) |v| if (versions.get(v & 0x7fff)) |vn| if (v & 0x7fff >= 2) {
                version = try std.fmt.allocPrint(arena, " {s}{s}", .{ if (v & 0x8000 != 0) "@" else "@@", vn });
            };
            try syms.append(arena, if (styp == 1 or styp == 6)
                try std.fmt.allocPrint(arena, "{s} {d} {d}{s}", .{ name, styp, ssize, version }) // data, TLS: size matters
            else
                try std.fmt.allocPrint(arena, "{s} {d}{s}", .{ name, styp, version }));
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
    // A `name=@built` depend names the very version and release in the build root: a new one, even with the same
    // files, changes the package that pins it. (Only recipes with such a depend get these lines.)
    for (t.recipes[idx].subpackages) |sp| for (sp.depends) |dep| {
        if (!std.mem.endsWith(u8, dep, "=@built")) continue;
        const p = t.provider(dep[0 .. dep.len - "=@built".len]) orelse continue;
        h.update(try std.fmt.allocPrint(arena, "pin {s} {s}-r{d}\n", .{ t.recipes[p].name, t.recipes[p].version, t.recipes[p].release }));
    };
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

test "a broken shared library counts whole instead of crashing (BC-14, SS-21)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const huge = std.math.maxInt(u64);
    // a header with one section: the section table's offset, then that section's offset, size and string link
    for ([_][4]u64{ .{ huge - 8, 11, 0, 0 }, .{ 64, 11, huge - 2, 48 }, .{ 64, 11, 32, huge }, .{ 64, 6, huge - 15, 64 } }) |c| {
        var d: [256]u8 = @splat(0);
        @memcpy(d[0..6], "\x7fELF\x02\x01");
        std.mem.writeInt(u16, d[16..18], 3, .little);
        std.mem.writeInt(u64, d[0x28..0x30], c[0], .little);
        std.mem.writeInt(u16, d[0x3A..0x3C], 64, .little);
        std.mem.writeInt(u16, d[0x3C..0x3E], 1, .little);
        std.mem.writeInt(u32, d[68..72], @intCast(c[1]), .little);
        std.mem.writeInt(u64, d[64 + 0x18 ..][0..8], c[2], .little);
        std.mem.writeInt(u64, d[64 + 0x20 ..][0..8], c[3], .little);
        _ = try elfInterface(st.allocator(), &d);
    }
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

test "links and executable bits are inputs; records from before still match (SS-11)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "packages/x/x/files");
    try tmp.dir.createDirPath(io, "profiles");
    try tmp.dir.writeFile(io, .{ .sub_path = "profiles/x86_64.toml", .data = "p" });
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/x/x/package.toml", .data = "r" });
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/x/x/files/run.sh", .data = "#!/bin/sh\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const plain = try ownHash(a, io, root, "x", "x86_64");
    // with neither, the hash is what it always was
    try std.testing.expectEqualSlices(u8, &plain, &(try ownHashWithout(a, io, root, "x", "x86_64")));
    try tmp.dir.setFilePermissions(io, "packages/x/x/files/run.sh", .fromMode(0o755), .{});
    const executable = try ownHash(a, io, root, "x", "x86_64");
    try std.testing.expect(!std.mem.eql(u8, &plain, &executable));
    try tmp.dir.symLink(io, "run.sh", "packages/x/x/files/active", .{});
    const linked = try ownHash(a, io, root, "x", "x86_64");
    try std.testing.expect(!std.mem.eql(u8, &executable, &linked));
    try tmp.dir.deleteFile(io, "packages/x/x/files/active");
    try tmp.dir.symLink(io, "other", "packages/x/x/files/active", .{});
    try std.testing.expect(!std.mem.eql(u8, &linked, &(try ownHash(a, io, root, "x", "x86_64"))));
    // a record from before (no scheme line) that matches the old way is taken as up to date
    const old_way = try ownHashWithout(a, io, root, "x", "x86_64");
    const old_text = try std.fmt.allocPrint(a, "version: 1-r1\ninputs: {s}\ndeps: {s}\n", .{ &old_way, &old_way });
    var rec = (try parse(a, old_text)).?;
    const now = try ownHash(a, io, root, "x", "x86_64");
    try adopt(a, io, root, "x", "x86_64", now, &rec);
    try std.testing.expectEqualSlices(u8, &now, &rec.inputs);
    // a new record is not: its hash already covers modes
    var new = (try parse(a, try format(a, .{ .version = "1-r1", .inputs = old_way, .deps = old_way }))).?;
    try adopt(a, io, root, "x", "x86_64", now, &new);
    try std.testing.expect(!std.mem.eql(u8, &now, &new.inputs));
    // and an old record of a recipe whose files changed since still differs
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/x/x/files/run.sh", .data = "#!/bin/sh\nedited\n" });
    var stale = (try parse(a, old_text)).?;
    const after = try ownHash(a, io, root, "x", "x86_64");
    try adopt(a, io, root, "x", "x86_64", after, &stale);
    try std.testing.expect(!std.mem.eql(u8, &after, &stale.inputs));
}

test "a symbol's version is part of a library's interface (BC-22)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "l.c", .data = "int dk_symbol(void) { return 1; }\n" });
    const S = struct {
        fn build(arena: Allocator, io_: std.Io, dir: []const u8, name: []const u8, script_text: ?[]const u8) !?[]const u8 {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ "zig", "cc", "-target", "x86_64-linux-musl", "-shared", "-fPIC", "-nostdlib", "-Wl,-soname,libdk.so.1", "-o", try std.fs.path.join(arena, &.{ dir, name }), try std.fs.path.join(arena, &.{ dir, "l.c" }) });
            if (script_text) |t| {
                const map = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}.map", .{name}) });
                try std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = map, .data = t });
                try argv.append(arena, try std.fmt.allocPrint(arena, "-Wl,--version-script={s}", .{map}));
            }
            const r = std.process.run(arena, io_, .{ .argv = argv.items }) catch return null;
            if (!(r.term == .exited and r.term.exited == 0)) return null;
            const data = try std.Io.Dir.cwd().readFileAlloc(io_, try std.fs.path.join(arena, &.{ dir, name }), arena, .limited(1 << 24));
            return try elfInterface(arena, data);
        }
    };
    const v1 = (try S.build(a, io, base, "v1.so", "V1 { global: dk_symbol; local: *; };\n")) orelse return error.SkipZigTest;
    const v1_again = (try S.build(a, io, base, "again.so", "V1 { global: dk_symbol; local: *; };\n")).?;
    const v2 = (try S.build(a, io, base, "v2.so", "V2 { global: dk_symbol; local: *; };\n")).?;
    const plain = (try S.build(a, io, base, "plain.so", null)).?;
    try std.testing.expectEqualStrings(v1, v1_again);
    try std.testing.expect(!std.mem.eql(u8, v1, v2)); // the same name under another version is another interface
    try std.testing.expect(!std.mem.eql(u8, v1, plain));
}
