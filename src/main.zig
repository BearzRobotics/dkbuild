const std = @import("std");
const recipe = @import("recipe.zig");
const tree = @import("tree.zig");
const fetch = @import("fetch.zig");
const npmdeps = @import("npmdeps.zig");
const build = @import("build.zig");
const inputs = @import("inputs.zig");
const bootstrap = @import("bootstrap.zig");
const sandbox = @import("sandbox.zig");
const doctor = @import("doctor.zig");
const cbuild = @import("cbuild.zig");
const sched = @import("sched.zig");
const imagefile = @import("image.zig");

const usage =
    \\usage: dkbuild [--tree DIR] <command> [args]
    \\
    \\  check [name|file.toml]...   validate recipes (all of them if none given)
    \\  fetch [name]...            download sources into cache/sources and check them
    \\  pkg [-j N] [-P N] [--key FILE] [--keep-root] [--no-check] [--keep-going] [--force] <name>...
    \\                             build packages and the dependencies in the tree
    \\  world [-j N] [-P N] [--key FILE] [--keep-root] [--no-check] [--keep-going] [--force]
    \\                             build every recipe in the tree that is out of date
    \\                             (-j: jobs per build; -P: builds at once, default 1)
    \\  image <file.toml>          make a root filesystem from repo/ (tarball, squashfs or
    \\                             directory in out/<name>/); see SPEC.md 8
    \\  prune [--dry-run] [--key FILE]
    \\                             remove packages from repo/ that their recipe no longer
    \\                             builds (older versions), and rebuild the index
    \\  graph <name>...            print the build order for packages
    \\  import-cbuild [--out DIR] <template.py|dir>...
    \\                             convert Chimera cbuild templates into draft recipes
    \\                             (default DIR: imported/); see docs/decisions/0002
    \\  doctor                     check this machine can run dkbuild; print the fixes
    \\  bootstrap-root [--force] [--dest DIR] <image>
    \\                             unpack the build machine (the DKRescue ISO, its
    \\                             rootfs.sfs, or a root tarball) into rootfs/dkrescue
    \\                             and check it (SPEC.md 9.2)
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // The sandbox runs in a copy of this program (sandbox.zig).
    if (args.len > 1 and std.mem.eql(u8, args[1], sandbox.subcommand)) sandbox.childMain(args[2..]);

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
            // it doesn't provide are assumed to be in the base image (SPEC.md 7.3).
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
            // Dependencies are vendored for the first tarball only, as the build
            // lays them in (ollama's second tarball is llama.cpp, no Go modules).
            var first_tb = true;
            for (r.source) |src| {
                var msg: []const u8 = "";
                if (fetch.fetchOne(arena, init.io, cache, src, &msg)) |st| {
                    std.debug.print("{s}: {s}\n", .{ r.name, @tagName(st) });
                    const is_first = src == .tarball and first_tb;
                    if (src == .tarball) first_tb = false;
                    if (is_first and contains(r.options, "zigdeps")) {
                        if (fetch.fetchZigDeps(arena, init.io, cache, src.tarball.sha256, &msg)) |zst| {
                            std.debug.print("{s}: zig dependencies {s}\n", .{ r.name, @tagName(zst) });
                        } else |zerr| {
                            failed = true;
                            std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(zerr) });
                        }
                    }
                    if (is_first and contains(r.options, "cargodeps")) {
                        if (fetch.fetchCargoDeps(arena, init.io, cache, src.tarball.sha256, &msg)) |cst| {
                            std.debug.print("{s}: Rust crates {s}\n", .{ r.name, @tagName(cst) });
                        } else |cerr| {
                            failed = true;
                            std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(cerr) });
                        }
                    }
                    if (is_first and contains(r.options, "npmdeps")) {
                        if (npmdeps.fetchNpmDeps(arena, init.io, cache, src.tarball.sha256, &msg)) |nst| {
                            std.debug.print("{s}: npm packages {s}\n", .{ r.name, @tagName(nst) });
                        } else |nerr| {
                            failed = true;
                            std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(nerr) });
                        }
                    }
                    if (is_first and contains(r.options, "godeps")) {
                        if (fetch.fetchGoDeps(arena, init.io, cache, src.tarball.sha256, &msg)) |gst| {
                            std.debug.print("{s}: Go modules {s}\n", .{ r.name, @tagName(gst) });
                        } else |gerr| {
                            failed = true;
                            std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(gerr) });
                        }
                    }
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
    } else if (std.mem.eql(u8, cmd, "pkg") or std.mem.eql(u8, cmd, "world")) {
        const is_world = std.mem.eql(u8, cmd, "world");
        var opts: build.Options = .{
            .root = root,
            .jobs = std.Thread.getCpuCount() catch 1,
            .fast_work = init.environ_map.get("DKBUILD_FAST_WORK"),
        };
        if (init.environ_map.get("HOME")) |home|
            opts.key = try std.fs.path.join(arena, &.{ home, ".config", "dkbuild", "signing.rsa" });
        var names: std.ArrayList([]const u8) = .empty;
        var force = false;
        var keep_going = false;
        var parallel: usize = 1;
        var k: usize = 0;
        while (k < rest.len) : (k += 1) {
            if (std.mem.eql(u8, rest[k], "-j") and k + 1 < rest.len) {
                k += 1;
                opts.jobs = std.fmt.parseInt(usize, rest[k], 10) catch return die(usage);
            } else if (std.mem.eql(u8, rest[k], "-P") and k + 1 < rest.len) {
                k += 1;
                parallel = std.fmt.parseInt(usize, rest[k], 10) catch return die(usage);
                if (parallel == 0) return die(usage);
            } else if (std.mem.eql(u8, rest[k], "--key") and k + 1 < rest.len) {
                k += 1;
                opts.key = rest[k];
            } else if (std.mem.eql(u8, rest[k], "--keep-root")) {
                opts.keep_root = true;
            } else if (std.mem.eql(u8, rest[k], "--keep-going")) {
                keep_going = true;
            } else if (std.mem.eql(u8, rest[k], "--no-check")) {
                opts.no_check = true;
            } else if (std.mem.eql(u8, rest[k], "--force")) {
                force = true;
            } else try names.append(arena, rest[k]);
        }
        if (names.items.len == 0 and !is_world) return die(usage);
        if (names.items.len > 0 and is_world) return die(usage);
        var t = try tree.load(arena, init.io, root, &problems);
        t.allow_external = true;
        opts.tree = t;
        // `world` is every recipe in the tree; what is up to date is skipped below.
        if (is_world) for (t.recipes) |wr| try names.append(arena, wr.name);
        // `pkg` builds what the named packages need at run time too (an image of
        // `base` needs base's rundeps built, not only what base builds against).
        if (!is_world) {
            var k2: usize = 0;
            while (k2 < names.items.len) : (k2 += 1) {
                const pi = t.provider(names.items[k2]) orelse continue;
                const pr = t.recipes[pi];
                for ([_][]const []const u8{pr.rundeps}) |deps| for (deps) |d| {
                    const di = t.provider(d) orelse continue;
                    if (!contains(names.items, t.recipes[di].name)) try names.append(arena, t.recipes[di].name);
                };
                for (pr.subpackages) |sp| for (sp.depends) |d| {
                    const di = t.provider(d) orelse continue;
                    if (!contains(names.items, t.recipes[di].name)) try names.append(arena, t.recipes[di].name);
                };
            }
        }
        const order = try t.order(arena, names.items, &problems);
        if (problems.items.len > 0) {
            report(problems.items);
            std.process.exit(1);
        }
        // Rebuild decisions (SPEC.md 7.2).
        const own = try arena.alloc(inputs.Hex, t.recipes.len);
        for (t.recipes, own) |r, *h| h.* = try inputs.ownHash(arena, init.io, root, r.name, opts.arch);
        // What can be settled before anything builds is settled here: a recipe
        // edited without a new release stops the run before any work is lost.
        // Whether a package whose recipe is unchanged needs rebuilding depends
        // on what its dependencies produce in this run; sched.zig decides that.
        const outputs = try arena.alloc(?inputs.Produced, t.recipes.len);
        @memset(outputs, null);
        var jobs: std.ArrayList(sched.Job) = .empty;
        var certain: usize = 0;
        for (t.recipes, 0..) |r, idx| {
            const rec_path = try std.fmt.allocPrint(arena, "{s}/repo/{s}/{s}.dkhash", .{ root, opts.arch, r.name });
            const rec_text = std.Io.Dir.cwd().readFileAlloc(init.io, rec_path, arena, .limited(1 << 16)) catch continue;
            if (try inputs.parse(arena, rec_text)) |rec| if (rec.output) |o| {
                outputs[idx] = .{ .output = o, .interface = rec.interface orelse o };
            };
        }
        for (order) |idx| {
            const r = t.recipes[idx];
            const ver = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
            const rec_path = try std.fmt.allocPrint(arena, "{s}/repo/{s}/{s}.dkhash", .{ root, opts.arch, r.name });
            const pkg_path = try std.fmt.allocPrint(arena, "{s}/repo/{s}/{s}-{s}.apk", .{ root, opts.arch, r.name, ver });
            const rec_text = std.Io.Dir.cwd().readFileAlloc(init.io, rec_path, arena, .limited(1 << 16)) catch null;
            const rec = if (rec_text) |txt| try inputs.parse(arena, txt) else null;
            const exists = if (std.Io.Dir.cwd().access(init.io, pkg_path, .{})) |_| true else |_| false;
            var job: sched.Job = .{
                .idx = idx,
                .id = try std.fmt.allocPrint(arena, "{s}-{s}", .{ r.name, ver }),
                .rec_path = rec_path,
                .version = ver,
                .own = own[idx],
                .certain = true,
                .script = try build.scriptHash(arena, init.io, r, opts),
            };
            if (force or rec == null or !exists or !std.mem.eql(u8, rec.?.version, ver) or rec.?.output == null) {
                // never built, a new version or release, --force, or a record
                // from before outputs were recorded: built at this release,
                // with nothing to compare against and no reason to bump it
            } else if (!std.mem.eql(u8, &rec.?.inputs, &own[idx])) {
                std.debug.print("error: {s}: its recipe, patches or files changed but the release is still r{d}; bump `release` (or use --force)\n", .{ r.name, r.release });
                std.process.exit(1);
            } else {
                job.certain = false;
                job.old_root = rec.?.deps;
                // A record from before scripts were recorded is taken as current.
                if (rec.?.script) |old| job.script_changed = !std.mem.eql(u8, &old, &job.script);
            }
            if (job.certain) certain += 1;
            try jobs.append(arena, job);
        }
        if (parallel > 1 and certain > 0)
            std.debug.print("{d} package(s) to build, others when what they build against changed; up to {d} at a time\n", .{ certain, parallel });
        const res = try sched.run(arena, init.io, t, jobs.items, outputs, opts, parallel, keep_going);
        const failed_names = res.failed;
        const skipped_names = res.skipped;
        if (failed_names.len > 0 and !keep_going) std.process.exit(1);
        if (failed_names.len > 0 or skipped_names.len > 0) {
            std.debug.print("\n{d} failed:", .{failed_names.len});
            for (failed_names) |n| std.debug.print(" {s}", .{n});
            std.debug.print("\n{d} skipped:", .{skipped_names.len});
            for (skipped_names) |n| std.debug.print(" {s}", .{n});
            std.debug.print("\n", .{});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "image")) {
        if (rest.len != 1) return die(usage);
        const text = std.Io.Dir.cwd().readFileAlloc(init.io, rest[0], arena, .limited(1 << 20)) catch |err| {
            std.debug.print("{s}: {s}\n", .{ rest[0], @errorName(err) });
            std.process.exit(1);
        };
        var diag: imagefile.Diagnostic = .{};
        const img = imagefile.parse(arena, text, &diag) catch |err| switch (err) {
            error.InvalidImage => {
                std.debug.print("{s}: {s}\n", .{ rest[0], diag.message });
                std.process.exit(1);
            },
            else => return err,
        };
        imagefile.build(arena, init.io, img, .{ .root = root }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.process.exit(1),
        };
    } else if (std.mem.eql(u8, cmd, "prune")) {
        var opts: build.Options = .{ .root = root };
        if (init.environ_map.get("HOME")) |home|
            opts.key = try std.fs.path.join(arena, &.{ home, ".config", "dkbuild", "signing.rsa" });
        var dry_run = false;
        var k: usize = 0;
        while (k < rest.len) : (k += 1) {
            if (std.mem.eql(u8, rest[k], "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, rest[k], "--key") and k + 1 < rest.len) {
                k += 1;
                opts.key = rest[k];
            } else return die(usage);
        }
        var t = try tree.load(arena, init.io, root, &problems);
        t.allow_external = true;
        opts.tree = t;
        build.prune(arena, init.io, opts, dry_run) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.process.exit(1),
        };
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
    } else if (std.mem.eql(u8, cmd, "import-cbuild")) {
        var out_dir: []const u8 = try std.fs.path.join(arena, &.{ root, "imported" });
        var inputs_list: std.ArrayList([]const u8) = .empty;
        var k: usize = 0;
        while (k < rest.len) : (k += 1) {
            if (std.mem.eql(u8, rest[k], "--out") and k + 1 < rest.len) {
                k += 1;
                out_dir = rest[k];
            } else try inputs_list.append(arena, rest[k]);
        }
        if (inputs_list.items.len == 0) return die(usage);
        var failed = false;
        for (inputs_list.items) |path| {
            const res = cbuild.importPath(arena, init.io, path, out_dir) catch |err| {
                std.debug.print("{s}: {s}\n", .{ path, @errorName(err) });
                failed = true;
                continue;
            };
            cbuild.printResult(res);
        }
        if (failed) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        const ok = try doctor.run(arena, init.io, root, init.environ_map.get("PATH") orelse "/usr/bin:/bin", init.environ_map.get("HOME"));
        if (!ok) std.process.exit(1);
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
    _ = @import("sandbox.zig");
    _ = @import("doctor.zig");
    _ = @import("cbuild.zig");
    _ = @import("fetch.zig");
    _ = @import("npmdeps.zig");
    _ = @import("build.zig");
    _ = @import("split.zig");
    _ = @import("scan.zig");
    _ = @import("inputs.zig");
    _ = @import("sched.zig");
    _ = @import("image.zig");
}
