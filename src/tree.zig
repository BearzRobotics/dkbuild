//! The recipe tree: loading every package and ordering builds (SPEC.md 7, 10).

const std = @import("std");
const recipe = @import("recipe.zig");
const split = @import("split.zig");
const Recipe = recipe.Recipe;
const Allocator = std.mem.Allocator;

pub const Problem = struct {
    /// Package directory name or file path the problem belongs to.
    where: []const u8,
    message: []const u8,
};

pub const Tree = struct {
    /// Sorted by name.
    recipes: []const Recipe,
    /// Dependencies that no recipe provides are not errors; they come from
    /// the bootstrap repositories (used by `pkg` until FenrirOS is self-hosting).
    allow_external: bool = false,

    pub fn find(t: Tree, name: []const u8) ?usize {
        for (t.recipes, 0..) |r, i| if (std.mem.eql(u8, r.name, name)) return i;
        return null;
    }

    /// The recipe that supplies `dep`: the recipe of that name, or the recipe
    /// whose default (`-devel`, `-static`, `-doc`) or declared subpackage it is.
    pub fn provider(t: Tree, dep: []const u8) ?usize {
        if (t.find(dep)) |i| return i;
        for (t.recipes, 0..) |r, i| {
            if (dep.len <= r.name.len + 1 or !std.mem.startsWith(u8, dep, r.name) or dep[r.name.len] != '-') continue;
            const suffix = dep[r.name.len + 1 ..];
            for (split.defaults) |d| if (std.mem.eql(u8, suffix, d.name)) return i;
            for (r.subpackages) |s| if (std.mem.eql(u8, s.name, suffix)) return i;
        }
        return null;
    }

    /// Build order for `roots` and everything they need: dependencies first.
    /// Needs are `hostdeps` and `builddeps`; `checkdeps` and `rundeps` don't
    /// have to exist before a package builds.
    pub fn order(t: Tree, arena: Allocator, roots: []const []const u8, problems: *std.ArrayList(Problem)) Allocator.Error![]const usize {
        const state = try arena.alloc(enum { new, active, done }, t.recipes.len);
        @memset(state, .new);
        var out: std.ArrayList(usize) = .empty;
        var stack: std.ArrayList(usize) = .empty;
        for (roots) |name| {
            const i = t.find(name) orelse {
                try problems.append(arena, .{ .where = name, .message = "not in the tree" });
                continue;
            };
            try t.visit(arena, i, state, &stack, &out, problems);
        }
        return out.toOwnedSlice(arena);
    }

    fn visit(t: Tree, arena: Allocator, i: usize, state: anytype, stack: *std.ArrayList(usize), out: *std.ArrayList(usize), problems: *std.ArrayList(Problem)) Allocator.Error!void {
        switch (state[i]) {
            .done => return,
            .active => {
                var msg: std.ArrayList(u8) = .empty;
                try msg.appendSlice(arena, "dependency cycle: ");
                var start: usize = 0;
                for (stack.items, 0..) |s, k| {
                    if (s == i) start = k;
                }
                for (stack.items[start..]) |s| {
                    try msg.appendSlice(arena, t.recipes[s].name);
                    try msg.appendSlice(arena, " -> ");
                }
                try msg.appendSlice(arena, t.recipes[i].name);
                try problems.append(arena, .{ .where = t.recipes[i].name, .message = try msg.toOwnedSlice(arena) });
                return;
            },
            .new => {},
        }
        state[i] = .active;
        try stack.append(arena, i);
        const r = t.recipes[i];
        for ([_][]const []const u8{ r.hostdeps, r.builddeps }) |deps| {
            for (deps) |d| {
                const p = t.provider(d) orelse {
                    if (t.allow_external) continue;
                    try problems.append(arena, .{
                        .where = r.name,
                        .message = try std.fmt.allocPrint(arena, "dependency '{s}' is not in the tree", .{d}),
                    });
                    continue;
                };
                if (p != i) try t.visit(arena, p, state, stack, out, problems);
            }
        }
        _ = stack.pop();
        state[i] = .done;
        try out.append(arena, i);
    }
};

/// Loads `<root>/packages/<letter>/<name>/package.toml`. A recipe sits in the
/// directory named by its first letter (`recipe.dirPath`). Recipes that fail
/// validation are reported in `problems` and left out of the tree.
pub fn load(arena: Allocator, io: std.Io, root: []const u8, problems: *std.ArrayList(Problem)) !Tree {
    var list: std.ArrayList(Recipe) = .empty;
    const pkg_path = try std.fs.path.join(arena, &.{ root, "packages" });
    var dir = try std.Io.Dir.cwd().openDir(io, pkg_path, .{ .iterate = true });
    defer dir.close(io);

    // Every package directory as "<letter>/<name>", sorted so the order is stable.
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        var bucket = try dir.openDir(io, e.name, .{ .iterate = true });
        defer bucket.close(io);
        var bit = bucket.iterate();
        while (try bit.next(io)) |p| {
            if (p.kind == .directory) try names.append(arena, try std.fs.path.join(arena, &.{ e.name, p.name }));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |dirname| {
        const file = try std.fs.path.join(arena, &.{ pkg_path, dirname, "package.toml" });
        const text = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(1 << 20)) catch |err| {
            try problems.append(arena, .{ .where = dirname, .message = try std.fmt.allocPrint(arena, "cannot read package.toml: {s}", .{@errorName(err)}) });
            continue;
        };
        var diag: recipe.Diagnostic = .{};
        const r = recipe.parse(arena, text, &diag) catch |err| switch (err) {
            error.InvalidRecipe => {
                try problems.append(arena, .{ .where = dirname, .message = diag.message });
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const expected = try std.fs.path.join(arena, &.{ r.name[0..1], r.name });
        if (!std.mem.eql(u8, expected, dirname)) {
            try problems.append(arena, .{ .where = dirname, .message = try std.fmt.allocPrint(arena, "name '{s}' belongs in packages/{s}", .{ r.name, expected }) });
            continue;
        }
        var ok = true;
        for (r.patches) |patch| {
            const pp = try std.fs.path.join(arena, &.{ pkg_path, dirname, "patches", patch });
            std.Io.Dir.cwd().access(io, pp, .{}) catch {
                try problems.append(arena, .{ .where = dirname, .message = try std.fmt.allocPrint(arena, "patch '{s}' not found in patches/", .{patch}) });
                ok = false;
            };
        }
        if (ok) try list.append(arena, r);
    }
    return .{ .recipes = try list.toOwnedSlice(arena) };
}

// ---- tests ----

fn rc(name: []const u8, host: []const []const u8, build: []const []const u8) Recipe {
    return .{
        .name = name, .version = "1", .release = 1, .summary = "s", .license = "MIT",
        .source = &.{}, .install = "x", .hostdeps = host, .builddeps = build,
    };
}

test "order puts dependencies first, resolves -devel to its recipe" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const t: Tree = .{ .recipes = &.{
        rc("app", &.{"zig"}, &.{"lib-devel"}),
        rc("lib", &.{}, &.{"zlib"}),
        rc("zig", &.{}, &.{}),
        rc("zlib", &.{}, &.{}),
    } };
    var problems: std.ArrayList(Problem) = .empty;
    const o = try t.order(a, &.{"app"}, &problems);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    var names: [4][]const u8 = undefined;
    for (o, 0..) |i, k| names[k] = t.recipes[i].name;
    try std.testing.expectEqualStrings("zig", names[0]);
    try std.testing.expectEqualStrings("zlib", names[1]);
    try std.testing.expectEqualStrings("lib", names[2]);
    try std.testing.expectEqualStrings("app", names[3]);
}

test "provider knows the default subpackages, including -static" {
    const t: Tree = .{ .recipes = &.{rc("zstd", &.{}, &.{})} };
    try std.testing.expectEqual(@as(?usize, 0), t.provider("zstd"));
    try std.testing.expectEqual(@as(?usize, 0), t.provider("zstd-devel"));
    try std.testing.expectEqual(@as(?usize, 0), t.provider("zstd-static"));
    try std.testing.expectEqual(@as(?usize, 0), t.provider("zstd-doc"));
    try std.testing.expectEqual(@as(?usize, null), t.provider("zstd-extra"));
}

test "cycles and missing dependencies are reported" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const t: Tree = .{ .recipes = &.{
        rc("a", &.{}, &.{"b"}),
        rc("b", &.{}, &.{ "a", "ghost" }),
    } };
    var problems: std.ArrayList(Problem) = .empty;
    _ = try t.order(a, &.{"a"}, &problems);
    try std.testing.expectEqual(@as(usize, 2), problems.items.len);
    try std.testing.expectEqualStrings("dependency cycle: a -> b -> a", problems.items[0].message);
    try std.testing.expectEqualStrings("dependency 'ghost' is not in the tree", problems.items[1].message);
}
