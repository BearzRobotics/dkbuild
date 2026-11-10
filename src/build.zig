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
const inputs = @import("inputs.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const Options = struct {
    /// Project root (holds packages/, profiles/, rootfs/, cache/, work/, logs/).
    root: []const u8,
    arch: []const u8 = "x86_64",
    jobs: usize = 1,
    keep_root: bool = false,
    /// Skip every recipe's check step (first bring-up builds).
    no_check: bool = false,
    /// Dependencies this tree provides are not installed from the bootstrap
    /// repositories; they will come from repo/ once packaging exists.
    tree: ?tree.Tree = null,
    /// Private key that signs the repository index (never in the project).
    key: []const u8 = "",
};

/// Top-level directories a package may install into (SPEC.md 7 step 4).
const allowed_top = [_][]const u8{ "usr", "etc", "var", "opt", "boot" };

pub const BuildError = error{ BuildFailed, PrepareFailed, UnpackFailed, PolicyViolation, BadRecipe } || Allocator.Error;

/// When several builds run at once (sched.zig), each worker thread collects
/// its console output here and the scheduler prints it in one piece when the
/// build ends. Null: print as it happens. Grown with `std.heap.smp_allocator`.
pub threadlocal var console: ?*std.ArrayList(u8) = null;

fn out(comptime fmt: []const u8, args: anytype) void {
    if (console) |c| {
        c.print(std.heap.smp_allocator, fmt, args) catch {};
        return;
    }
    std.debug.print(fmt, args);
}

/// Downloads and vendoring of one source happen one at a time (two builds that
/// share a source would write the same `.part` file in the cache), but
/// different sources do not wait for each other: a source takes the lock its
/// checksum picks out of these. A cached source only checks its file.
var fetch_locks: [64]std.Io.Mutex = @splat(.init);

fn fetchLock(src: recipe.Source) *std.Io.Mutex {
    const key: []const u8 = switch (src) {
        .tarball => |t| t.sha256,
        .git => |g| g.url,
    };
    return &fetch_locks[@as(usize, @truncate(std.hash.Wyhash.hash(0, key))) % fetch_locks.len];
}
/// One index rebuild at a time (`apk mkndx` writes Packages.adb in place).
var index_mutex: std.Io.Mutex = .init;

/// A recipe that caps its jobs (`jobs:N`) is a large build (LLVM, Zig): the
/// scheduler runs it alone, never beside another build.
pub fn isHeavy(r: recipe.Recipe) bool {
    for (r.options) |o| if (std.mem.startsWith(u8, o, "jobs:")) return true;
    return false;
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
    // The variables SPEC 5.5 lists besides jobs/srcdir/pkgdir/CC/CFLAGS.
    try w.add(arena, &s, "export target='{s}'\nexport arch='{s}'\nexport zig_target='{s}'\nexport zig_cpu='{s}'\n", .{ ctx.target.triple, ctx.target.arch, ctx.target.zig_target, ctx.target.zig_cpu });
    try s.appendSlice(arena, try ctx.target.buildEnv(arena, ctx.target.isCross(ctx.host), ctx.static));
    // Go builds offline from the shared module cache (fetch.zig), checked
    // against go.sum when it was filled.
    if (contains(r.options, "godeps"))
        try s.appendSlice(arena, "export GOMODCACHE=/dkdeps/go GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOFLAGS=-mod=mod\n");
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
        .{ .name = "check", .body = if (contains(r.options, "!check") or opts.no_check) null else r.check },
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

/// Hash of `r`'s build script with dkbuild's macros expanded, for the record
/// (inputs.Record.script): the same for every machine (one job, a fixed
/// source directory), so it changes only when a recipe or a macro does.
pub fn scriptHash(arena: Allocator, io: std.Io, r: recipe.Recipe, opts: Options) !inputs.Hex {
    const prof_path = try std.fmt.allocPrint(arena, "{s}/profiles/{s}.toml", .{ opts.root, opts.arch });
    const prof_text = try Dir.cwd().readFileAlloc(io, prof_path, arena, .limited(1 << 16));
    var pdiag: profile.Diagnostic = .{};
    const prof = try profile.parse(arena, prof_text, &pdiag);
    const ctx: macro.Context = .{ .target = prof, .host = prof, .static = contains(r.options, "static") };
    var fixed = opts;
    fixed.jobs = 1;
    var bad: []const u8 = "";
    const text = try script(arena, r, ctx, "/build/src", fixed, &bad);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(text);
    return std.fmt.bytesToHex(h.finalResult(), .lower);
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
    // musl's loader only searches /usr/lib; CMake's GNUInstallDirs picks lib64
    // on x86_64 unless told otherwise (%cmake does).
    if (d.openDir(io, "usr/lib64", .{})) |lib64| {
        var l = lib64;
        l.close(io);
        try problems.append(arena, "installs into /usr/lib64 (libraries go in /usr/lib: -DCMAKE_INSTALL_LIBDIR=lib, --libdir=/usr/lib)");
    } else |_| {}
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

/// The `.apk` files (names inside repo/<arch>) a build needs on top of the base
/// image: the packages providing its host and build dependencies, and what
/// those need to build and run (their own build and run dependencies, and the
/// main package next to a `-devel`). Dependencies the tree does not provide are
/// the image's (stage 1 assumes it has them).
/// Whether a source URL names a tar archive (anything else is copied, not unpacked).
fn isTarArchive(url: []const u8) bool {
    const exts = [_][]const u8{ ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.Z" };
    var u = url;
    if (std.mem.indexOfAny(u8, u, "?#")) |i| u = u[0..i];
    for (exts) |e| if (std.mem.endsWith(u8, u, e)) return true;
    // GitHub and GitLab archive links without an extension in the path.
    return std.mem.indexOf(u8, u, "/archive/") != null and !std.mem.endsWith(u8, u, ".zip");
}

test "isTarArchive" {
    try std.testing.expect(isTarArchive("https://x.org/a-1.0.tar.xz"));
    try std.testing.expect(isTarArchive("https://github.com/o/r/archive/v1.tar.gz"));
    try std.testing.expect(!isTarArchive("https://docbook.org/xml/4.5/docbook-xml-4.5.zip"));
    try std.testing.expect(!isTarArchive("https://x.org/protocol-21.1.txt"));
}

fn inTreeFiles(arena: Allocator, io: std.Io, opts: Options, r: recipe.Recipe, repo_abs: ?[]const u8) BuildError![]const []const u8 {
    const t = opts.tree orelse return &.{};
    var work: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ r.hostdeps, r.builddeps }) |deps| try work.appendSlice(arena, deps);
    const direct = work.items.len;
    var k: usize = 0;
    while (k < work.items.len) : (k += 1) {
        const d = work.items[k];
        if (contains(seen.items, d)) continue;
        try seen.append(arena, d);
        const pi = t.provider(d) orelse {
            if (k < direct) out("    note: '{s}' is assumed to be in the base image (stage 1 does not check, SPEC.md 7.3)\n", .{d});
            continue;
        };
        const pr = t.recipes[pi];
        // Also the provider's -libs, when it has one: its programs and -devel need the
        // libraries, and `apk extract` does not follow dependencies.
        const libs_name = try std.fmt.allocPrint(arena, "{s}-libs", .{pr.name});
        for ([_][]const u8{ d, pr.name, libs_name }) |want| {
            const file = try std.fmt.allocPrint(arena, "{s}-{s}-r{d}.apk", .{ want, pr.version, pr.release });
            const optional = std.mem.eql(u8, want, libs_name);
            if (contains(files.items, file)) continue;
            const present = if (repo_abs) |ra| blk: {
                const path = try std.fs.path.join(arena, &.{ ra, file });
                break :blk if (Dir.cwd().access(io, path, .{})) |_| true else |_| false;
            } else false;
            if (!present) {
                if (k < direct and !optional) {
                    out("error: {s} is not in repo/{s}; it should have been built before {s}\n", .{ file, opts.arch, r.name });
                    return error.PrepareFailed;
                }
                continue;
            }
            try files.append(arena, file);
        }
        // What the provider needs once installed (not its build tools).
        for ([_][]const []const u8{ pr.builddeps, pr.rundeps }) |deps| try work.appendSlice(arena, deps);
        // A subpackage's own `depends` (llvm-devel needs llvm-static: LLVM's
        // CMake files name every static library).
        for (pr.subpackages) |sp| {
            if (d.len == pr.name.len + 1 + sp.name.len and std.mem.startsWith(u8, d, pr.name) and
                d[pr.name.len] == '-' and std.mem.eql(u8, d[pr.name.len + 1 ..], sp.name))
                try work.appendSlice(arena, sp.depends);
        }
    }
    return files.items;
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

/// For a rebuild only because the build root changed (sched.zig): what the
/// last build of this release produced, and how to move to the next release.
pub const Rebuild = struct {
    previous: inputs.Produced,
    /// Writes the next release into the recipe and returns it; called only
    /// when the rebuild came out different.
    bump: *const fn (ctx: *anyopaque) anyerror!u32,
    ctx: *anyopaque,
};

pub const Built = struct {
    produced: inputs.Produced,
    /// The release it was published as (`r.release`, or the bumped one).
    release: u32,
    /// False when a rebuild came out identical: the package already in repo/
    /// is kept, and nothing is published.
    published: bool,
};

/// Builds `r` and publishes it. A `rebuild` that comes out identical to the
/// last build is not published (its package stays, at its release); one that
/// differs gets the next release first (SPEC.md 7.2).
pub fn buildOne(arena: Allocator, io: std.Io, r_in: recipe.Recipe, opts: Options, rebuild: ?Rebuild) BuildError!Built {
    var r = r_in;
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
    // Dependencies fetched on the host into the shared stores (fetch.zig): the
    // lists of what this package uses.
    var zig_list: ?[]const u8 = null;
    var cargo_list: ?[]const u8 = null;
    var cargo_config: ?[]const u8 = null;
    var uses_go = false;
    {
        for (r.source) |src| {
            const lock = fetchLock(src);
            lock.lockUncancelable(io);
            defer lock.unlock(io);
            var msg: []const u8 = "";
            _ = fetch.fetchOne(arena, io, cache, src, &msg) catch |err| {
                out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                return error.PrepareFailed;
            };
            if (first_tarball == null and src == .tarball) {
                first_tarball = try fetch.cachePath(arena, cache, src.tarball.sha256);
                if (contains(r.options, "zigdeps")) {
                    _ = fetch.fetchZigDeps(arena, io, cache, src.tarball.sha256, &msg) catch |err| {
                        out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                        return error.PrepareFailed;
                    };
                    zig_list = try fetch.zigDepsPath(arena, cache, src.tarball.sha256);
                }
                if (contains(r.options, "cargodeps")) {
                    _ = fetch.fetchCargoDeps(arena, io, cache, src.tarball.sha256, &msg) catch |err| {
                        out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                        return error.PrepareFailed;
                    };
                    cargo_list = try fetch.cargoDepsPath(arena, cache, src.tarball.sha256);
                    cargo_config = try std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.config.toml", .{ cache, src.tarball.sha256 });
                }
                if (contains(r.options, "godeps")) {
                    _ = fetch.fetchGoDeps(arena, io, cache, src.tarball.sha256, &msg) catch |err| {
                        out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                        return error.PrepareFailed;
                    };
                    uses_go = true;
                }
            }
        }
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
        // Stage 1: the toolchain and libraries are the image's. The packages
        // this tree built are laid over it from repo/ with `apk extract`, which
        // checks each signature but not dependencies: the image has no package
        // database, so there is nothing for a solver to work with (SPEC.md 7.3).
        const files = try inTreeFiles(arena, io, opts, r, local_abs);
        out("    preparing build root ({d} package(s) from repo/ on top of the base image)\n", .{files.len});
        if (files.len > 0) {
            var binds: std.ArrayList(sandbox.Bind) = .empty;
            try binds.append(arena, .{ .src = local_abs.?, .dst = "/dkrepo", .read_only = true });
            if (keys_dir) |kd| try binds.append(arena, .{ .src = kd, .dst = "/dkkeys", .read_only = true });
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ "/usr/bin/apk", "--force-overwrite", "--keys-dir", "/dkkeys", "extract", "--destination", "/" });
            for (files) |f| try argv.append(arena, try std.fmt.allocPrint(arena, "/dkrepo/{s}", .{f}));
            const ok = runTool(arena, io, base_root, sb, binds.items, argv.items, &log) catch false;
            if (!ok) {
                out("error: unpacking packages from repo/ failed; see {s}\n", .{logpath});
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
            const from = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), sub });
            Dir.cwd().access(io, from, .{}) catch continue;
            const to = try std.fs.path.join(arena, &.{ root_rel, "dkbuild", sub });
            const ok = runLogged(arena, io, &.{ "cp", "-r", from, to }, &log) catch false;
            if (!ok) {
                out("error: cannot copy {s}\n", .{from});
                return error.PrepareFailed;
            }
        }
        // Sources in order: a tar archive is unpacked into /build (the first
        // one's top directory is $srcdir; the others land next to it); any
        // other file (a .zip, a .txt) is copied to /build/sources/<name>.
        if (first_tarball != null) {
            var first = true;
            for (r.source) |src| {
                if (src != .tarball) continue;
                const file = try fetch.cachePath(arena, cache, src.tarball.sha256);
                if (!src.tarball.unpack or src.tarball.name != null or !isTarArchive(src.tarball.url)) {
                    const sdir = try std.fs.path.join(arena, &.{ build_rel, "sources" });
                    Dir.cwd().createDirPath(io, sdir) catch return error.UnpackFailed;
                    const base = src.tarball.name orelse std.fs.path.basename(src.tarball.url);
                    const ok = runLogged(arena, io, &.{ "cp", file, try std.fs.path.join(arena, &.{ sdir, base }) }, &log) catch false;
                    if (!ok) return error.UnpackFailed;
                    first = false;
                    continue;
                }
                const ok = runLogged(arena, io, &.{ "tar", "-xf", file, "-C", build_rel, "--no-same-owner" }, &log) catch false;
                if (!ok) {
                    out("error: cannot unpack {s}\n", .{file});
                    return error.UnpackFailed;
                }
                if (first) {
                    first = false;
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
        }
        // Crates and Zig packages from the shared stores: symbolic links to
        // where the build sees the stores (read-only, bound at /dkdeps), so a
        // build cannot change them. Go reads its module cache directly.
        const dest = try std.fmt.allocPrint(arena, "{s}{s}", .{ build_rel, srcdir["/build".len..] });
        var lay: std.ArrayList(u8) = .empty;
        if (cargo_list) |cl| {
            const text = Dir.cwd().readFileAlloc(io, cl, arena, .limited(1 << 22)) catch return error.UnpackFailed;
            try lay.appendSlice(arena, "mkdir -p vendor .cargo\n");
            try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "cp '{s}' .cargo/config.toml\n", .{cargo_config.?}));
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |l| {
                var f = std.mem.tokenizeScalar(u8, l, ' ');
                const n = f.next() orelse continue;
                const k = f.next() orelse continue;
                try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "ln -sfn '/dkdeps/crates/{s}' 'vendor/{s}'\n", .{ k, n }));
            }
        }
        if (zig_list) |zl| {
            const text = Dir.cwd().readFileAlloc(io, zl, arena, .limited(1 << 22)) catch return error.UnpackFailed;
            try lay.appendSlice(arena, "mkdir -p zig-pkg\n");
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |n| try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "ln -sfn '/dkdeps/zig/{s}' 'zig-pkg/{s}'\n", .{ n, n }));
        }
        if (lay.items.len > 0) {
            const ok = runLogged(arena, io, &.{ "sh", "-ec", try std.fmt.allocPrint(arena, "cd '{s}'\n{s}", .{ dest, lay.items }) }, &log) catch false;
            if (!ok) {
                out("error: cannot lay out the vendored dependencies of {s}\n", .{r.name});
                return error.UnpackFailed;
            }
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
        var binds: std.ArrayList(sandbox.Bind) = .empty;
        try binds.appendSlice(arena, &.{
            .{ .src = try std.fs.path.join(arena, &.{ root_abs, "build" }), .dst = "/build" },
            .{ .src = try std.fs.path.join(arena, &.{ root_abs, "destdir" }), .dst = "/destdir" },
            .{ .src = try std.fs.path.join(arena, &.{ root_abs, "dkbuild" }), .dst = "/dkbuild" },
        });
        // The shared dependency stores, read-only.
        for ([_]struct { use: bool, sub: []const u8, dst: []const u8 }{
            .{ .use = cargo_list != null, .sub = "crates", .dst = "/dkdeps/crates" },
            .{ .use = zig_list != null, .sub = "zigpkg", .dst = "/dkdeps/zig" },
            .{ .use = uses_go, .sub = "gomod", .dst = "/dkdeps/go" },
        }) |st| {
            if (!st.use) continue;
            const rel = try std.fs.path.join(arena, &.{ cache, st.sub });
            Dir.cwd().createDirPath(io, rel) catch return error.PrepareFailed;
            try binds.append(arena, .{ .src = absPath(arena, io, rel) catch return error.PrepareFailed, .dst = st.dst, .read_only = true });
        }
        const ok = runTool(arena, io, base_root, sb, binds.items, &.{ "/usr/bin/sh", "/dkbuild/script.sh" }, &log) catch false;
        if (!ok) {
            out("error: {s} failed; log: {s}\n", .{ id, logpath });
            const tail_start = if (log.items.len > 1500) log.items.len - 1500 else 0;
            out("{s}\n", .{log.items[tail_start..]});
            return error.BuildFailed;
        }
    }

    // 5. Policy
    var problems: std.ArrayList([]const u8) = .empty;
    // `rootlayout` (base-files) ships the root's own directories (/dev, /proc, ...).
    if (!contains(r.options, "rootlayout"))
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
    // What this build produced, before anything names a release: an identical
    // rebuild is not published, and a different one is published as the next
    // release, which the packages' metadata below must carry.
    var parts: std.ArrayList(inputs.Part) = .empty;
    try parts.append(arena, .{ .name = r.name, .dir = destdir_abs });
    for (moved) |m| try parts.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ r.name, m.name }), .dir = try std.fs.path.join(arena, &.{ subs_abs, m.name }) });
    const produced = inputs.outputHash(arena, io, parts.items) catch |err| {
        out("error: {s}: hashing what it produced failed: {s}\n", .{ r.name, @errorName(err) });
        return error.BuildFailed;
    };
    if (rebuild) |rb| {
        if (std.mem.eql(u8, &rb.previous.output, &produced.output)) {
            out("    rebuilt {s}: identical to the package in repo/, kept as is; log: {s}\n", .{ id, logpath });
            return .{ .produced = produced, .release = r.release, .published = false };
        }
        r.release = rb.bump(rb.ctx) catch |err| {
            out("error: {s}: cannot bump its release in its recipe: {s}\n", .{ r.name, @errorName(err) });
            return error.BuildFailed;
        };
        out("    {s} came out different: published as release {d} (bumped in its recipe)\n", .{ id, r.release });
    }
    const pub_id = try std.fmt.allocPrint(arena, "{s}-{s}-r{d}", .{ r.name, r.version, r.release });

    var pkg_list: std.ArrayList(Pkg) = .empty;
    const ver = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
    {
        var main = try withScan(arena, io, destdir_abs, r.rundeps);
        main.name = r.name;
        main.summary = r.summary;
        if (r.provides.len > 0) {
            var all: std.ArrayList([]const u8) = .empty;
            try all.appendSlice(arena, main.provides);
            for (r.provides) |pv| if (!contains(all.items, pv)) try all.append(arena, pv);
            main.provides = all.items;
        }
        try pkg_list.append(arena, main);
    }
    for (moved) |m| {
        var summary: []const u8 = m.name;
        var sp_depends: []const []const u8 = &.{};
        var sp_install_if: []const []const u8 = &.{};
        for (try split.merge(arena, r.subpackages)) |sp| if (std.mem.eql(u8, sp.name, m.name)) {
            summary = sp.summary;
            sp_depends = sp.depends;
            sp_install_if = sp.install_if;
        };
        // -devel needs its main package; -static needs -devel (headers to build against).
        // When the package has a -libs, -devel needs that and not the programs.
        const has_libs = for (moved) |mm| {
            if (std.mem.eql(u8, mm.name, "libs")) break true;
        } else false;
        const need = if (std.mem.eql(u8, m.name, "devel"))
            try std.fmt.allocPrint(arena, "{s}{s}={s}", .{ r.name, if (has_libs) "-libs" else "", ver })
        else if (std.mem.eql(u8, m.name, "static"))
            try std.fmt.allocPrint(arena, "{s}-devel={s}", .{ r.name, ver })
        else
            "";
        var declared: std.ArrayList([]const u8) = .empty;
        if (need.len > 0) try declared.append(arena, need);
        try declared.appendSlice(arena, sp_depends);
        var sub = try withScan(arena, io, try std.fs.path.join(arena, &.{ subs_abs, m.name }), declared.items);
        sub.name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ r.name, m.name });
        sub.summary = summary;
        sub.install_if = sp_install_if;
        try pkg_list.append(arena, sub);
        out("    {s}-{s}: {d} files\n", .{ r.name, m.name, m.files });
    }
    try publish(arena, io, r, opts, pub_id, base_root, sb, pkg_list.items, &log);
    out("    built {s}; log: {s}\n", .{ pub_id, logpath });
    return .{ .produced = produced, .release = r.release, .published = true };
}

/// The install script names apk knows (apk-package(5)).
const script_types = [_][]const u8{ "pre-install", "post-install", "pre-upgrade", "post-upgrade", "pre-deinstall", "post-deinstall", "trigger" };

/// `apk mkpkg` for the package, then `apk mkndx` to rebuild and sign the
/// architecture's index in repo/<arch>/.
const Pkg = struct {
    name: []const u8,
    summary: []const u8,
    /// Absolute path of the directory holding the package's files.
    files: []const u8,
    depends: []const []const u8,
    provides: []const []const u8 = &.{},
    install_if: []const []const u8 = &.{},
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
    // Checked here, before any package is made; reindex uses them.
    _ = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "keys" })) catch {
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
        if (pk.install_if.len > 0) try argv.appendSlice(arena, &.{ "--info", try std.fmt.allocPrint(arena, "install-if:{s}", .{try std.mem.join(arena, " ", pk.install_if)}) });
        // apk-tools 3 takes trigger paths as --trigger, one per path.
        if (std.mem.eql(u8, pk.name, r.name)) for (r.triggers) |tr| try argv.appendSlice(arena, &.{ "--trigger", tr });
        if (pk.provides.len > 0) {
            // apk only picks a provider automatically when the provide has a
            // version: sonames get 0, commands and pkg-config names the package's.
            var versioned: std.ArrayList([]const u8) = .empty;
            for (pk.provides) |pv| try versioned.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ pv, if (std.mem.startsWith(u8, pv, "so:")) "0" else ver }));
            try argv.appendSlice(arena, &.{ "--info", try std.fmt.allocPrint(arena, "provides:{s}", .{try std.mem.join(arena, " ", versioned.items)}) });
        }
        // Install scripts (SPEC 9.4): scripts/<type> next to package.toml, on the
        // main package only. The types are apk-package(5)'s.
        var all_binds: std.ArrayList(sandbox.Bind) = .empty;
        try all_binds.appendSlice(arena, &binds);
        if (std.mem.eql(u8, pk.name, r.name)) {
            const sdir = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "scripts" });
            if (absPath(arena, io, sdir)) |sabs| {
                try all_binds.append(arena, .{ .src = sabs, .dst = "/tmp/scripts", .read_only = true });
                for (script_types) |t| {
                    Dir.cwd().access(io, try std.fs.path.join(arena, &.{ sdir, t }), .{}) catch continue;
                    try argv.appendSlice(arena, &.{ "--script", try std.fmt.allocPrint(arena, "{s}:/tmp/scripts/{s}", .{ t, t }) });
                }
            } else |_| {}
        }
        // Written as .part and renamed when complete: a build running beside
        // this one may unpack from repo/ or index it at any moment, and must
        // never see half a package (mkndx below only takes *.apk).
        const file = try std.fmt.allocPrint(arena, "{s}-{s}.apk", .{ pk.name, ver });
        try argv.appendSlice(arena, &.{ "--files", "/tmp/files", "--output", try std.fmt.allocPrint(arena, "/tmp/out/{s}.part", .{file}) });
        const part = try std.fmt.allocPrint(arena, "{s}/{s}.part", .{ repo_rel, file });
        const ok = runTool(arena, io, base_root, sb, all_binds.items, argv.items, log) catch false;
        if (!ok) {
            Dir.cwd().deleteFile(io, part) catch {};
            out("error: apk mkpkg failed for {s}\n", .{pk.name});
            return error.BuildFailed;
        }
        Dir.cwd().rename(part, Dir.cwd(), try std.fmt.allocPrint(arena, "{s}/{s}", .{ repo_rel, file }), io) catch {
            out("error: cannot move {s} into place\n", .{part});
            return error.BuildFailed;
        };
    }

    try reindex(arena, io, opts, base_root, sb, log);
}

/// `apk mkndx` over every package in repo/<arch>/, signed: one build at a time
/// (it lists the directory, then writes Packages.adb in place).
fn reindex(arena: Allocator, io: std.Io, opts: Options, base_root: []const u8, sb: SbDirs, log: *std.ArrayList(u8)) BuildError!void {
    const key_abs = absPath(arena, io, opts.key) catch {
        out("error: signing key {s} not found\n", .{opts.key});
        return error.PrepareFailed;
    };
    const keys_abs = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "keys" })) catch return error.PrepareFailed;
    const repo_rel = try std.fmt.allocPrint(arena, "{s}/repo/{s}", .{ opts.root, opts.arch });
    const repo_abs = absPath(arena, io, repo_rel) catch return error.PrepareFailed;
    index_mutex.lockUncancelable(io);
    defer index_mutex.unlock(io);
    var argv: std.ArrayList([]const u8) = .empty;
    const binds = [_]sandbox.Bind{ .{ .src = repo_abs, .dst = "/tmp/out" }, .{ .src = key_abs, .dst = "/tmp/key", .read_only = true }, .{ .src = keys_abs, .dst = "/tmp/keys", .read_only = true } };
    try argv.appendSlice(arena, &.{ "/usr/bin/apk", "--keys-dir", "/tmp/keys", "mkndx", "--sign-key", "/tmp/key", "--output", "/tmp/out/Packages.adb" });
    var d = Dir.cwd().openDir(io, repo_rel, .{ .iterate = true }) catch return error.PrepareFailed;
    defer d.close(io);
    var it = d.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (it.next(io) catch null) |e| {
        if (std.mem.endsWith(u8, e.name, ".apk")) try names.append(arena, try std.fmt.allocPrint(arena, "/tmp/out/{s}", .{e.name}));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try argv.appendSlice(arena, names.items);
    const ok = runTool(arena, io, base_root, sb, &binds, argv.items, log) catch false;
    if (!ok) {
        out("error: apk mkndx failed\n", .{});
        return error.BuildFailed;
    }
}

/// What a file in repo/<arch>/ is, for `prune`.
pub const RepoFile = enum { current, stale, orphan, other };

/// `<pkgname>-<version>-r<N>.apk` against the tree: current (a package of a
/// recipe at its present version-release), stale (a recipe's package at
/// another version), or orphan (no recipe provides that package name).
pub fn classify(t: tree.Tree, file: []const u8) RepoFile {
    if (!std.mem.endsWith(u8, file, ".apk")) return .other;
    const stem = file[0 .. file.len - ".apk".len];
    const rdash = std.mem.lastIndexOf(u8, stem, "-r") orelse return .other;
    const rel = stem[rdash + 2 ..];
    if (rel.len == 0) return .other;
    for (rel) |c| if (!std.ascii.isDigit(c)) return .other;
    const vdash = std.mem.lastIndexOfScalar(u8, stem[0..rdash], '-') orelse return .other;
    const pkg = stem[0..vdash];
    const ver = stem[vdash + 1 .. rdash];
    const idx = t.provider(pkg) orelse return .orphan;
    const r = t.recipes[idx];
    const want_rel = std.fmt.parseInt(u32, rel, 10) catch return .other;
    return if (std.mem.eql(u8, ver, r.version) and want_rel == r.release) .current else .stale;
}

/// The main package of the recipe a stale file belongs to, at the recipe's
/// present version-release: once that is built, the recipe's older files go
/// (including subpackages the recipe no longer makes).
fn currentFile(arena: Allocator, t: tree.Tree, file: []const u8) Allocator.Error!?[]const u8 {
    const stem = file[0 .. file.len - ".apk".len];
    const rdash = std.mem.lastIndexOf(u8, stem, "-r") orelse return null;
    const vdash = std.mem.lastIndexOfScalar(u8, stem[0..rdash], '-') orelse return null;
    const r = t.recipes[t.provider(stem[0..vdash]) orelse return null];
    return try std.fmt.allocPrint(arena, "{s}-{s}-r{d}.apk", .{ r.name, r.version, r.release });
}

/// Deletes stale packages from repo/<arch>/, once their recipe's present
/// version is built (an older package is never removed before that), and
/// rebuilds the index. Orphans (a recipe was removed or renamed) are only
/// reported.
/// The shared dependency stores (fetch.zig): lists whose source tarball no
/// recipe uses any more go, and then every crate or Zig package no remaining
/// list names. Go's module cache is left to `go clean -modcache`. Do not run
/// it while a fetch is running: a fetch moves into the store before it lists.
fn pruneDeps(arena: Allocator, io: std.Io, opts: Options, t: tree.Tree, dry_run: bool) !void {
    const cache = try std.fs.path.join(arena, &.{ opts.root, "cache" });
    const kinds = [_]struct { option: []const u8, dir: []const u8, store: ?[]const u8, field: usize }{
        .{ .option = "cargodeps", .dir = "cargodeps", .store = "crates", .field = 1 },
        .{ .option = "zigdeps", .dir = "zigdeps", .store = "zigpkg", .field = 0 },
        .{ .option = "godeps", .dir = "godeps", .store = null, .field = 0 },
    };
    var removed: usize = 0;
    for (kinds) |k| {
        // The source tarballs of the recipes that use this kind.
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (t.recipes) |r| {
            if (!contains(r.options, k.option)) continue;
            for (r.source) |src| if (src == .tarball) {
                try wanted.put(arena, src.tarball.sha256, {});
                break;
            };
        }
        const dir_rel = try std.fs.path.join(arena, &.{ cache, k.dir });
        var keep: std.StringHashMapUnmanaged(void) = .empty;
        var d = Dir.cwd().openDir(io, dir_rel, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (std.mem.startsWith(u8, e.name, "tmp-") or e.name.len < 64) continue;
            const sha = e.name[0..64];
            if (wanted.contains(sha)) {
                if (!std.mem.endsWith(u8, e.name, ".list")) continue;
                const text = d.readFileAlloc(io, e.name, arena, .limited(1 << 22)) catch continue;
                var lines = std.mem.tokenizeScalar(u8, text, '\n');
                while (lines.next()) |l| {
                    var f = std.mem.tokenizeScalar(u8, l, ' ');
                    var i: usize = 0;
                    while (f.next()) |v| : (i += 1) if (i == k.field) try keep.put(arena, try arena.dupe(u8, v), {});
                }
                continue;
            }
            out("{s} {s}/{s}\n", .{ if (dry_run) "would remove" else "removing", k.dir, e.name });
            removed += 1;
            if (!dry_run) d.deleteFile(io, e.name) catch {};
        }
        const store = k.store orelse continue;
        const store_rel = try std.fs.path.join(arena, &.{ cache, store });
        var sd = Dir.cwd().openDir(io, store_rel, .{ .iterate = true }) catch continue;
        defer sd.close(io);
        var stale: std.ArrayList([]const u8) = .empty;
        var sit = sd.iterate();
        while (sit.next(io) catch null) |e| {
            if (!keep.contains(e.name)) try stale.append(arena, try arena.dupe(u8, e.name));
        }
        for (stale.items) |n| {
            out("{s} {s}/{s}\n", .{ if (dry_run) "would remove" else "removing", store, n });
            removed += 1;
            if (!dry_run) sd.deleteTree(io, n) catch {};
        }
    }
    out("{d} stale dependency file(s) or store entr(ies){s}\n", .{ removed, if (dry_run) " (dry run: nothing removed)" else "" });
}

pub fn prune(arena: Allocator, io: std.Io, opts: Options, dry_run: bool) BuildError!void {
    const t = opts.tree orelse return error.BadRecipe;
    try pruneDeps(arena, io, opts, t, dry_run);
    const repo_rel = try std.fmt.allocPrint(arena, "{s}/repo/{s}", .{ opts.root, opts.arch });
    var d = Dir.cwd().openDir(io, repo_rel, .{ .iterate = true }) catch {
        out("nothing to prune: {s} does not exist\n", .{repo_rel});
        return;
    };
    defer d.close(io);
    var stale: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        switch (classify(t, e.name)) {
            .stale => {
                const cur = (try currentFile(arena, t, e.name)) orelse continue;
                if (d.access(io, cur, .{})) |_| {
                    try stale.append(arena, try arena.dupe(u8, e.name));
                } else |_| out("kept (its {s} is not built yet): {s}\n", .{ cur, e.name });
            },
            .orphan => out("orphan (no recipe provides it; left alone): {s}\n", .{e.name}),
            else => {},
        }
    }
    std.mem.sort([]const u8, stale.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (stale.items) |f| {
        out("{s} {s}\n", .{ if (dry_run) "would remove" else "removing", f });
        if (!dry_run) d.deleteFile(io, f) catch |err| out("warning: cannot remove {s}: {s}\n", .{ f, @errorName(err) });
    }
    if (dry_run or stale.items.len == 0) {
        out("{d} stale package(s){s}\n", .{ stale.items.len, if (dry_run) " (dry run: nothing removed)" else "" });
        return;
    }
    const base_root = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "rootfs", "dkrescue" })) catch return error.PrepareFailed;
    const work = try std.fs.path.join(arena, &.{ opts.root, "work", "prune" });
    removeBuildDir(arena, io, work);
    defer removeBuildDir(arena, io, work);
    const sb = try sbDirs(arena, io, work, "sb");
    var log: std.ArrayList(u8) = .empty;
    reindex(arena, io, opts, base_root, sb, &log) catch |err| {
        out("{s}\n", .{log.items});
        return err;
    };
    out("removed {d} stale package(s); index rebuilt\n", .{stale.items.len});
}

test "classify: current, stale and orphan packages in repo/" {
    const rc = struct {
        fn f(name: []const u8, version: []const u8, release: u32) recipe.Recipe {
            return .{ .name = name, .version = version, .release = release, .summary = "s", .license = "MIT", .source = &.{}, .install = "x" };
        }
    }.f;
    const t: tree.Tree = .{ .recipes = &.{ rc("spirv-tools", "1.4.363.0", 3), rc("zlib", "1.3", 1) } };
    try std.testing.expectEqual(RepoFile.current, classify(t, "spirv-tools-1.4.363.0-r3.apk"));
    try std.testing.expectEqual(RepoFile.current, classify(t, "spirv-tools-devel-1.4.363.0-r3.apk"));
    try std.testing.expectEqual(RepoFile.stale, classify(t, "spirv-tools-1.4.363.0-r2.apk"));
    try std.testing.expectEqual(RepoFile.stale, classify(t, "spirv-tools-libs-1.4.363.0-r1.apk"));
    try std.testing.expectEqual(RepoFile.stale, classify(t, "zlib-1.2-r1.apk"));
    try std.testing.expectEqual(RepoFile.orphan, classify(t, "gone-1-r1.apk"));
    try std.testing.expectEqual(RepoFile.other, classify(t, "Packages.adb"));
    try std.testing.expectEqual(RepoFile.other, classify(t, "zlib.dkhash"));
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
