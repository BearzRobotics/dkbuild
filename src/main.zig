const std = @import("std");
const recipe = @import("recipe.zig");
const tree = @import("tree.zig");
const fetch = @import("fetch.zig");
const build = @import("build.zig");
const inputs = @import("inputs.zig");
const bootstrap = @import("bootstrap.zig");

const usage =
    \\usage: dkbuild [--tree DIR] <command> [args]
    \\
    \\  check [name|file.toml]...   validate recipes (all of them if none given)
    \\  fetch [name]...            download sources into cache/sources and check them
    \\  pkg [-j N] [--key FILE] [--keep-root] [--force] <name>...
    \\                             build packages and the dependencies in the tree
    \\  graph <name>...            print the build order for packages
    \\  bootstrap-root [--force] [--dest DIR] <image>
    \\                             unpack the build machine (the DKRescue ISO, its
    \\                             rootfs.sfs, or a root tarball) into rootfs/dkrescue
    \\                             and check it (SPEC.md 9.2)
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var root: []const u8 = ".";
    var i: usize = 1;
    if (i + 1 < args.len and std.mem.eql(u8, args[i], "--tree")) {
        root = args[i + 1];
        i += 2;
    }
    if (i >= args.len) return die(usage);
    const cmd = args[i];
    const rest = args[i + 1 ..];

    var problems: std.ArrayList(tree.Problem) = .empty;

    if (std.mem.eql(u8, cmd, "check")) {
        var checked: usize = 0;
        // Files named directly are checked on their own.
        var names: std.ArrayList([]const u8) = .empty;
        for (rest) |a| {
            if (std.mem.endsWith(u8, a, ".toml")) {
                checked += 1;
                const text = std.Io.Dir.cwd().readFileAlloc(init.io, a, arena, .limited(1 << 20)) catch |err| {
                    try problems.append(arena, .{ .where = a, .message = @errorName(err) });
                    continue;
                };
                var diag: recipe.Diagnostic = .{};
                _ = recipe.parse(arena, text, &diag) catch |err| switch (err) {
                    error.InvalidRecipe => try problems.append(arena, .{ .where = a, .message = diag.message }),
                    error.OutOfMemory => return err,
                };
            } else try names.append(arena, a);
        }
        if (rest.len == 0 or names.items.len > 0) {
            var t = try tree.load(arena, init.io, root, &problems);
            // Until the tree builds its own toolchain (SPEC.md 9), dependencies
            // it doesn't provide come from the Chimera bootstrap repositories.
            t.allow_external = true;
            checked += if (rest.len == 0) t.recipes.len else names.items.len;
            for (names.items) |n| {
                if (t.find(n) == null and !hasProblem(problems.items, n))
                    try problems.append(arena, .{ .where = n, .message = "not in the tree" });
            }
            // Dependencies must resolve, and must not form a cycle.
            var all: std.ArrayList([]const u8) = .empty;
            for (t.recipes) |r| if (rest.len == 0 or contains(names.items, r.name)) try all.append(arena, r.name);
            _ = try t.order(arena, all.items, &problems);
        }
        if (problems.items.len == 0) {
            std.debug.print("{d} recipe(s) ok\n", .{checked});
            return;
        }
        report(problems.items);
        std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "fetch")) {
        const t = try tree.load(arena, init.io, root, &problems);
        const cache = try std.fs.path.join(arena, &.{ root, "cache" });
        var failed = false;
        for (t.recipes) |r| {
            if (rest.len > 0 and !contains(rest, r.name)) continue;
            for (r.source) |src| {
                var msg: []const u8 = "";
                if (fetch.fetchOne(arena, init.io, cache, src, &msg)) |st| {
                    std.debug.print("{s}: {s}\n", .{ r.name, @tagName(st) });
                } else |err| {
                    failed = true;
                    std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                }
            }
        }
        for (rest) |n| if (t.find(n) == null) {
            failed = true;
            std.debug.print("{s}: not in the tree\n", .{n});
        };
        report(problems.items);
        if (failed or problems.items.len > 0) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "pkg")) {
        var opts: build.Options = .{
            .root = root,
            .jobs = std.Thread.getCpuCount() catch 1,
        };
        if (init.environ_map.get("HOME")) |home|
            opts.key = try std.fs.path.join(arena, &.{ home, ".config", "dkbuild", "signing.rsa" });
        var names: std.ArrayList([]const u8) = .empty;
        var force = false;
        var k: usize = 0;
        while (k < rest.len) : (k += 1) {
            if (std.mem.eql(u8, rest[k], "-j") and k + 1 < rest.len) {
                k += 1;
                opts.jobs = std.fmt.parseInt(usize, rest[k], 10) catch return die(usage);
            } else if (std.mem.eql(u8, rest[k], "--key") and k + 1 < rest.len) {
                k += 1;
                opts.key = rest[k];
            } else if (std.mem.eql(u8, rest[k], "--keep-root")) {
                opts.keep_root = true;
            } else if (std.mem.eql(u8, rest[k], "--force")) {
                force = true;
            } else try names.append(arena, rest[k]);
        }
        if (names.items.len == 0) return die(usage);
        var t = try tree.load(arena, init.io, root, &problems);
        t.allow_external = true;
        opts.tree = t;
        const order = try t.order(arena, names.items, &problems);
        if (problems.items.len > 0) {
            report(problems.items);
            std.process.exit(1);
        }
        // Rebuild decisions (SPEC.md 7.2).
        const own = try arena.alloc(inputs.Hex, t.recipes.len);
        for (t.recipes, own) |r, *h| h.* = try inputs.ownHash(arena, init.io, root, r.name, opts.arch);
        for (order) |idx| {
            const r = t.recipes[idx];
            const ver = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
            const deps = try inputs.depsHash(arena, t, own, idx);
            const rec_path = try std.fmt.allocPrint(arena, "{s}/repo/{s}/{s}.dkhash", .{ root, opts.arch, r.name });
            const pkg_path = try std.fmt.allocPrint(arena, "{s}/repo/{s}/{s}-{s}.apk", .{ root, opts.arch, r.name, ver });
            const rec_text = std.Io.Dir.cwd().readFileAlloc(init.io, rec_path, arena, .limited(1 << 16)) catch null;
            const rec = if (rec_text) |txt| try inputs.parse(arena, txt) else null;
            const exists = if (std.Io.Dir.cwd().access(init.io, pkg_path, .{})) |_| true else |_| false;
            switch (inputs.decide(rec, ver, own[idx], deps, exists)) {
                .up_to_date => if (!force) {
                    std.debug.print("==> {s}-{s}: up to date\n", .{ r.name, ver });
                    continue;
                },
                .rebuild_deps => std.debug.print("==> {s}-{s}: packages it builds against changed; rebuilding\n", .{ r.name, ver }),
                .unchanged_release => if (!force) {
                    std.debug.print("error: {s}: its recipe, patches or files changed but the release is still r{d}; bump `release` (or use --force)\n", .{ r.name, r.release });
                    std.process.exit(1);
                },
                .build => {},
            }
            build.buildOne(arena, init.io, r, opts) catch |err| {
                std.debug.print("{s}: {s}\n", .{ r.name, @errorName(err) });
                std.process.exit(1);
            };
            const text = try inputs.format(arena, .{ .version = ver, .inputs = own[idx], .deps = deps });
            std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = rec_path, .data = text }) catch |err| {
                std.debug.print("warning: cannot write {s}: {s}\n", .{ rec_path, @errorName(err) });
            };
        }
    } else if (std.mem.eql(u8, cmd, "graph")) {
        if (rest.len == 0) return die(usage);
        const t = try tree.load(arena, init.io, root, &problems);
        const order = try t.order(arena, rest, &problems);
        if (problems.items.len > 0) {
            report(problems.items);
            std.process.exit(1);
        }
        for (order) |idx| {
            const r = t.recipes[idx];
            std.debug.print("{s}-{s}-r{d}\n", .{ r.name, r.version, r.release });
        }
    } else if (std.mem.eql(u8, cmd, "bootstrap-root")) {
        var force = false;
        var dest: ?[]const u8 = null;
        var image: ?[]const u8 = null;
        var k: usize = 0;
        while (k < rest.len) : (k += 1) {
            if (std.mem.eql(u8, rest[k], "--force")) {
                force = true;
            } else if (std.mem.eql(u8, rest[k], "--dest") and k + 1 < rest.len) {
                k += 1;
                dest = rest[k];
            } else if (image == null) {
                image = rest[k];
            } else return die(usage);
        }
        const img = image orelse return die(usage);
        const where = dest orelse try std.fs.path.join(arena, &.{ root, "rootfs", "dkrescue" });
        const work = try std.fs.path.join(arena, &.{ root, "work" });
        bootstrap.bootstrapRoot(arena, init.io, img, where, .{ .work_dir = work, .force = force }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.process.exit(1),
        };
    } else return die(usage);
}

fn die(msg: []const u8) noreturn {
    std.debug.print("{s}", .{msg});
    std.process.exit(2);
}

fn report(ps: []const tree.Problem) void {
    for (ps) |p| std.debug.print("{s}: {s}\n", .{ p.where, p.message });
}

fn hasProblem(ps: []const tree.Problem, where: []const u8) bool {
    for (ps) |p| if (std.mem.eql(u8, p.where, where)) return true;
    return false;
}

fn contains(hay: []const []const u8, needle: []const u8) bool {
    for (hay) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

test {
    _ = @import("cfg.zig");
    _ = @import("recipe.zig");
    _ = @import("profile.zig");
    _ = @import("macro.zig");
    _ = @import("tree.zig");
    _ = @import("bootstrap.zig");
    _ = @import("fetch.zig");
    _ = @import("build.zig");
    _ = @import("split.zig");
    _ = @import("scan.zig");
    _ = @import("inputs.zig");
}
