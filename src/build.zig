//! Building one recipe (SPEC.md 7): prepare a root, unpack, run the steps in
//! the sandbox, check what was installed. Packaging comes after this.
//!
//! Stage 1 (SPEC.md 7.3, 9.2): builds run on the DKRescue image (rootfs/dkrescue,
//! from `dkbuild bootstrap-root`) under a writable layer, in our own sandbox.

const std = @import("std");
const recipe = @import("recipe.zig");
const fetch = @import("fetch.zig");
const macro = @import("macro.zig");
const profile = @import("profile.zig");
const tree = @import("tree.zig");
const split = @import("split.zig");
const scan = @import("scan.zig");
const sandbox = @import("sandbox.zig");
const basepkg = @import("basepkg.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const Options = struct {
    /// Project root (holds packages/, profiles/, rootfs/, cache/, work/, logs/).
    root: []const u8,
    arch: []const u8 = "x86_64",
    jobs: usize = 1,
    keep_root: bool = false,
    /// Dependencies this tree provides are not installed from the bootstrap
    /// repositories; they will come from repo/ once packaging exists.
    tree: ?tree.Tree = null,
    /// Private key that signs the repository index (never in the project).
    key: []const u8 = "",
};

/// Top-level directories a package may install into (SPEC.md 7 step 4).
const allowed_top = [_][]const u8{ "usr", "etc", "var", "opt", "boot" };

pub const BuildError = error{ BuildFailed, PrepareFailed, UnpackFailed, PolicyViolation, BadRecipe } || Allocator.Error;

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn runLogged(arena: Allocator, io: std.Io, argv: []const []const u8, log: *std.ArrayList(u8)) !bool {
    const res = try std.process.run(arena, io, .{ .argv = argv });
    try log.appendSlice(arena, res.stdout);
    try log.appendSlice(arena, res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn absPath(arena: Allocator, io: std.Io, p: []const u8) ![]const u8 {
    return try Dir.cwd().realPathFileAlloc(io, p, arena);
}

fn contains(hay: []const []const u8, needle: []const u8) bool {
    for (hay) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// Run after `install`: strip ELF files and static archives in `$pkgdir`.
/// Object files are left alone: the startup files musl ships are linked into programs.
const strip_script =
    \\echo '==> strip'
    \\find "$pkgdir" -type f | while IFS= read -r f; do
    \\    case "$f" in
    \\        *.a) llvm-strip --strip-debug "$f" || true ;;
    \\        *.o) ;; # object files (crt1.o and friends) are left alone
    \\        *) if [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then llvm-strip --strip-unneeded "$f" || true; fi ;;
    \\    esac
    \\done
    \\
;

/// The script that runs inside the sandbox.
pub fn script(arena: Allocator, r: recipe.Recipe, ctx: macro.Context, srcdir: []const u8, opts: Options, bad_macro: *[]const u8) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    const w = struct {
        fn add(a: Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
            try list.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
        }
    };
    var jobs = opts.jobs;
    for (r.options) |o| {
        if (std.mem.startsWith(u8, o, "jobs:"))
            jobs = @min(jobs, std.fmt.parseInt(usize, o["jobs:".len..], 10) catch jobs);
    }
    try w.add(arena, &s, "set -e\nexport jobs={d}\nexport srcdir='{s}'\nexport pkgdir=/destdir\n", .{ jobs, srcdir });
    try s.appendSlice(arena, try ctx.target.buildEnv(arena, ctx.target.isCross(ctx.host), ctx.static));
    if (r.environment) |e| {
        try s.appendSlice(arena, try macro.expand(arena, ctx, e, bad_macro));
        try s.append(arena, '\n');
    }
    try s.appendSlice(arena, "export pkgfiles=/dkbuild/files\n");
    if (r.patches.len > 0) {
        try s.appendSlice(arena, "echo '==> patch'\ncd \"$srcdir\"\n");
        for (r.patches) |pt| try w.add(arena, &s, "patch -Np1 -i '/dkbuild/patches/{s}'\n", .{pt});
    }
    const steps = [_]struct { name: []const u8, body: ?[]const u8 }{
        .{ .name = "setup", .body = r.setup },
        .{ .name = "build", .body = r.build },
        .{ .name = "check", .body = if (contains(r.options, "!check")) null else r.check },
        .{ .name = "install", .body = r.install },
    };
    for (steps) |st| {
        const body = st.body orelse continue;
        try w.add(arena, &s, "echo '==> {s}'\ncd \"$srcdir\"\n", .{st.name});
        try s.appendSlice(arena, try macro.expand(arena, ctx, body, bad_macro));
        try s.append(arena, '\n');
    }
    if (!contains(r.options, "!strip")) try s.appendSlice(arena, strip_script);
    return s.items;
}

/// Everything under `destdir` must sit in an allowed top-level directory,
/// and nothing may be in /usr/local.
pub fn checkPolicy(arena: Allocator, io: std.Io, destdir: []const u8, problems: *std.ArrayList([]const u8)) !void {
    var d = try Dir.cwd().openDir(io, destdir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (!contains(&allowed_top, e.name))
            try problems.append(arena, try std.fmt.allocPrint(arena, "installs /{s}, outside /usr /etc /var /opt /boot", .{e.name}));
    }
    var local = d.openDir(io, "usr/local", .{}) catch return;
    local.close(io);
    try problems.append(arena, "installs into /usr/local");
}

/// Deletes a build's work directory, including a sandbox's overlay layers
/// (see `sandbox.makeRemovable`). Works on leftovers of an earlier build too.
fn removeBuildDir(arena: Allocator, io: std.Io, work: []const u8) void {
    if (std.fs.path.join(arena, &.{ work, "sb", "work" })) |ow| sandbox.makeRemovable(io, ow) else |_| {}
    Dir.cwd().deleteTree(io, work) catch {};
}

const SbDirs = struct { upper: []const u8, work: []const u8, merged: []const u8 };

/// Fresh upper, work and mount-point directories for one sandbox, under `parent`.
fn sbDirs(arena: Allocator, io: std.Io, parent: []const u8, name: []const u8) BuildError!SbDirs {
    var out_dirs: [3][]const u8 = undefined;
    for ([_][]const u8{ "upper", "work", "merged" }, 0..) |sub, k| {
        const rel = try std.fs.path.join(arena, &.{ parent, name, sub });
        Dir.cwd().createDirPath(io, rel) catch return error.PrepareFailed;
        out_dirs[k] = absPath(arena, io, rel) catch return error.PrepareFailed;
    }
    return .{ .upper = out_dirs[0], .work = out_dirs[1], .merged = out_dirs[2] };
}

/// Runs `argv` (absolute path) in the build machine's root, in our sandbox, with
/// `binds`; `sb` is the writable layer.
fn runTool(arena: Allocator, io: std.Io, base_root: []const u8, sb: SbDirs, binds: []const sandbox.Bind, argv: []const []const u8, log: *std.ArrayList(u8)) !bool {
    return sandbox.run(arena, io, .{
        .lower = base_root,
        .upper = sb.upper,
        .work = sb.work,
        .merged = sb.merged,
        .binds = binds,
        .env = &.{ "PATH=/usr/bin:/bin", "HOME=/root" },
        .argv = argv,
    }, log);
}

pub fn buildOne(arena: Allocator, io: std.Io, r: recipe.Recipe, opts: Options) BuildError!void {
    const id = try std.fmt.allocPrint(arena, "{s}-{s}-r{d}", .{ r.name, r.version, r.release });
    out("==> {s}\n", .{id});

    const prof_path = try std.fmt.allocPrint(arena, "{s}/profiles/{s}.toml", .{ opts.root, opts.arch });
    const prof_text = Dir.cwd().readFileAlloc(io, prof_path, arena, .limited(1 << 16)) catch {
        out("error: cannot read {s}\n", .{prof_path});
        return error.BadRecipe;
    };
    var pdiag: profile.Diagnostic = .{};
    const prof = profile.parse(arena, prof_text, &pdiag) catch |err| switch (err) {
        error.InvalidProfile => {
            out("error: {s}: {s}\n", .{ prof_path, pdiag.message });
            return error.BadRecipe;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const ctx: macro.Context = .{ .target = prof, .host = prof, .static = contains(r.options, "static") };

    // 1. Sources
    const cache = try std.fs.path.join(arena, &.{ opts.root, "cache" });
    var first_tarball: ?[]const u8 = null;
    for (r.source) |src| {
        var msg: []const u8 = "";
        _ = fetch.fetchOne(arena, io, cache, src, &msg) catch |err| {
            out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
            return error.PrepareFailed;
        };
        if (first_tarball == null and src == .tarball)
            first_tarball = try fetch.cachePath(arena, cache, src.tarball.sha256);
    }

    // 2. Build root
    const work = try std.fs.path.join(arena, &.{ opts.root, "work", r.name });
    removeBuildDir(arena, io, work);
    const root_rel = try std.fs.path.join(arena, &.{ work, "root" });
    Dir.cwd().createDirPath(io, root_rel) catch return error.PrepareFailed;
    const root_abs = absPath(arena, io, root_rel) catch return error.PrepareFailed;
    const base_root = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "rootfs", "dkrescue" })) catch {
        out("error: rootfs/dkrescue is missing; unpack the build machine with `dkbuild bootstrap-root <dkrescue.iso>` (SPEC.md 9.2)\n", .{});
        return error.PrepareFailed;
    };
    // The writable layer of the build root; the prepare and
    // build steps share it, so what the first installs the second sees.
    const sb = try sbDirs(arena, io, work, "sb");
    defer if (!opts.keep_root) removeBuildDir(arena, io, work);

    var log: std.ArrayList(u8) = .empty;
    const logdir = try std.fs.path.join(arena, &.{ opts.root, "logs", opts.arch });
    Dir.cwd().createDirPath(io, logdir) catch {};
    const logpath = try std.fmt.allocPrint(arena, "{s}/{s}.log", .{ logdir, id });
    defer Dir.cwd().writeFile(io, .{ .sub_path = logpath, .data = log.items }) catch {};

    const local_repo = try std.fmt.allocPrint(arena, "{s}/repo/{s}", .{ opts.root, opts.arch });
    const local_abs: ?[]const u8 = absPath(arena, io, local_repo) catch null;
    const keys_dir: ?[]const u8 = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "keys" })) catch null;
    {
        // Stage 1: the toolchain and libraries are the image's. Only packages
        // this tree built are added, on top, from repo/ (SPEC.md 7.3).
        var specs: std.ArrayList([]const u8) = .empty;
        for ([_][]const []const u8{ r.hostdeps, r.builddeps }) |deps| {
            for (deps) |d| {
                if (opts.tree) |t| if (t.provider(d)) |pi| {
                    const pr = t.recipes[pi];
                    for ([_][]const u8{ d, pr.name }) |want| {
                        const spec = try std.fmt.allocPrint(arena, "{s}={s}-r{d}", .{ want, pr.version, pr.release });
                        if (!contains(specs.items, spec)) try specs.append(arena, spec);
                    }
                    continue;
                };
                out("    note: '{s}' is assumed to be in the base image (stage 1 does not check, SPEC.md 7.3)\n", .{d});
            }
        }
        out("    preparing build root ({d} package(s) from repo/ on top of the base image)\n", .{specs.items.len});
        if (specs.items.len > 0) {
            const la = local_abs orelse {
                out("error: the tree has packages to install but no repo/{s}\n", .{opts.arch});
                return error.PrepareFailed;
            };
            // apk must know what the image already provides (basepkg.zig).
            basepkg.ensure(arena, io, opts.root, base_root, false) catch {
                out("error: cannot describe the base image to apk\n", .{});
                return error.PrepareFailed;
            };
            const base_dir = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, basepkg.dir })) catch return error.PrepareFailed;
            var binds: std.ArrayList(sandbox.Bind) = .empty;
            try binds.append(arena, .{ .src = la, .dst = "/dkrepo", .read_only = true });
            try binds.append(arena, .{ .src = base_dir, .dst = "/dkbase", .read_only = true });
            if (keys_dir) |kd| try binds.append(arena, .{ .src = kd, .dst = "/dkkeys", .read_only = true });
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{
                "/usr/bin/sh", "-c",
                "mkdir -p /etc/apk/keys && { cp /dkkeys/* /etc/apk/keys/ 2>/dev/null || true; } && " ++
                    "apk --root / --initdb --no-network --no-interactive --allow-untrusted add /dkbase/" ++ basepkg.file_name ++ " && " ++
                    "exec apk --root / --no-network --no-interactive --repository /dkrepo/Packages.adb add \"$@\"",
                "apk",
            });
            try argv.appendSlice(arena, specs.items);
            const ok = runTool(arena, io, base_root, sb, binds.items, argv.items, &log) catch false;
            if (!ok) {
                out("error: installing packages from repo/ failed; see {s}\n", .{logpath});
                return error.PrepareFailed;
            }
        }
    }

    // 3. Unpack
    var srcdir: []const u8 = "/build";
    {
        const build_rel = try std.fs.path.join(arena, &.{ root_rel, "build" });
        Dir.cwd().createDirPath(io, build_rel) catch return error.UnpackFailed;
        Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ root_rel, "destdir" })) catch return error.UnpackFailed;
        Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ root_rel, "dkbuild" })) catch return error.UnpackFailed;
        // The recipe's patches/ and files/ appear read-only-by-convention at /dkbuild.
        for ([_][]const u8{ "patches", "files" }) |sub| {
            const from = try std.fs.path.join(arena, &.{ opts.root, "packages", r.name, sub });
            Dir.cwd().access(io, from, .{}) catch continue;
            const to = try std.fs.path.join(arena, &.{ root_rel, "dkbuild", sub });
            const ok = runLogged(arena, io, &.{ "cp", "-r", from, to }, &log) catch false;
            if (!ok) {
                out("error: cannot copy {s}\n", .{from});
                return error.PrepareFailed;
            }
        }
        if (first_tarball) |tb| {
            const ok = runLogged(arena, io, &.{ "tar", "-xf", tb, "-C", build_rel, "--no-same-owner" }, &log) catch false;
            if (!ok) {
                out("error: cannot unpack {s}\n", .{tb});
                return error.UnpackFailed;
            }
            var d = Dir.cwd().openDir(io, build_rel, .{ .iterate = true }) catch return error.UnpackFailed;
            defer d.close(io);
            var it = d.iterate();
            var count: usize = 0;
            var only: []const u8 = "";
            while (it.next(io) catch null) |e| {
                count += 1;
                only = try arena.dupe(u8, e.name);
            }
            if (count == 1) srcdir = try std.fmt.allocPrint(arena, "/build/{s}", .{only});
        }
    }

    // 4. Steps, in the sandbox
    var bad: []const u8 = "";
    const text = script(arena, r, ctx, srcdir, opts, &bad) catch |err| switch (err) {
        error.UnknownMacro => {
            out("error: {s}: unknown macro %{s}\n", .{ r.name, bad });
            return error.BadRecipe;
        },
        else => return error.OutOfMemory,
    };
    Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ root_rel, "dkbuild", "script.sh" }), .data = text }) catch return error.PrepareFailed;

    out("    building\n", .{});
    {
        // The three directories the build writes to are bound in from the host
        // side, so `destdir` can be read after the sandbox is gone.
        const binds = [_]sandbox.Bind{
            .{ .src = try std.fs.path.join(arena, &.{ root_abs, "build" }), .dst = "/build" },
            .{ .src = try std.fs.path.join(arena, &.{ root_abs, "destdir" }), .dst = "/destdir" },
            .{ .src = try std.fs.path.join(arena, &.{ root_abs, "dkbuild" }), .dst = "/dkbuild" },
        };
        const ok = runTool(arena, io, base_root, sb, &binds, &.{ "/usr/bin/sh", "/dkbuild/script.sh" }, &log) catch false;
        if (!ok) {
            out("error: {s} failed; log: {s}\n", .{ id, logpath });
            const tail_start = if (log.items.len > 1500) log.items.len - 1500 else 0;
            out("{s}\n", .{log.items[tail_start..]});
            return error.BuildFailed;
        }
    }

    // 5. Policy
    var problems: std.ArrayList([]const u8) = .empty;
    checkPolicy(arena, io, try std.fs.path.join(arena, &.{ root_rel, "destdir" }), &problems) catch return error.PolicyViolation;
    if (problems.items.len > 0) {
        for (problems.items) |p| out("error: {s}: {s}\n", .{ r.name, p });
        return error.PolicyViolation;
    }
    const destdir_abs = absPath(arena, io, try std.fs.path.join(arena, &.{ root_rel, "destdir" })) catch return error.PrepareFailed;
    const subs_rel = try std.fs.path.join(arena, &.{ work, "pkgs" });
    Dir.cwd().createDirPath(io, subs_rel) catch return error.PrepareFailed;
    const subs_abs = absPath(arena, io, subs_rel) catch return error.PrepareFailed;
    const moved = split.run(arena, io, destdir_abs, subs_abs, try split.merge(arena, r.subpackages)) catch |err| {
        out("error: {s}: splitting subpackages failed: {s}\n", .{ r.name, @errorName(err) });
        return error.BuildFailed;
    };
    var pkg_list: std.ArrayList(Pkg) = .empty;
    const ver = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
    {
        var main = try withScan(arena, io, destdir_abs, r.rundeps);
        main.name = r.name;
        main.summary = r.summary;
        try pkg_list.append(arena, main);
    }
    for (moved) |m| {
        var summary: []const u8 = m.name;
        for (try split.merge(arena, r.subpackages)) |sp| if (std.mem.eql(u8, sp.name, m.name)) {
            summary = sp.summary;
        };
        // -devel needs its main package; -static needs -devel (headers to build against).
        const need = if (std.mem.eql(u8, m.name, "devel"))
            try std.fmt.allocPrint(arena, "{s}={s}", .{ r.name, ver })
        else if (std.mem.eql(u8, m.name, "static"))
            try std.fmt.allocPrint(arena, "{s}-devel={s}", .{ r.name, ver })
        else
            "";
        var sub = try withScan(arena, io, try std.fs.path.join(arena, &.{ subs_abs, m.name }), if (need.len > 0) try arena.dupe([]const u8, &.{need}) else &.{});
        sub.name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ r.name, m.name });
        sub.summary = summary;
        try pkg_list.append(arena, sub);
        out("    {s}-{s}: {d} files\n", .{ r.name, m.name, m.files });
    }
    try publish(arena, io, r, opts, id, base_root, sb, pkg_list.items, &log);
    out("    built {s}; log: {s}\n", .{ id, logpath });
}

/// `apk mkpkg` for the package, then `apk mkndx` to rebuild and sign the
/// architecture's index in repo/<arch>/.
const Pkg = struct {
    name: []const u8,
    summary: []const u8,
    /// Absolute path of the directory holding the package's files.
    files: []const u8,
    depends: []const []const u8,
    provides: []const []const u8 = &.{},
};

/// Declared dependencies plus what the scan found, without duplicates.
fn withScan(arena: Allocator, io: std.Io, files: []const u8, declared: []const []const u8) BuildError!Pkg {
    const res = scan.scanTree(arena, io, files) catch |err| {
        out("error: scanning {s}: {s}\n", .{ files, @errorName(err) });
        return error.BuildFailed;
    };
    var deps: std.ArrayList([]const u8) = .empty;
    try deps.appendSlice(arena, declared);
    for (res.depends) |d| if (!contains(deps.items, d)) try deps.append(arena, d);
    return .{ .name = "", .summary = "", .files = files, .depends = deps.items, .provides = res.provides };
}

fn publish(arena: Allocator, io: std.Io, r: recipe.Recipe, opts: Options, id: []const u8, base_root: []const u8, sb: SbDirs, pkgs: []const Pkg, log: *std.ArrayList(u8)) BuildError!void {
    _ = id;
    if (opts.key.len == 0) {
        out("error: no signing key; create one with:\n  openssl genrsa -out ~/.config/dkbuild/signing.rsa 4096\n", .{});
        return error.PrepareFailed;
    }
    const key_abs = absPath(arena, io, opts.key) catch {
        out("error: signing key {s} not found\n", .{opts.key});
        return error.PrepareFailed;
    };
    const keys_abs = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "keys" })) catch {
        out("error: {s}/keys (public signing keys) not found\n", .{opts.root});
        return error.PrepareFailed;
    };
    const repo_rel = try std.fmt.allocPrint(arena, "{s}/repo/{s}", .{ opts.root, opts.arch });
    Dir.cwd().createDirPath(io, repo_rel) catch return error.PrepareFailed;
    const repo_abs = absPath(arena, io, repo_rel) catch return error.PrepareFailed;

    // Mount points live under /tmp (a tmpfs) so the rootfs stays untouched.
    const out_bind = sandbox.Bind{ .src = repo_abs, .dst = "/tmp/out" };

    // mkpkg, once per package
    for (pkgs) |pk| {
        var argv: std.ArrayList([]const u8) = .empty;
        const binds = [_]sandbox.Bind{ out_bind, .{ .src = pk.files, .dst = "/tmp/files" }, .{ .src = key_abs, .dst = "/tmp/key", .read_only = true } };
        try argv.appendSlice(arena, &.{ "/usr/bin/apk", "mkpkg", "--sign-key", "/tmp/key" });
        const ver = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
        const info = [_][2][]const u8{
            .{ "name", pk.name },
            .{ "version", ver },
            .{ "arch", opts.arch },
            .{ "description", pk.summary },
            .{ "license", r.license },
        };
        for (info) |kv| try argv.appendSlice(arena, &.{ "--info", try std.fmt.allocPrint(arena, "{s}:{s}", .{ kv[0], kv[1] }) });
        if (r.homepage) |h| try argv.appendSlice(arena, &.{ "--info", try std.fmt.allocPrint(arena, "url:{s}", .{h}) });
        // A repeated --info key replaces the earlier value, so lists are one
        // space-separated value.
        if (pk.depends.len > 0) try argv.appendSlice(arena, &.{ "--info", try std.fmt.allocPrint(arena, "depends:{s}", .{try std.mem.join(arena, " ", pk.depends)}) });
        if (pk.provides.len > 0) {
            // apk only picks a provider automatically when the provide has a
            // version: sonames get 0, commands and pkg-config names the package's.
            var versioned: std.ArrayList([]const u8) = .empty;
            for (pk.provides) |pv| try versioned.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ pv, if (std.mem.startsWith(u8, pv, "so:")) "0" else ver }));
            try argv.appendSlice(arena, &.{ "--info", try std.fmt.allocPrint(arena, "provides:{s}", .{try std.mem.join(arena, " ", versioned.items)}) });
        }
        try argv.appendSlice(arena, &.{ "--files", "/tmp/files", "--output", try std.fmt.allocPrint(arena, "/tmp/out/{s}-{s}.apk", .{ pk.name, ver }) });
        const ok = runTool(arena, io, base_root, sb, &binds, argv.items, log) catch false;
        if (!ok) {
            out("error: apk mkpkg failed for {s}\n", .{pk.name});
            return error.BuildFailed;
        }
    }

    // mkndx over every package in the repository directory
    {
        var argv: std.ArrayList([]const u8) = .empty;
        const binds = [_]sandbox.Bind{ out_bind, .{ .src = key_abs, .dst = "/tmp/key", .read_only = true }, .{ .src = keys_abs, .dst = "/tmp/keys", .read_only = true } };
        try argv.appendSlice(arena, &.{ "/usr/bin/apk", "--keys-dir", "/tmp/keys", "mkndx", "--sign-key", "/tmp/key", "--output", "/tmp/out/Packages.adb" });
        var d = Dir.cwd().openDir(io, repo_rel, .{ .iterate = true }) catch return error.PrepareFailed;
        defer d.close(io);
        var it = d.iterate();
        var names: std.ArrayList([]const u8) = .empty;
        while (it.next(io) catch null) |e| {
            if (std.mem.endsWith(u8, e.name, ".apk")) try names.append(arena, try std.fmt.allocPrint(arena, "/tmp/out/{s}", .{e.name}));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        try argv.appendSlice(arena, names.items);
        const ok = runTool(arena, io, base_root, sb, &binds, argv.items, log) catch false;
        if (!ok) {
            out("error: apk mkndx failed\n", .{});
            return error.BuildFailed;
        }
    }
}

test "script runs setup, build, check, install in order with macros expanded" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const p: profile.Profile = .{ .arch = "x86_64", .triple = "x86_64-fenriros-linux-musl", .cpu = "x86-64", .zig_target = "x86_64-linux-musl", .zig_cpu = "baseline", .kernel_arch = "x86" };
    const r: recipe.Recipe = .{
        .name = "t", .version = "1", .release = 1, .summary = "s", .license = "MIT",
        .source = &.{}, .build = "%make", .install = "%make_install",
    };
    var bad: []const u8 = "";
    const s = try script(a, r, .{ .target = p, .host = p }, "/build/t-1", .{ .root = ".", .jobs = 4 }, &bad);
    try std.testing.expect(std.mem.indexOf(u8, s, "export jobs=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "--target=x86_64-fenriros-linux-musl") != null);
    const b = std.mem.indexOf(u8, s, "==> build").?;
    const i = std.mem.indexOf(u8, s, "==> install").?;
    try std.testing.expect(b < i);
    try std.testing.expect(std.mem.indexOf(u8, s, "==> setup") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "DESTDIR=$pkgdir install") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "==> patch") == null);
}

test "patches are applied in order before setup" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const p: profile.Profile = .{ .arch = "x86_64", .triple = "x86_64-fenriros-linux-musl", .cpu = "x86-64", .zig_target = "x86_64-linux-musl", .zig_cpu = "baseline", .kernel_arch = "x86" };
    const r: recipe.Recipe = .{
        .name = "t", .version = "1", .release = 1, .summary = "s", .license = "MIT",
        .source = &.{}, .patches = &.{ "a.patch", "b.patch" }, .setup = "echo setup", .install = "x",
    };
    var bad: []const u8 = "";
    const s = try script(a, r, .{ .target = p, .host = p }, "/build/t-1", .{ .root = "." }, &bad);
    const pa = std.mem.indexOf(u8, s, "-i '/dkbuild/patches/a.patch'").?;
    const pb = std.mem.indexOf(u8, s, "-i '/dkbuild/patches/b.patch'").?;
    const su = std.mem.indexOf(u8, s, "==> setup").?;
    try std.testing.expect(pa < pb and pb < su);
}
