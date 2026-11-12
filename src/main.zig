const std = @import("std");
const recipe = @import("recipe.zig");
const tree = @import("tree.zig");
const fetch = @import("fetch.zig");
const npmdeps = @import("npmdeps.zig");
const gemdeps = @import("gemdeps.zig");
const pubdeps = @import("pubdeps.zig");
const build = @import("build.zig");
const inputs = @import("inputs.zig");
const term = @import("term.zig");
const bootstrap = @import("bootstrap.zig");
const sandbox = @import("sandbox.zig");
const doctor = @import("doctor.zig");
const cbuild = @import("cbuild.zig");
const sched = @import("sched.zig");
const imagefile = @import("image.zig");
const discs = @import("discs.zig");

const usage =
    \\usage: dkbuild [--tree DIR] <command> [args]
    \\
    \\  check [name|file.toml]...   validate recipes (all of them if none given)
    \\  fetch [name]...            download sources into cache/sources and check them
    \\  pkg [-j N] [-P N] [--key FILE] [--keep-root] [--no-check] [--keep-going] [--force] [--color=auto|always|never] <name>...
    \\                             build packages and the dependencies in the tree
    \\  world [-j N] [-P N] [--key FILE] [--keep-root] [--no-check] [--keep-going] [--force] [--color=auto|always|never]
    \\                             build every recipe in the tree that is out of date
    \\                             (-j: jobs per build; -P: builds at once, default 1)
    \\  image <file.toml>          make a root filesystem from repo/ (tarball, squashfs or
    \\                             directory in out/<name>/); see SPEC.md 8
    \\  discs [--media M] <file.toml>
    \\                             the repository (kind = "repo") or the sources ("source")
    \\                             as ISO images in out/<name>/: one image (media usb) or a
    \\                             set for discs (cd, dvd, dvd-dl, bd25, bd50, bd100)
    \\  prune [--dry-run] [--key FILE]
    \\  outdated [--bump]          recipes changed since their last build without a new release (--bump raises it)
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
            var npm_found = false;
            var gem_found = false;
            var pub_found = false;
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
                    // further sources with a Cargo project at their top (crubit beside Chromium)
                    if (!is_first and src.tarball.unpack and contains(r.options, "cargodeps") and
                        fetch.hasTopCargoLock(arena, init.io, try fetch.cachePath(arena, cache, src.tarball.sha256)))
                    {
                        if (fetch.fetchCargoDeps(arena, init.io, cache, src.tarball.sha256, "", &.{}, null, &msg)) |cst| {
                            std.debug.print("{s}: Rust crates of a further source {s}\n", .{ r.name, @tagName(cst) });
                        } else |cerr| {
                            failed = true;
                            std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(cerr) });
                        }
                    }
                    if (is_first and contains(r.options, "cargodeps")) {
                        if (fetch.fetchCargoDeps(arena, init.io, cache, src.tarball.sha256, try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, root, r.name), "patches" }), r.patches, try fetch.recipeCargoLock(arena, r.options, try recipe.dirPath(arena, root, r.name)), &msg)) |cst| {
                            std.debug.print("{s}: Rust crates {s}\n", .{ r.name, @tagName(cst) });
                        } else |cerr| {
                            failed = true;
                            std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(cerr) });
                        }
                    }
                    if (src == .tarball and src.tarball.unpack and contains(r.options, "gemdeps")) {
                        if (gemdeps.fetchGemDeps(arena, init.io, cache, src.tarball.sha256, &msg)) |gst| {
                            gem_found = true;
                            std.debug.print("{s}: Ruby gems {s}\n", .{ r.name, @tagName(gst) });
                        } else |gerr2| {
                            if (!std.mem.eql(u8, msg, gemdeps.no_lockfile)) {
                                failed = true;
                                std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(gerr2) });
                            }
                        }
                    }
                    if (src == .tarball and src.tarball.unpack and contains(r.options, "pubdeps")) {
                        if (pubdeps.fetchPubDeps(arena, init.io, cache, src.tarball.sha256, &msg)) |pst| {
                            pub_found = true;
                            std.debug.print("{s}: Dart packages {s}\n", .{ r.name, @tagName(pst) });
                        } else |perr| {
                            if (!std.mem.eql(u8, msg, pubdeps.no_lockfile)) {
                                failed = true;
                                std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(perr) });
                            }
                        }
                    }
                    // every unpacked tarball may carry lockfiles (a web client as a second source)
                    if (src == .tarball and src.tarball.unpack and contains(r.options, "npmdeps")) {
                        if (npmdeps.fetchNpmDeps(arena, init.io, cache, src.tarball.sha256, &msg)) |nst| {
                            npm_found = true;
                            std.debug.print("{s}: npm packages {s}\n", .{ r.name, @tagName(nst) });
                        } else |nerr| {
                            if (!std.mem.eql(u8, msg, npmdeps.no_lockfile)) {
                                failed = true;
                                std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(nerr) });
                            }
                        }
                    }
                    if (is_first and contains(r.options, "godeps")) {
                        if (fetch.fetchGoDeps(arena, init.io, cache, src.tarball.sha256, try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, root, r.name), "patches" }), r.patches, &msg)) |gst| {
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
            // a pubspec.lock the recipe keeps in its files/
            if (contains(r.options, "pubdeps")) {
                const pl = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, root, r.name), "files", "pubspec.lock" });
                if (std.Io.Dir.cwd().access(init.io, pl, .{})) |_| {
                    var pmsg: []const u8 = "";
                    if (pubdeps.fetchPubLockFile(arena, init.io, cache, pl, &pmsg)) |pst| {
                        pub_found = true;
                        std.debug.print("{s}: Dart packages (files/pubspec.lock) {s}\n", .{ r.name, @tagName(pst) });
                    } else |perr| {
                        failed = true;
                        std.debug.print("{s}: {s}\n", .{ r.name, if (pmsg.len > 0) pmsg else @errorName(perr) });
                    }
                } else |_| {}
            }
            if (contains(r.options, "pubdeps") and !pub_found and !failed) {
                failed = true;
                std.debug.print("{s}: {s} (in none of its sources)\n", .{ r.name, pubdeps.no_lockfile });
            }
            if (contains(r.options, "gemdeps") and !gem_found and !failed) {
                failed = true;
                std.debug.print("{s}: {s} (in none of its sources)\n", .{ r.name, gemdeps.no_lockfile });
            }
            // lockfiles the recipe keeps in its files/
            if (contains(r.options, "npmdeps")) {
                const fdir = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, root, r.name), "files" });
                for (try npmdeps.recipeLocks(arena, init.io, fdir)) |lp| {
                    var msg: []const u8 = "";
                    if (npmdeps.fetchNpmLockFile(arena, init.io, cache, lp, &msg)) |nst| {
                        npm_found = true;
                        std.debug.print("{s}: npm packages ({s}) {s}\n", .{ r.name, std.fs.path.basename(lp), @tagName(nst) });
                    } else |nerr| {
                        failed = true;
                        std.debug.print("{s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(nerr) });
                    }
                }
            }
            if (contains(r.options, "npmdeps") and !npm_found and !failed) {
                failed = true;
                std.debug.print("{s}: {s} (in none of its sources)\n", .{ r.name, npmdeps.no_lockfile });
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
        var color_mode: ?[]const u8 = null;
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
            } else if (std.mem.startsWith(u8, rest[k], "--color=")) {
                color_mode = rest[k]["--color=".len..];
            } else try names.append(arena, rest[k]);
        }
        term.setup(init.io, color_mode, init.environ_map.get("NO_COLOR") != null);
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
        var unbumped: std.ArrayList([]const u8) = .empty;
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
                if (!keep_going) std.process.exit(1);
                // --keep-going: the rest of the tree still builds; this one is
                // reported with the failures (its old package stays in repo/).
                try unbumped.append(arena, r.name);
                continue;
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
        writeRunSummary(arena, init.io, root, opts.arch, t, if (is_world) "world" else "pkg", jobs.items.len, failed_names, unbumped.items, skipped_names);
        // What the builds took from the base image (dependencies no recipe
        // provides; stage 1 does not check them, SPEC.md 7.3): once, not per build.
        {
            var base_names: std.ArrayList([]const u8) = .empty;
            for (jobs.items) |jb| {
                const jr = t.recipes[jb.idx];
                for ([_][]const []const u8{ jr.hostdeps, jr.builddeps }) |deps| for (deps) |d| {
                    if (t.provider(d) == null and !contains(base_names.items, d)) try base_names.append(arena, d);
                };
            }
            if (base_names.items.len > 0) {
                std.mem.sort([]const u8, base_names.items, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lt);
                term.print("note: taken from the base image (no recipe provides them): {s}\n", .{try std.mem.join(arena, " ", base_names.items)});
            }
        }
        if (failed_names.len > 0 and !keep_going) std.process.exit(1);
        if (failed_names.len > 0 or skipped_names.len > 0 or unbumped.items.len > 0) {
            term.print("\n{d} failed:", .{failed_names.len});
            for (failed_names) |n| term.print(" {s}", .{n});
            if (unbumped.items.len > 0) {
                term.print("\n{d} changed without a release bump (not built):", .{unbumped.items.len});
                for (unbumped.items) |n| term.print(" {s}", .{n});
            }
            term.print("\n{d} skipped:", .{skipped_names.len});
            for (skipped_names) |n| term.print(" {s}", .{n});
            term.print("\nsummary: logs/{s}/last-run.txt\n", .{opts.arch});
            std.process.exit(1);
        }
        term.print("summary: logs/{s}/last-run.txt\n", .{opts.arch});
    } else if (std.mem.eql(u8, cmd, "outdated")) {
        // Recipes whose recipe, patches or files changed since they were built,
        // at the same version-release: world would refuse them (SPEC.md 7.2).
        // Builds nothing; --bump raises `release` in each package.toml.
        var bump = false;
        for (rest) |a| {
            if (std.mem.eql(u8, a, "--bump")) bump = true else return die(usage);
        }
        const arch = "x86_64";
        problems.clearRetainingCapacity();
        const t = try tree.load(arena, init.io, root, &problems);
        var n: usize = 0;
        for (t.recipes) |r| {
            const ver = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
            const rec_path = try std.fmt.allocPrint(arena, "{s}/repo/{s}/{s}.dkhash", .{ root, arch, r.name });
            const txt = std.Io.Dir.cwd().readFileAlloc(init.io, rec_path, arena, .limited(1 << 16)) catch continue;
            const rec = (try inputs.parse(arena, txt)) orelse continue;
            if (!std.mem.eql(u8, rec.version, ver) or rec.output == null) continue;
            const own = try inputs.ownHash(arena, init.io, root, r.name, arch);
            if (std.mem.eql(u8, &rec.inputs, &own)) continue;
            n += 1;
            if (!bump) {
                std.debug.print("{s}: changed at r{d}\n", .{ r.name, r.release });
                continue;
            }
            const path = try std.fmt.allocPrint(arena, "{s}/package.toml", .{try recipe.dirPath(arena, root, r.name)});
            const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 22));
            const needle = try std.fmt.allocPrint(arena, "release = {d}\n", .{r.release});
            const needle2 = try std.fmt.allocPrint(arena, "release   = {d}\n", .{r.release});
            const which = if (std.mem.indexOf(u8, text, needle) != null) needle else if (std.mem.indexOf(u8, text, needle2) != null) needle2 else {
                std.debug.print("{s}: changed at r{d}, but its release line is not plain; bump it by hand\n", .{ r.name, r.release });
                continue;
            };
            const repl = try std.fmt.allocPrint(arena, "{s}{d}\n", .{ which[0 .. which.len - 1 - std.fmt.count("{d}", .{r.release})], r.release + 1 });
            const out = try std.mem.replaceOwned(u8, arena, text, which, repl);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out });
            std.debug.print("{s}: r{d} -> r{d}\n", .{ r.name, r.release, r.release + 1 });
        }
        if (n == 0) std.debug.print("nothing changed without a release bump\n", .{});
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
    } else if (std.mem.eql(u8, cmd, "discs")) {
        var media: ?[]const u8 = null;
        var file: ?[]const u8 = null;
        var k: usize = 0;
        while (k < rest.len) : (k += 1) {
            if (std.mem.eql(u8, rest[k], "--media") and k + 1 < rest.len) {
                k += 1;
                media = rest[k];
            } else if (file == null and rest[k].len > 0 and rest[k][0] != '-') {
                file = rest[k];
            } else return die(usage);
        }
        const path = file orelse return die(usage);
        const text = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 20)) catch |err| {
            std.debug.print("{s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(1);
        };
        var diag: discs.Diagnostic = .{};
        var set = discs.parse(arena, text, &diag) catch |err| switch (err) {
            error.InvalidSet => {
                std.debug.print("{s}: {s}\n", .{ path, diag.message });
                std.process.exit(1);
            },
            else => return err,
        };
        if (media) |m| {
            set.media = m;
            discs.check(arena, &diag, set) catch {
                std.debug.print("--media: {s}\n", .{diag.message});
                std.process.exit(1);
            };
        }
        var t = try tree.load(arena, init.io, root, &problems);
        t.allow_external = true;
        var dopts: discs.Options = .{ .root = root };
        if (init.environ_map.get("HOME")) |home|
            dopts.key = try std.fs.path.join(arena, &.{ home, ".config", "dkbuild", "signing.rsa" });
        discs.make(arena, init.io, t, set, dopts) catch |err| switch (err) {
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
    _ = @import("gemdeps.zig");
    _ = @import("pubdeps.zig");
    _ = @import("build.zig");
    _ = @import("split.zig");
    _ = @import("scan.zig");
    _ = @import("inputs.zig");
    _ = @import("sched.zig");
    _ = @import("image.zig");
    _ = @import("discs.zig");
}

/// After `pkg` or `world`: logs/<arch>/last-run.txt, and a dated copy in
/// logs/<arch>/runs/, listing what failed (with each build log), what was not
/// built because its recipe changed without a release bump, and what was
/// skipped because something it needs failed. Read it instead of scrolling.
fn writeRunSummary(arena: std.mem.Allocator, io: std.Io, root: []const u8, arch: []const u8, t: tree.Tree, what: []const u8, considered: usize, failed: []const []const u8, unbumped: []const []const u8, skipped: []const []const u8) void {
    var b: std.ArrayList(u8) = .empty;
    const stamp = blk: {
        const res = std.process.run(arena, io, .{ .argv = &.{ "date", "+%F %T" } }) catch break :blk "?";
        break :blk std.mem.trim(u8, res.stdout, "\n ");
    };
    const w = struct {
        fn line(a: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) void {
            const text = std.fmt.allocPrint(a, fmt, args) catch return;
            list.appendSlice(a, text) catch {};
        }
    };
    w.line(arena, &b, "dkbuild {s} ({s}), finished {s}\n", .{ what, arch, stamp });
    w.line(arena, &b, "{d} package(s) considered; {d} failed, {d} changed without a release bump, {d} skipped\n\n", .{ considered, failed.len, unbumped.len, skipped.len });
    w.line(arena, &b, "failed ({d}):\n", .{failed.len});
    for (failed) |n| {
        const pi = t.provider(n);
        if (pi) |i| {
            const r = t.recipes[i];
            w.line(arena, &b, "  {s}  logs/{s}/{s}-{s}-r{d}.log\n", .{ n, arch, r.name, r.version, r.release });
        } else w.line(arena, &b, "  {s}\n", .{n});
    }
    w.line(arena, &b, "\nchanged without a release bump, not built ({d}):\n", .{unbumped.len});
    for (unbumped) |n| w.line(arena, &b, "  {s}\n", .{n});
    w.line(arena, &b, "\nskipped, something they need failed ({d}):\n", .{skipped.len});
    for (skipped) |n| w.line(arena, &b, "  {s}\n", .{n});
    const dir = std.fs.path.join(arena, &.{ root, "logs", arch, "runs" }) catch return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const last = std.fs.path.join(arena, &.{ root, "logs", arch, "last-run.txt" }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = last, .data = b.items }) catch {};
    var name = std.ArrayList(u8).empty;
    for (stamp) |c| name.append(arena, if (c == ' ' or c == ':') '-' else c) catch {};
    const dated = std.fmt.allocPrint(arena, "{s}/{s}-{s}.txt", .{ dir, name.items, what }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dated, .data = b.items }) catch {};
}
