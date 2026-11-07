//! Rebuild decisions (SPEC.md 7.2).
//!
//! Each built package gets a record next to it in repo/<arch>/<name>.dkhash:
//! the version it was built as, a hash of its own inputs (recipe, patches,
//! files, architecture profile) and a hash of the in-tree packages it was built
//! against. Own inputs changing under the same version-release is an error;
//! the packages it builds against changing only means a rebuild.

const std = @import("std");
const recipe = @import("recipe.zig");
const tree = @import("tree.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hex = [64]u8;

pub const Record = struct {
    /// `<version>-r<release>`
    version: []const u8,
    inputs: Hex,
    deps: Hex,
};

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
    return std.fmt.allocPrint(arena, "version: {s}\ninputs: {s}\ndeps: {s}\n", .{ r.version, &r.inputs, &r.deps });
}

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!?Record {
    var version: ?[]const u8 = null;
    var inputs: ?Hex = null;
    var deps: ?Hex = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const key = line[0..colon];
        const val = line[colon + 2 ..];
        if (std.mem.eql(u8, key, "version")) version = try arena.dupe(u8, val);
        if (std.mem.eql(u8, key, "inputs") and val.len == 64) inputs = val[0..64].*;
        if (std.mem.eql(u8, key, "deps") and val.len == 64) deps = val[0..64].*;
    }
    return .{ .version = version orelse return null, .inputs = inputs orelse return null, .deps = deps orelse return null };
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

/// Hash over the in-tree packages `name` is built against (its build
/// dependencies, transitively): their names, versions and own hashes.
pub fn depsHash(arena: Allocator, t: tree.Tree, own: []const Hex, idx: usize) !Hex {
    var seen = try arena.alloc(bool, t.recipes.len);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    try stack.append(arena, idx);
    seen[idx] = true;
    var members: std.ArrayList(usize) = .empty;
    while (stack.pop()) |i| {
        const r = t.recipes[i];
        for ([_][]const []const u8{ r.hostdeps, r.builddeps }) |deps| {
            for (deps) |d| {
                const p = t.provider(d) orelse continue;
                if (seen[p]) continue;
                seen[p] = true;
                try members.append(arena, p);
                try stack.append(arena, p);
            }
        }
    }
    std.mem.sort(usize, members.items, t, struct {
        fn lt(tt: tree.Tree, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, tt.recipes[a].name, tt.recipes[b].name);
        }
    }.lt);
    var h = Sha256.init(.{});
    for (members.items) |m| {
        const r = t.recipes[m];
        h.update(try std.fmt.allocPrint(arena, "{s} {s}-r{d} {s}\n", .{ r.name, r.version, r.release, &own[m] }));
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

test "depsHash follows build dependencies transitively and ignores unrelated recipes" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const R = @import("recipe.zig").Recipe;
    const mk = struct {
        fn f(name: []const u8, build: []const []const u8) R {
            return .{ .name = name, .version = "1", .release = 1, .summary = "s", .license = "MIT", .source = &.{}, .install = "x", .builddeps = build };
        }
    }.f;
    const t: tree.Tree = .{ .recipes = &.{ mk("app", &.{"lib"}), mk("lib", &.{"base"}), mk("other", &.{}), mk("base", &.{}) } };
    const own = [_]Hex{ hx('a'), hx('b'), hx('c'), hx('d') };
    const h1 = try depsHash(a, t, &own, 0);
    // Changing an unrelated recipe doesn't matter; changing base (two levels down) does.
    var own2 = own;
    own2[2] = hx('z');
    try std.testing.expectEqualSlices(u8, &h1, &(try depsHash(a, t, &own2, 0)));
    own2[3] = hx('z');
    try std.testing.expect(!std.mem.eql(u8, &h1, &(try depsHash(a, t, &own2, 0))));
    // The package's own hash isn't part of its deps hash.
    var own3 = own;
    own3[0] = hx('z');
    try std.testing.expectEqualSlices(u8, &h1, &(try depsHash(a, t, &own3, 0)));
}
