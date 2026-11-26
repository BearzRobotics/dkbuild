//! Building one recipe (SPEC.md 7): prepare a root, unpack, run the steps in
//! the sandbox, check what was installed. Packaging comes after this.
//!
//! Stage 1 (SPEC.md 7.3, 9.2): builds run on the DKRescue image (rootfs/dkrescue,
//! from `dkbuild bootstrap-root`) under a writable layer, in our own sandbox.

const term = @import("term.zig");
const std = @import("std");
const recipe = @import("recipe.zig");
const fetch = @import("fetch.zig");
const npmdeps = @import("npmdeps.zig");
const gemdeps = @import("gemdeps.zig");
const pubdeps = @import("pubdeps.zig");
const hackagedeps = @import("hackagedeps.zig");
const pydeps = @import("pydeps.zig");
/// Sets up npm's cache from the npm store in a build (npmdeps).
const npm_offline_js = @embedFile("scripts/npm-offline.js");
const pnpm_registry_js = @embedFile("scripts/pnpm-registry.js");
/// gradledeps: the resolve step's init script, the store copier, and the build's init script.
const gradle_resolve = @embedFile("scripts/gradle-resolve.gradle");
const gradle_store_sh = @embedFile("scripts/gradle-store.sh");
const gradle_offline = @embedFile("scripts/gradle-offline.gradle");
/// mavendeps: copies a restore's local repository into the shared Maven-layout store.
const maven_store_sh = @embedFile("scripts/maven-store.sh");
/// nugetdeps: copies a restore's packages into the shared store.
const nuget_store_sh = @embedFile("scripts/nuget-store.sh");
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
    /// DKBUILD_FAST_WORK: build roots of recipes that are not heavy go here
    /// (a faster disk), while it has 30 GB free (buildWorkDir).
    fast_work: ?[]const u8 = null,
};

/// Top-level directories a package may install into (SPEC.md 7 step 4).
const allowed_top = [_][]const u8{ "usr", "etc", "var", "opt", "boot" };

pub const BuildError = error{ BuildFailed, PrepareFailed, UnpackFailed, PolicyViolation, BadRecipe, MissingDependency } || Allocator.Error;

/// When several builds run at once (sched.zig), each worker thread collects
/// its console output here and the scheduler prints it in one piece when the
/// build ends. Null: print as it happens. Grown with `std.heap.smp_allocator`.
pub threadlocal var console: ?*std.ArrayList(u8) = null;

fn out(comptime fmt: []const u8, args: anytype) void {
    if (console) |c| {
        c.print(std.heap.smp_allocator, fmt, args) catch {};
        return;
    }
    term.print(fmt, args);
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

/// Where a recipe's build root goes (SPEC.md 7): `<root>/work/<name>`, or
/// `$DKBUILD_FAST_WORK/<name>` when that is set and the directory's file system
/// has enough free space, so a fast but small disk is never filled: at least
/// 30 GB for an ordinary recipe, at least 100 GB for a heavy one (`jobs:N`:
/// LLVM, Firefox, Chromium; their trees are tens of GB and are the ones that
/// stall a slow disk, a shingled hard disk above all).
fn buildWorkDir(arena: Allocator, io: std.Io, opts: Options, r: recipe.Recipe) ![]const u8 {
    const default = try std.fs.path.join(arena, &.{ opts.root, "work", r.name });
    const fast = opts.fast_work orelse return default;
    if (fast.len == 0) return default;
    var need_kb: u64 = 30 * 1024 * 1024;
    for (r.options) |o| if (std.mem.startsWith(u8, o, "jobs:")) {
        need_kb = 100 * 1024 * 1024;
    };
    Dir.cwd().createDirPath(io, fast) catch return default;
    const res = std.process.run(arena, io, .{ .argv = &.{ "df", "-Pk", fast } }) catch return default;
    var lines = std.mem.tokenizeScalar(u8, res.stdout, '\n');
    _ = lines.next();
    const line = lines.next() orelse return default;
    var cols = std.mem.tokenizeScalar(u8, line, ' ');
    var i: usize = 0;
    while (cols.next()) |c| : (i += 1) if (i == 3) {
        const kb = std.fmt.parseInt(u64, c, 10) catch return default;
        if (kb < need_kb) return default;
        return try std.fs.path.join(arena, &.{ fast, r.name });
    };
    return default;
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
    try w.add(arena, &s, "export name='{s}'\nexport version='{s}'\nexport release={d}\n", .{ r.name, r.version, r.release });
    // The variables SPEC 5.5 lists besides jobs/srcdir/pkgdir/CC/CFLAGS.
    try w.add(arena, &s, "export target='{s}'\nexport arch='{s}'\nexport zig_target='{s}'\nexport zig_cpu='{s}'\n", .{ ctx.target.triple, ctx.target.arch, ctx.target.zig_target, ctx.target.zig_cpu });
    try s.appendSlice(arena, try ctx.target.buildEnv(arena, ctx.target.isCross(ctx.host), ctx.static));
    // The default RUSTFLAGS (profile.Profile.rustEnv) only for a recipe built with the rust
    // package: the line is part of the script hash, so on every recipe it would rebuild the tree.
    // (The rust recipe itself has no rust in its hostdeps and manages its own flags.)
    if (contains(r.hostdeps, "rust")) try s.appendSlice(arena, profile.Profile.rustEnv(contains(r.options, "static")));
    if (contains(r.options, "gcc")) try s.appendSlice(arena, try profile.gccEnv(ctx.target, arena, ctx.static));
    // Go builds offline from the shared module cache (fetch.zig), checked
    // against go.sum when it was filled.
    // npm installs offline from the shared store (npmdeps.zig): npm-offline.js
    // makes a private npm cache whose content is the store, indexed by the
    // lockfiles' tarball URLs.
    if (contains(r.options, "npmdeps"))
        try s.appendSlice(arena,
            \\node /dkbuild/npm-offline.js /tmp/npm-cache $(find /build -path /build/sources -prune -o -name package-lock.json -not -path '*/node_modules/*' -print)
            \\export npm_config_cache=/tmp/npm-cache npm_config_offline=true npm_config_audit=false npm_config_fund=false npm_config_update_notifier=false
            \\# pnpm (pnpm-lock.yaml): the store served as a registry on 127.0.0.1
            \\pnpm_locks=$(find /build -path /build/sources -prune -o -name pnpm-lock.yaml -not -path '*/node_modules/*' -print)
            \\# yarn 2+ (the recipe's files/yarn.package-lock.json, from dkbuild yarn-lock):
            \\# the same registry
            \\yarn_locks=$(ls /dkbuild/files/*yarn.package-lock.json 2>/dev/null || true)
            \\pnpm_locks="$pnpm_locks $yarn_locks"; pnpm_locks=${pnpm_locks# }; pnpm_locks=${pnpm_locks% }
            \\if [ -n "$pnpm_locks" ] && [ ! -f /tmp/pnpm-registry.ready ]; then
            \\    node /dkbuild/pnpm-registry.js 4873 /tmp/pnpm-registry.ready $pnpm_locks > /tmp/pnpm-registry.log 2>&1 &
            \\    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -f /tmp/pnpm-registry.ready ] && break; sleep 0.5; done
            \\    [ -f /tmp/pnpm-registry.ready ] || { echo "pnpm-registry did not start"; cat /tmp/pnpm-registry.log; exit 1; }
            \\fi
            \\if [ -n "$pnpm_locks" ]; then
            \\    export npm_config_registry=http://127.0.0.1:4873/ npm_config_store_dir=/tmp/pnpm-store PNPM_HOME=/tmp/pnpm-home
            \\    # pnpm 11 reads only pnpm_config_* (not npm_config_*): without these it asks the
            \\    # real registry, finds no network and retries each package for hours
            \\    export pnpm_config_registry=http://127.0.0.1:4873/ pnpm_config_store_dir=/tmp/pnpm-store
            \\    unset npm_config_offline
            \\fi
            \\if [ -n "$yarn_locks" ]; then
            \\    # yarn 2+: that registry only, a private cache, the lockfile's zip
            \\    # checksums not compared (the tarballs were checked at fetch time;
            \\    # yarn's zips differ between its versions); no telemetry
            \\    export YARN_NPM_REGISTRY_SERVER=http://127.0.0.1:4873 YARN_UNSAFE_HTTP_WHITELIST=127.0.0.1 \\
            \\        YARN_ENABLE_GLOBAL_CACHE=false YARN_CACHE_FOLDER=/tmp/yarn-cache YARN_CHECKSUM_BEHAVIOR=ignore \\
            \\        YARN_ENABLE_TELEMETRY=false YARN_ENABLE_INLINE_BUILDS=true YARN_ENABLE_HARDENED_MODE=false
            \\fi
            \\
        );
    // yarn 2+ (`yarnberry`, with npmdeps): the two line continuations in the block above are written as
    // `\\` (these literals are raw), so dash ran `export \` and stopped ("export: \: bad variable name").
    // Corrected only for the recipes that use yarn: the block is part of every npmdeps script hash.
    if (contains(r.options, "yarnberry")) {
        const fixed = try std.mem.replaceOwned(u8, arena, s.items, " \\\\\n        YARN_", " \\\n        YARN_");
        s.clearRetainingCapacity();
        try s.appendSlice(arena, fixed);
    }
    // Gradle (gradledeps): the recipe's Gradle distribution, and `gradle` on
    // PATH always offline with the store as its only repository.
    if (contains(r.options, "gradledeps"))
        try s.appendSlice(arena,
            \\mkdir -p /tmp/gradle-dist /tmp/dkbin
            \\unzip -q -o "$(ls /build/sources/gradle-*-bin.zip | head -n1)" -d /tmp/gradle-dist
            \\printf '#!/bin/sh\nexport JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Dorg.gradle.native=false"\nexec %s/bin/gradle --offline --no-daemon -g /tmp/ghome -I /dkbuild/gradle-offline.gradle "$@"\n' "$(ls -d /tmp/gradle-dist/gradle-*)" > /tmp/dkbin/gradle
            \\chmod 755 /tmp/dkbin/gradle
            \\# Gradle's native helpers (file events, ...) are glibc builds: off
            \\mkdir -p /tmp/ghome && printf 'org.gradle.native=false\norg.gradle.vfs.watch=false\n' > /tmp/ghome/gradle.properties
            \\export PATH="/tmp/dkbin:$PATH"
            \\
        );
    // Maven (mavendeps): the recipe's Maven distribution, and `mvn` on PATH with the store (a file:// repository) as the mirror of every repository.
    if (contains(r.options, "mavendeps"))
        try s.appendSlice(arena,
            \\mkdir -p /tmp/maven-dist /tmp/dkbin
            \\tar -xzf "$(ls /build/sources/apache-maven-*-bin.tar.gz | head -n1)" -C /tmp/maven-dist
            \\printf '%s\n' '<settings><localRepository>/tmp/m2</localRepository><mirrors><mirror><id>dkstore</id><mirrorOf>*</mirrorOf><url>file:///dkdeps/maven</url></mirror></mirrors></settings>' > /tmp/dk-settings.xml
            \\printf '#!/bin/sh\nexec %s/bin/mvn -B -s /tmp/dk-settings.xml "$@"\n' "$(ls -d /tmp/maven-dist/apache-maven-*)" > /tmp/dkbin/mvn
            \\chmod 755 /tmp/dkbin/mvn
            \\export PATH="/tmp/dkbin:$PATH"
            \\
        );
    // Ruby (gemdeps): Bundler installs the source gems laid in vendor/cache.
    if (contains(r.options, "gemdeps"))
        try s.appendSlice(arena, "export BUNDLE_FORCE_RUBY_PLATFORM=true BUNDLE_DISABLE_VERSION_CHECK=true GEM_HOME=/tmp/gems\n");
    // Dart (pubdeps): the pub cache laid out in the source tree before the build.
    if (contains(r.options, "pubdeps"))
        try s.appendSlice(arena, "export PUB_CACHE=\"$srcdir/.dkpub\" PUB_ENVIRONMENT=dkbuild DART_SUPPRESS_ANALYTICS=true\n");
    // Haskell (hackagedeps): cabal's only repository is .dkhackage, offline.
    if (contains(r.options, "hackagedeps")) try s.appendSlice(arena, hackagedeps.env);
    // Python (pydeps): pip and uv install only from .dkpython, offline.
    if (contains(r.options, "pydeps")) try s.appendSlice(arena, pydeps.env);
    if (contains(r.options, "godeps"))
        try s.appendSlice(arena, "export GOMODCACHE=/dkdeps/go GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOFLAGS=-mod=mod\n");
    // NuGet (nugetdeps): a private package folder; the store is the only feed
    // ($DKBUILD_NUGET, for `dotnet restore --source`); no telemetry.
    if (contains(r.options, "nugetdeps"))
        try s.appendSlice(arena, "export NUGET_PACKAGES=/tmp/nuget DKBUILD_NUGET=/dkdeps/nuget HOME=/tmp DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1\n");
    if (r.environment) |e| {
        try s.appendSlice(arena, try macro.expand(arena, ctx, e, bad_macro));
        try s.append(arena, '\n');
    }
    try s.appendSlice(arena, "export pkgfiles=/dkbuild/files\n");
    if (r.patches.len > 0) {
        try s.appendSlice(arena, "echo '==> patch'\ncd \"$srcdir\"\n");
        // A patch that touches .cargo/config.toml finds the laid config (the
        // patched one plus the vendored sources, see `lay`) already patched:
        // `patch -N` skips that hunk and exits 1. Accept it when every hunk of the
        // patch is present (it reverses cleanly, --dry-run); a hunk that really
        // failed does not, and stops the build as before.
        for (r.patches) |pt| try w.add(arena, &s, "patch -Np1 -i '/dkbuild/patches/{s}' || patch -Rp1 -s --dry-run -i '/dkbuild/patches/{s}'\n", .{ pt, pt });
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
    // a way of running a build, not a change to it: records keep the hash of the script with its check
    fixed.no_check = false;
    var bad: []const u8 = "";
    const text = try script(arena, r, ctx, "/build/src", fixed, &bad);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(text);
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// Removes `destdir`/`sub` if it is a tree of nothing but directories, and says whether it did. `destdir` is
/// what an untrusted build left: no link is followed on the way or inside (a `var` that is a link would
/// otherwise lead to the host's directories), and only empty directories are removed, never a file.
fn dropEmptyTree(arena: Allocator, io: std.Io, destdir: []const u8, sub: []const u8) !bool {
    var parent = Dir.cwd().openDir(io, destdir, .{}) catch return false;
    defer parent.close(io);
    var rest = sub;
    while (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const next = parent.openDir(io, rest[0..slash], .{ .follow_symlinks = false }) catch return false;
        parent.close(io);
        parent = next;
        rest = rest[slash + 1 ..];
    }
    var dirs: std.ArrayList([]const u8) = .empty;
    {
        var top = parent.openDir(io, rest, .{ .iterate = true, .follow_symlinks = false }) catch return false;
        defer top.close(io);
        var w = try top.walk(arena);
        defer w.deinit();
        while (w.next(io) catch return false) |e| {
            if (e.kind != .directory) return false;
            try dirs.append(arena, try std.fs.path.join(arena, &.{ rest, e.path }));
        }
    }
    // deepest first (a longer path is never the parent of a shorter one)
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn longer(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.longer);
    for (dirs.items) |d| parent.deleteDir(io, d) catch return false;
    parent.deleteDir(io, rest) catch return false;
    return true;
}

/// Everything under `destdir` must sit in an allowed top-level directory,
/// and nothing may be in /usr/local.
pub fn checkPolicy(arena: Allocator, io: std.Io, destdir: []const u8, problems: *std.ArrayList([]const u8)) !void {
    // /run (and /var/run, a link to it) is a tmpfs made at boot: many installs
    // create empty directories there, which are dropped (tmpfiles.d makes
    // them at boot). Files there are still an error.
    for ([_][]const u8{ "run", "var/run" }) |sub| {
        if (try dropEmptyTree(arena, io, destdir, sub))
            out("    note: dropped the empty /{s} the install made (a tmpfs at boot; use tmpfiles.d)\n", .{sub});
    }
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

/// The name of a restore step's list: its source, and what else decides what it downloads (the recipe's patches,
/// the restore step itself, its environment).
fn restoreKey(arena: Allocator, io: std.Io, opts: Options, r: recipe.Recipe, cache: []const u8, kind: []const u8, sha: []const u8) BuildError![]const u8 {
    var extra: std.ArrayList([]const u8) = .empty;
    if (r.restore) |x| try extra.appendSlice(arena, &.{ "restore", x });
    if (r.environment) |x| try extra.appendSlice(arena, &.{ "environment", x });
    const patch_dir = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "patches" });
    const key = fetch.depsKey(arena, io, sha, patch_dir, r.patches, extra.items) catch return error.PrepareFailed;
    Dir.cwd().createDirPath(io, try std.fs.path.join(arena, &.{ cache, kind })) catch return error.PrepareFailed;
    fetch.adoptList(arena, io, cache, kind, sha, key) catch return error.PrepareFailed;
    return key;
}

const StoreKind = enum { maven, nuget };
const Stage = struct { store: []const u8, lists: []const u8 };

/// Empty directories for one restore step to write into: its store and its dependency list.
fn restoreStage(arena: Allocator, io: std.Io, work: []const u8, name: []const u8) BuildError!Stage {
    var dirs: [2][]const u8 = undefined;
    for ([_][]const u8{ "store", "lists" }, &dirs) |sub, *d| {
        const rel = try std.fs.path.join(arena, &.{ work, try std.fmt.allocPrint(arena, "stage-{s}", .{name}), sub });
        Dir.cwd().createDirPath(io, rel) catch return error.PrepareFailed;
        d.* = absPath(arena, io, rel) catch return error.PrepareFailed;
    }
    return .{ .store = dirs[0], .lists = dirs[1] };
}

/// A line of a restore's list: a plain relative path.
fn safeStorePath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    for (p) |c| if (c < ' ' or c == 0x7f) return false;
    var parts = std.mem.splitScalar(u8, p, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// Adds what a restore step downloaded into its staging store to the shared one, then writes its list at
/// `list_path`. The step ran upstream code, so only regular files are taken, a file the store has already is never
/// replaced, and the checksum files are made here from the contents.
fn mergeRestored(arena: Allocator, io: std.Io, kind: StoreKind, stage: Stage, store: []const u8, list_path: []const u8, log: *std.ArrayList(u8)) !void {
    const list_name = std.fs.path.basename(list_path);
    var lists = try Dir.cwd().openDir(io, stage.lists, .{});
    defer lists.close(io);
    const st = try lists.statFile(io, list_name, .{ .follow_symlinks = false });
    if (st.kind != .file) return error.BadRestoreList;
    const list = try lists.readFileAlloc(io, list_name, arena, .limited(1 << 24));

    var src = try Dir.cwd().openDir(io, stage.store, .{ .iterate = true });
    defer src.close(io);
    var w = try src.walk(arena);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (e.kind != .file) continue;
        const wanted = switch (kind) {
            .maven => !std.mem.endsWith(u8, e.path, ".sha1") and !std.mem.endsWith(u8, e.path, ".sha256") and !std.mem.endsWith(u8, e.path, ".part"),
            .nuget => std.mem.endsWith(u8, e.path, ".nupkg"),
        };
        if (!wanted or !safeStorePath(e.path)) continue;
        const from = try std.fs.path.join(arena, &.{ stage.store, e.path });
        const to = try std.fs.path.join(arena, &.{ store, e.path });
        if (pathExists(io, to)) {
            // a repository's metadata differs from one restore to the next; an artifact should not
            if (!std.mem.eql(u8, std.fs.path.basename(e.path), "maven-metadata.xml")) {
                const a = try fetch.hashFile(io, from);
                const b = try fetch.hashFile(io, to);
                if (!std.mem.eql(u8, &a, &b))
                    try log.appendSlice(arena, try std.fmt.allocPrint(arena, "warning: {s} downloaded with other contents than the store's; the store's is kept\n", .{e.path}));
            }
            continue;
        }
        try Dir.cwd().createDirPath(io, std.fs.path.dirname(to) orelse store);
        // its checksums first: a build never sees an artifact without them
        const data = try src.readFileAlloc(io, e.path, std.heap.page_allocator, .limited(1 << 31));
        defer std.heap.page_allocator.free(data);
        switch (kind) {
            .maven => {
                var s1: [20]u8 = undefined;
                std.crypto.hash.Sha1.hash(data, &s1, .{});
                var s2: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(data, &s2, .{});
                try placeFile(arena, io, try std.fmt.allocPrint(arena, "{s}.sha1", .{to}), try std.fmt.allocPrint(arena, "{s}\n", .{&std.fmt.bytesToHex(s1, .lower)}));
                try placeFile(arena, io, try std.fmt.allocPrint(arena, "{s}.sha256", .{to}), try std.fmt.allocPrint(arena, "{s}\n", .{&std.fmt.bytesToHex(s2, .lower)}));
            },
            .nuget => {
                var s5: [64]u8 = undefined;
                std.crypto.hash.sha2.Sha512.hash(data, &s5, .{});
                var b64: [std.base64.standard.Encoder.calcSize(64)]u8 = undefined;
                try placeFile(arena, io, try std.fmt.allocPrint(arena, "{s}.sha512", .{to}), std.base64.standard.Encoder.encode(&b64, &s5));
            },
        }
        try placeFile(arena, io, to, data);
    }

    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    while (lines.next()) |l| if (safeStorePath(l)) {
        try kept.appendSlice(arena, l);
        try kept.append(arena, '\n');
    };
    try placeFile(arena, io, list_path, kept.items);
}

/// Writes a file under a name of this process's own, then renames it into place: it is whole or not there, also
/// when two restores add the same artifact at once.
fn placeFile(arena: Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(arena, "{s}.dk-{x}.part", .{ path, &rnd });
    errdefer Dir.cwd().deleteFile(io, tmp) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    try Dir.cwd().rename(tmp, Dir.cwd(), path, io);
}

/// A path under `cache` as the layout script's sandbox sees it, under /dkcache.
fn inLay(arena: Allocator, cache: []const u8, path: []const u8) BuildError![]const u8 {
    if (!std.mem.startsWith(u8, path, cache) or path.len <= cache.len or path[cache.len] != '/') return error.UnpackFailed;
    return std.fmt.allocPrint(arena, "/dkcache{s}", .{path[cache.len..]});
}

/// Deletes a build's work directory, including a sandbox's overlay layers.
/// Works on leftovers of an earlier build too.
/// Returns whether nothing is left. A build may leave directories without owner permission anywhere (Go's
/// read-only module trees, a `chmod 555` in a test, each overlay's `work/work` of mode 000), which a delete
/// cannot enter: `chmod -R` first, which does not follow the links it meets.
fn removeBuildDir(arena: Allocator, io: std.Io, work: []const u8) bool {
    if (!pathExists(io, work)) return true;
    _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", "--", work } }) catch {};
    Dir.cwd().deleteTree(io, work) catch {};
    return !pathExists(io, work);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| return err != error.FileNotFound;
    return true;
}

/// The `.apk` files (names inside repo/<arch>) a build needs on top of the base
/// image: the packages providing its host and build dependencies, and what
/// those need to build and run (their own build and run dependencies, and the
/// main package next to a `-devel`). Dependencies the tree does not provide are
/// the image's (stage 1 assumes it has them).
/// Whether a source URL names a tar archive (anything else is copied, not unpacked).
/// A .zip source, unpacked like a tarball unless the recipe says unpack = false.
fn isZipArchive(url: []const u8) bool {
    var u = url;
    if (std.mem.indexOfAny(u8, u, "?#")) |i| u = u[0..i];
    return std.mem.endsWith(u8, u, ".zip");
}

fn isTarArchive(url: []const u8) bool {
    const exts = [_][]const u8{ ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.Z", ".crate" };
    // Snapshots (fetch.zig) are zstd tarballs.
    if (std.mem.startsWith(u8, url, "snapshot:")) return true;
    var u = url;
    if (std.mem.indexOfAny(u8, u, "?#")) |i| u = u[0..i];
    for (exts) |e| if (std.mem.endsWith(u8, u, e)) return true;
    // GitHub and GitLab archive links without an extension in the path.
    return std.mem.indexOf(u8, u, "/archive/") != null and !std.mem.endsWith(u8, u, ".zip");
}

test "removeBuildDir removes read-only and mode-000 directories and follows no link out" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "w/destdir/ro");
    try tmp.dir.writeFile(io, .{ .sub_path = "w/destdir/ro/f", .data = "old" });
    try tmp.dir.createDirPath(io, "w/sign/work/work");
    try tmp.dir.createDirPath(io, "outside/ro");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/ro/keep", .data = "keep" });
    try tmp.dir.symLink(io, "../../outside", "w/destdir/out", .{});
    try tmp.dir.setFilePermissions(io, "w/destdir/ro", .fromMode(0o555), .{});
    try tmp.dir.setFilePermissions(io, "w/sign/work/work", .fromMode(0), .{});
    try tmp.dir.setFilePermissions(io, "outside/ro", .fromMode(0o555), .{});
    defer tmp.dir.setFilePermissions(io, "outside/ro", .fromMode(0o755), .{}) catch {};
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const w = try std.fs.path.join(a, &.{ base, "w" });
    try std.testing.expect(removeBuildDir(a, io, w));
    try std.testing.expect(!pathExists(io, w));
    try std.testing.expect(removeBuildDir(a, io, w)); // nothing there is fine too
    const kept = try tmp.dir.statFile(io, "outside/ro", .{});
    try std.testing.expectEqual(@as(u32, 0o555), @as(u32, kept.permissions.toMode()) & 0o777);
    try tmp.dir.access(io, "outside/ro/keep", .{});
}

test "checkPolicy drops empty /run trees and follows no link out of destdir (BC-11, SS-17)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const at = struct {
        fn path(arena: Allocator, b: []const u8, p: []const u8) ![]const u8 {
            return std.fs.path.join(arena, &.{ b, p });
        }
    }.path;
    try tmp.dir.createDirPath(io, "victim/run/keep/deeper");
    // the build made var, or run itself, a link to a directory outside
    try tmp.dir.createDirPath(io, "d1");
    try tmp.dir.symLink(io, "../victim", "d1/var", .{});
    try std.testing.expect(!try dropEmptyTree(a, io, try at(a, base, "d1"), "var/run"));
    try tmp.dir.createDirPath(io, "d2");
    try tmp.dir.symLink(io, "../victim/run", "d2/run", .{});
    try std.testing.expect(!try dropEmptyTree(a, io, try at(a, base, "d2"), "run"));
    try tmp.dir.access(io, "victim/run/keep/deeper", .{});
    // an honest empty tree goes; one with a file, or a link, stays
    try tmp.dir.createDirPath(io, "d3/var/run/a/b");
    try std.testing.expect(try dropEmptyTree(a, io, try at(a, base, "d3"), "var/run"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "d3/var/run", .{}));
    try tmp.dir.access(io, "d3/var", .{});
    try tmp.dir.createDirPath(io, "d4/run/a");
    try tmp.dir.writeFile(io, .{ .sub_path = "d4/run/a/pid", .data = "1" });
    try std.testing.expect(!try dropEmptyTree(a, io, try at(a, base, "d4"), "run"));
    try tmp.dir.access(io, "d4/run/a/pid", .{});
    try tmp.dir.createDirPath(io, "d5/run");
    try tmp.dir.symLink(io, "../../victim", "d5/run/l", .{});
    try std.testing.expect(!try dropEmptyTree(a, io, try at(a, base, "d5"), "run"));
    try std.testing.expect(!try dropEmptyTree(a, io, try at(a, base, "d5"), "var/run"));
}

test "isTarArchive" {
    try std.testing.expect(isTarArchive("https://x.org/a-1.0.tar.xz"));
    try std.testing.expect(isTarArchive("https://github.com/o/r/archive/v1.tar.gz"));
    try std.testing.expect(!isTarArchive("https://docbook.org/xml/4.5/docbook-xml-4.5.zip"));
    // crates.io packages are gzipped tarballs.
    try std.testing.expect(isTarArchive("https://static.crates.io/crates/bindgen-cli/bindgen-cli-0.73.2.crate"));
    try std.testing.expect(!isTarArchive("https://x.org/protocol-21.1.txt"));
    try std.testing.expect(isTarArchive("snapshot:electron v43.8.3 150.0.7871.250 c4cdaeebba9b9ed92d041997317ffdbd042158ac"));
}

/// A subpackage dependency `name=@built` becomes `name=<version>`: the version
/// of `name` (or of `name-devel`, the same build) that was in the build root.
/// zfs-kmod's `linux=@built` pins it to the kernel its modules were built for.
/// Anything else is returned as it is.
fn builtDep(arena: Allocator, dep: []const u8, root_files: []const []const u8) ![]const u8 {
    if (!std.mem.endsWith(u8, dep, "=@built")) return dep;
    const name = dep[0 .. dep.len - "=@built".len];
    for ([_][]const u8{ name, try std.fmt.allocPrint(arena, "{s}-devel", .{name}) }) |n| {
        for (root_files) |f| {
            const base = std.fs.path.basename(f);
            if (!std.mem.startsWith(u8, base, n) or base.len <= n.len + 1 or base[n.len] != '-') continue;
            const rest = base[n.len + 1 ..];
            if (rest.len == 0 or !std.ascii.isDigit(rest[0]) or !std.mem.endsWith(u8, rest, ".apk")) continue;
            return std.fmt.allocPrint(arena, "{s}={s}", .{ name, rest[0 .. rest.len - ".apk".len] });
        }
    }
    out("error: {s}: no {s} in the build root to pin to\n", .{ dep, name });
    return error.PrepareFailed;
}

test "builtDep pins to the version in the build root" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const files = [_][]const u8{ "/x/repo/x86_64/linux-headers-6.19-r3.apk", "/x/repo/x86_64/linux-devel-6.19-r10.apk" };
    try std.testing.expectEqualStrings("linux=6.19-r10", try builtDep(a, "linux=@built", &files));
    try std.testing.expectEqualStrings("zfs", try builtDep(a, "zfs", &files));
}

fn inTreeFiles(arena: Allocator, io: std.Io, opts: Options, r: recipe.Recipe, repo_abs: ?[]const u8) BuildError![]const []const u8 {
    const t = opts.tree orelse return &.{};
    var work: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ r.hostdeps, r.builddeps }) |deps| try work.appendSlice(arena, deps);
    // selfhost (dotnet): the newest package of this recipe already in repo/,
    // whatever its version, is the compiler the build runs, with what it
    // needs; with none yet, this is the first build and stage0deps stand in.
    if (contains(r.options, "selfhost")) {
        // with its declared subpackages of that build (dotnet-artifacts: the
        // packages the next build starts from); one without them all (made
        // before the recipe declared one) does not count
        var previous: ?[]const []const u8 = null;
        if (try previousBuild(arena, io, r.name, repo_abs)) |f| {
            var set: std.ArrayList([]const u8) = .empty;
            try set.append(arena, f);
            const ver = f[r.name.len + 1 .. f.len - ".apk".len];
            for (r.subpackages) |sp| {
                const sf = try std.fmt.allocPrint(arena, "{s}-{s}-{s}.apk", .{ r.name, sp.name, ver });
                const path = try std.fs.path.join(arena, &.{ repo_abs.?, sf });
                if (Dir.cwd().access(io, path, .{})) |_| try set.append(arena, sf) else |_| break;
            } else previous = set.items;
        }
        if (previous) |set| {
            try files.appendSlice(arena, set);
            try work.appendSlice(arena, r.rundeps);
            out("    selfhost: {s} from repo/\n", .{set[0]});
        } else {
            try work.appendSlice(arena, r.stage0deps);
            out("    selfhost: no earlier {s} in repo/, a stage 0 build with its stage0deps\n", .{r.name});
        }
    }
    const direct = work.items.len;
    // checkdeps (SPEC 5.2): what the `check` step needs. They come after `direct`, so one
    // that is not built yet is just left out (the check then fails on its own, loudly)
    // instead of stopping the build; none are installed when the check does not run.
    if (!opts.no_check and !contains(r.options, "!check") and r.check != null)
        try work.appendSlice(arena, r.checkdeps);
    var k: usize = 0;
    while (k < work.items.len) : (k += 1) {
        const d = work.items[k];
        if (contains(seen.items, d)) continue;
        try seen.append(arena, d);
        const pi = t.provider(d) orelse {
            // (the run's summary lists these once: main.zig, baseImageNames)
            continue;
        };
        const pr = t.recipes[pi];
        // Also the provider's -libs, when it has one: its programs and -devel need the
        // libraries, and `apk extract` does not follow dependencies.
        const libs_name = try std.fmt.allocPrint(arena, "{s}-libs", .{pr.name});
        // With a -devel, its -static too: CMake and pkg-config files often name
        // the static libraries, and every library ships one (SPEC.md 5.7).
        const static_name = if (std.mem.endsWith(u8, d, "-devel") or std.mem.eql(u8, d, pr.name)) try std.fmt.allocPrint(arena, "{s}-static", .{pr.name}) else libs_name;
        // A build dependency on a package's bare name brings its -devel too:
        // header-only libraries (eigen, mdds, xorgproto, ...) keep their
        // headers and .pc in -devel, and recipes name them without it.
        const devel_name = if (std.mem.eql(u8, d, pr.name)) try std.fmt.allocPrint(arena, "{s}-devel", .{pr.name}) else libs_name;
        for ([_][]const u8{ d, pr.name, libs_name, devel_name, static_name }) |want| {
            const file = try std.fmt.allocPrint(arena, "{s}-{s}-r{d}.apk", .{ want, pr.version, pr.release });
            const optional = std.mem.eql(u8, want, libs_name) or std.mem.eql(u8, want, static_name) or std.mem.eql(u8, want, devel_name);
            if (contains(files.items, file)) continue;
            const present = if (repo_abs) |ra| blk: {
                const path = try std.fs.path.join(arena, &.{ ra, file });
                break :blk if (Dir.cwd().access(io, path, .{})) |_| true else |_| false;
            } else false;
            if (!present) {
                if (k < direct and !optional) {
                    // Not this recipe's fault: something it needs was never built
                    // (or failed in an earlier run). Reported as a skip.
                    out("==> {s}: skipped, it needs {s}, which is not built ({s} is not in repo/{s})\n", .{ r.name, d, file, opts.arch });
                    return error.MissingDependency;
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

/// The newest `<name>-<version>-r<release>.apk` in repo/ (by modification
/// time: the last one built), for a selfhost recipe; not its subpackages
/// (`<name>-devel-...`: a version starts with a digit).
fn previousBuild(arena: Allocator, io: std.Io, name: []const u8, repo_abs: ?[]const u8) Allocator.Error!?[]const u8 {
    const ra = repo_abs orelse return null;
    var d = Dir.cwd().openDir(io, ra, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var it = d.iterate();
    var best: ?[]const u8 = null;
    var best_time: i96 = 0;
    while (it.next(io) catch null) |e| {
        if (!isOwnPackage(name, e.name)) continue;
        const st = d.statFile(io, e.name, .{}) catch continue;
        const ns: i96 = st.mtime.nanoseconds;
        if (best == null or ns > best_time) {
            best = try arena.dupe(u8, e.name);
            best_time = ns;
        }
    }
    return best;
}

fn isOwnPackage(name: []const u8, file: []const u8) bool {
    if (file.len <= name.len + 1 or !std.mem.startsWith(u8, file, name) or file[name.len] != '-') return false;
    if (!std.ascii.isDigit(file[name.len + 1]) or !std.mem.endsWith(u8, file, ".apk")) return false;
    const stem = file[0 .. file.len - ".apk".len];
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return false;
    if (dash <= name.len or stem.len < dash + 3 or stem[dash + 1] != 'r') return false;
    for (stem[dash + 2 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "isOwnPackage: the recipe's main package of any version, not its subpackages" {
    try std.testing.expect(isOwnPackage("dotnet", "dotnet-10.0.114-r1.apk"));
    try std.testing.expect(isOwnPackage("dotnet", "dotnet-10.0.200-r12.apk"));
    try std.testing.expect(!isOwnPackage("dotnet", "dotnet-devel-10.0.114-r1.apk"));
    try std.testing.expect(!isOwnPackage("dotnet", "dotnet-bootstrap-gcc-runtime-15.2.0-r2.apk"));
    try std.testing.expect(!isOwnPackage("dotnet", "dotnet-10.0.114-r1.apk.tmp"));
    try std.testing.expect(!isOwnPackage("dotnet", "dotnet.dkhash"));
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
        // SOURCE_DATE_EPOCH, fixed: a build date or a file time a package embeds (OpenSSL's "built on",
        // Python's .pyc and documentation dates) is the same on every build, so a rebuild comes
        // out identical and the early cutoff (SPEC 4.x) stops there. Not in the script, so it is
        // not part of the script hash.
        .env = &.{ "PATH=/usr/bin:/bin", "HOME=/root", "SOURCE_DATE_EPOCH=1767225600" },
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

/// A build of the same name, version and release as an earlier one used to overwrite its log, so a
/// diagnosis of what the earlier build did (samba r16, whose log the r17 build replaced) was
/// impossible. The earlier `<id>.log` is kept as `<id>.1.log`, `<id>.2.log`, ... (oldest first);
/// `<id>.log` stays the newest, which is the path the messages print.
fn archivePreviousLog(arena: Allocator, io: std.Io, logdir: []const u8, id: []const u8) void {
    const cur = std.fmt.allocPrint(arena, "{s}/{s}.log", .{ logdir, id }) catch return;
    Dir.cwd().access(io, cur, .{}) catch return;
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        const dst = std.fmt.allocPrint(arena, "{s}/{s}.{d}.log", .{ logdir, id, n }) catch return;
        if (Dir.cwd().access(io, dst, .{})) |_| continue else |_| {}
        Dir.cwd().rename(cur, Dir.cwd(), dst, io) catch {};
        return;
    }
}

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
    var uses_npm = false;
    var gem_lists: std.ArrayList([]const u8) = .empty;
    // further sources' Cargo projects: { archive, list, config }
    var extra_cargo: std.ArrayList([3][]const u8) = .empty;
    var pub_lists: std.ArrayList([]const u8) = .empty;
    var hackage_pkgs: ?[]hackagedeps.Pkg = null;
    var py_pkgs: ?[]pydeps.Pkg = null;
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
            // Ruby gems: any unpacked tarball's Gemfile.lock
            if (src == .tarball and src.tarball.unpack and contains(r.options, "gemdeps")) {
                if (gemdeps.fetchGemDeps(arena, io, cache, src.tarball.sha256, &msg)) |_| {
                    try gem_lists.append(arena, try gemdeps.listPath(arena, cache, src.tarball.sha256));
                } else |err| if (!std.mem.eql(u8, msg, gemdeps.no_lockfile)) {
                    out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                    return error.PrepareFailed;
                }
            }
            // Dart: any unpacked tarball's pubspec.lock
            if (src == .tarball and src.tarball.unpack and contains(r.options, "pubdeps")) {
                if (pubdeps.fetchPubDeps(arena, io, cache, src.tarball.sha256, &msg)) |_| {
                    try pub_lists.append(arena, try pubdeps.listPath(arena, cache, src.tarball.sha256));
                } else |err| if (!std.mem.eql(u8, msg, pubdeps.no_lockfile)) {
                    out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                    return error.PrepareFailed;
                }
            }
            // npm lockfiles may be in any unpacked tarball (a web client as a second source)
            if (src == .tarball and src.tarball.unpack and contains(r.options, "npmdeps")) {
                if (npmdeps.fetchNpmDeps(arena, io, cache, src.tarball.sha256, &msg)) |_| {
                    uses_npm = true;
                } else |err| if (!std.mem.eql(u8, msg, npmdeps.no_lockfile)) {
                    out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                    return error.PrepareFailed;
                }
            }
            if (first_tarball != null and src == .tarball and src.tarball.unpack and contains(r.options, "cargodeps") and
                fetch.hasTopCargoLock(arena, io, try fetch.cachePath(arena, cache, src.tarball.sha256)))
            {
                _ = fetch.fetchCargoDeps(arena, io, cache, src.tarball.sha256, "", &.{}, null, &msg) catch |err| {
                    out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                    return error.PrepareFailed;
                };
                try extra_cargo.append(arena, .{
                    try fetch.cachePath(arena, cache, src.tarball.sha256),
                    try fetch.cargoDepsPath(arena, cache, src.tarball.sha256),
                    try std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.config.toml", .{ cache, src.tarball.sha256 }),
                });
            }
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
                    _ = fetch.fetchCargoDeps(arena, io, cache, src.tarball.sha256, try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "patches" }), r.patches, try fetch.recipeCargoLock(arena, r.options, try recipe.dirPath(arena, opts.root, r.name)), &msg) catch |err| {
                        out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                        return error.PrepareFailed;
                    };
                    const rdir = try recipe.dirPath(arena, opts.root, r.name);
                    const key = fetch.cargoDepsKey(arena, io, src.tarball.sha256, try std.fs.path.join(arena, &.{ rdir, "patches" }), r.patches, try fetch.recipeCargoLock(arena, r.options, rdir)) catch return error.PrepareFailed;
                    cargo_list = try fetch.cargoDepsPath(arena, cache, key);
                    cargo_config = try std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.config.toml", .{ cache, key });
                }

                if (contains(r.options, "godeps")) {
                    _ = fetch.fetchGoDeps(arena, io, cache, src.tarball.sha256, try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "patches" }), r.patches, &msg) catch |err| {
                        out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                        return error.PrepareFailed;
                    };
                    uses_go = true;
                }
            }
        }
        if (contains(r.options, "pubdeps")) {
            const pl = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "files", "pubspec.lock" });
            if (Dir.cwd().access(io, pl, .{})) |_| {
                var pmsg: []const u8 = "";
                _ = pubdeps.fetchPubLockFile(arena, io, cache, pl, &pmsg) catch |err| {
                    out("error: {s}: {s}\n", .{ r.name, if (pmsg.len > 0) pmsg else @errorName(err) });
                    return error.PrepareFailed;
                };
                const data = Dir.cwd().readFileAlloc(io, pl, arena, .limited(1 << 24)) catch return error.PrepareFailed;
                try pub_lists.append(arena, try pubdeps.listPath(arena, cache, try pubdeps.lockKey(arena, data)));
            } else |_| {}
        }
        if (contains(r.options, "hackagedeps")) {
            const hl = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "files", hackagedeps.lock_name });
            var hmsg: []const u8 = "";
            _ = hackagedeps.fetchLock(arena, io, cache, hl, &hmsg) catch |err| {
                out("error: {s}: {s}\n", .{ r.name, if (hmsg.len > 0) hmsg else @errorName(err) });
                return error.PrepareFailed;
            };
            const data = Dir.cwd().readFileAlloc(io, hl, arena, .limited(1 << 22)) catch return error.PrepareFailed;
            hackage_pkgs = hackagedeps.parse(arena, data, &hmsg) catch {
                out("error: {s}: {s}\n", .{ r.name, hmsg });
                return error.PrepareFailed;
            };
        }
        if (contains(r.options, "pydeps")) {
            const pl = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "files", pydeps.lock_name });
            var pmsg: []const u8 = "";
            _ = pydeps.fetchLock(arena, io, cache, pl, &pmsg) catch |err| {
                out("error: {s}: {s}\n", .{ r.name, if (pmsg.len > 0) pmsg else @errorName(err) });
                return error.PrepareFailed;
            };
            const data = Dir.cwd().readFileAlloc(io, pl, arena, .limited(1 << 22)) catch return error.PrepareFailed;
            py_pkgs = pydeps.parse(arena, data, &pmsg) catch {
                out("error: {s}: {s}\n", .{ r.name, pmsg });
                return error.PrepareFailed;
            };
        }
        if (contains(r.options, "pubdeps") and pub_lists.items.len == 0) {
            out("error: {s}: {s} (in none of its sources)\n", .{ r.name, pubdeps.no_lockfile });
            return error.PrepareFailed;
        }
        if (contains(r.options, "gemdeps") and gem_lists.items.len == 0) {
            out("error: {s}: {s} (in none of its sources)\n", .{ r.name, gemdeps.no_lockfile });
            return error.PrepareFailed;
        }
        // lockfiles the recipe keeps in its files/ (made from a yarn.lock, ...)
        if (contains(r.options, "npmdeps")) {
            const fdir = try std.fs.path.join(arena, &.{ try recipe.dirPath(arena, opts.root, r.name), "files" });
            for (try npmdeps.recipeLocks(arena, io, fdir)) |lp| {
                var msg: []const u8 = "";
                _ = npmdeps.fetchNpmLockFile(arena, io, cache, lp, &msg) catch |err| {
                    out("error: {s}: {s}\n", .{ r.name, if (msg.len > 0) msg else @errorName(err) });
                    return error.PrepareFailed;
                };
                uses_npm = true;
            }
        }
        if (contains(r.options, "npmdeps") and !uses_npm) {
            out("error: {s}: {s} (in none of its sources)\n", .{ r.name, npmdeps.no_lockfile });
            return error.PrepareFailed;
        }
    }

    // 2. Build root: in <root>/work, or in DKBUILD_FAST_WORK (a faster disk)
    // for recipes that are not heavy (`jobs:N`), while it has 30 GB free.
    const work = try buildWorkDir(arena, io, opts, r);
    // Never build on top of an earlier build's leftovers: they would be packaged and signed with the new files.
    if (!removeBuildDir(arena, io, work)) {
        out("error: cannot remove the old build directory {s}; remove it by hand\n", .{work});
        return error.PrepareFailed;
    }
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
    defer if (!opts.keep_root and !removeBuildDir(arena, io, work)) out("    warning: cannot remove {s}\n", .{work});

    var log: std.ArrayList(u8) = .empty;
    const logdir = try std.fs.path.join(arena, &.{ opts.root, "logs", opts.arch });
    Dir.cwd().createDirPath(io, logdir) catch {};
    const logpath = try std.fmt.allocPrint(arena, "{s}/{s}.log", .{ logdir, id });
    defer {
        archivePreviousLog(arena, io, logdir, id);
        Dir.cwd().writeFile(io, .{ .sub_path = logpath, .data = log.items }) catch {};
    }

    const local_repo = try std.fmt.allocPrint(arena, "{s}/repo/{s}", .{ opts.root, opts.arch });
    const local_abs: ?[]const u8 = absPath(arena, io, local_repo) catch null;
    const keys_dir: ?[]const u8 = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "keys" })) catch null;
    // the repo packages laid in the build root (for `name=@built` depends)
    var root_files: []const []const u8 = &.{};
    {
        // Stage 1: the toolchain and libraries are the image's. The packages
        // this tree built are laid over it from repo/ with `apk extract`, which
        // checks each signature but not dependencies: the image has no package
        // database, so there is nothing for a solver to work with (SPEC.md 7.3).
        const files = try inTreeFiles(arena, io, opts, r, local_abs);
        root_files = files;
        out("    preparing build root ({d} package(s) from repo/ on top of the base image)\n", .{files.len});
        try unpackDeps(arena, io, base_root, sb, files, local_abs, keys_dir, &log, logpath);
    }
    // The networked restore steps (below) run upstream code, so they get a root of their own, made the same way:
    // what they change in it stays out of the build's.
    var restore_layer: ?SbDirs = null;

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
        // one's top directory is $srcdir; the others land next to it), and
        // so are zips; any other file (a .txt, a .whl), and any source with
        // unpack = false or a name, is copied to /build/sources/<name>.
        if (first_tarball != null) {
            var first = true;
            for (r.source) |src| {
                if (src != .tarball) continue;
                const file = try fetch.cachePath(arena, cache, src.tarball.sha256);
                const zip = isZipArchive(src.tarball.url);
                if (!src.tarball.unpack or src.tarball.name != null or (!isTarArchive(src.tarball.url) and !zip)) {
                    const sdir = try std.fs.path.join(arena, &.{ build_rel, "sources" });
                    // An earlier archive may have made `sources`, or a name in it, a link to anywhere.
                    if (Dir.cwd().statFile(io, sdir, .{ .follow_symlinks = false })) |st| {
                        if (st.kind != .directory) {
                            out("error: {s}: a source archive has a 'sources' that is not a directory\n", .{r.name});
                            return error.UnpackFailed;
                        }
                    } else |_| Dir.cwd().createDirPath(io, sdir) catch return error.UnpackFailed;
                    const base = src.tarball.name orelse std.fs.path.basename(src.tarball.url);
                    const ok = runLogged(arena, io, &.{ "cp", "--remove-destination", file, try std.fs.path.join(arena, &.{ sdir, base }) }, &log) catch false;
                    if (!ok) return error.UnpackFailed;
                    first = false;
                    continue;
                }
                // zips with the host's unzip (tar does not read them)
                const ok = if (zip)
                    runLogged(arena, io, &.{ "unzip", "-q", "-o", file, "-d", build_rel }, &log) catch false
                else
                    runLogged(arena, io, &.{ "tar", "-xf", file, "-C", build_rel, "--no-same-owner" }, &log) catch false;
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
        var lay: std.ArrayList(u8) = .empty;
        // The layout script runs in a sandbox of its own (below): the unpacked source is untrusted, full of
        // whatever links and names its archive chose. It sees the cache at /dkcache, read-only.
        var cargo_lock_bind: ?sandbox.Bind = null;
        if (cargo_list) |cl| {
            const text = Dir.cwd().readFileAlloc(io, cl, arena, .limited(1 << 22)) catch return error.UnpackFailed;
            // with `cargolock=<dir>`: the recipe's Cargo.lock, the crates and the
            // config in that project's directory (a subshell keeps the rest at the top)
            const clock = try fetch.recipeCargoLock(arena, r.options, try recipe.dirPath(arena, opts.root, r.name));
            if (clock) |l| {
                cargo_lock_bind = .{ .src = absPath(arena, io, l.file) catch return error.UnpackFailed, .dst = "/dkcargolock", .read_only = true };
                try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "(\ncd '{s}'\ncp /dkcargolock Cargo.lock\n", .{l.dir}));
            }
            try lay.appendSlice(arena, "mkdir -p vendor .cargo\n");
            try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "cp '{s}' .cargo/config.toml\n", .{try inLay(arena, cache, cargo_config.?)}));
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |l| {
                var f = std.mem.tokenizeScalar(u8, l, ' ');
                const n = f.next() orelse continue;
                const k = f.next() orelse continue;
                try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "if [ -d 'vendor/{1s}' ] && [ ! -L 'vendor/{1s}' ] && [ \"$(sed -n 's/^version = \"\\(.*\\)\"$/\\1/p' 'vendor/{1s}/Cargo.toml' | head -n 1)\" != \"$(sed -n 's/^version = \"\\(.*\\)\"$/\\1/p' '{2s}/crates/{0s}/Cargo.toml' | head -n 1)\" ]; then ln -sfn '/dkdeps/crates/{0s}' 'vendor/{1s}-dkdeps'; else rm -rf 'vendor/{1s}'; ln -sfn '/dkdeps/crates/{0s}' 'vendor/{1s}'; fi\n", .{ k, n, "/dkcache" }));
            }
            if (clock != null) try lay.appendSlice(arena, ")\n");
        }
        // further sources' crates, in their own directories (next to this one)
        for (extra_cargo.items) |ec| {
            const text = Dir.cwd().readFileAlloc(io, ec[1], arena, .limited(1 << 22)) catch return error.UnpackFailed;
            try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "(\nd=$(tar -tf '{s}' | head -n1 | sed 's|^\\./||' | cut -d/ -f1)\ncd \"../$d\"\nmkdir -p vendor .cargo\ncp '{s}' .cargo/config.toml\n", .{ try inLay(arena, cache, ec[0]), try inLay(arena, cache, ec[2]) }));
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |l| {
                var f = std.mem.tokenizeScalar(u8, l, ' ');
                const n = f.next() orelse continue;
                const k = f.next() orelse continue;
                try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "if [ -d 'vendor/{1s}' ] && [ ! -L 'vendor/{1s}' ] && [ \"$(sed -n 's/^version = \"\\(.*\\)\"$/\\1/p' 'vendor/{1s}/Cargo.toml' | head -n 1)\" != \"$(sed -n 's/^version = \"\\(.*\\)\"$/\\1/p' '{2s}/crates/{0s}/Cargo.toml' | head -n 1)\" ]; then ln -sfn '/dkdeps/crates/{0s}' 'vendor/{1s}-dkdeps'; else rm -rf 'vendor/{1s}'; ln -sfn '/dkdeps/crates/{0s}' 'vendor/{1s}'; fi\n", .{ k, n, "/dkcache" }));
            }
            try lay.appendSlice(arena, ")\n");
        }
        // Gems: vendor/cache in the source's top directory, linking into the
        // store; `bundle install --local` installs from there.
        if (gem_lists.items.len > 0) try lay.appendSlice(arena, "mkdir -p vendor/cache\n");
        for (gem_lists.items) |gl| {
            const text = Dir.cwd().readFileAlloc(io, gl, arena, .limited(1 << 22)) catch return error.UnpackFailed;
            var gl_lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (gl_lines.next()) |f| {
                if (std.mem.indexOfScalar(u8, f, ' ') != null) {
                    // "<archive> <dir>": a git gem, unpacked as Bundler's cached git gem
                    var parts = std.mem.tokenizeScalar(u8, f, ' ');
                    const arc = parts.next() orelse continue;
                    const gdir = parts.next() orelse continue;
                    // unpacked now, by the layout script
                    try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "mkdir -p 'vendor/cache/{1s}' && tar -xzf '{2s}/{0s}' -C 'vendor/cache/{1s}' --strip-components=1 && touch 'vendor/cache/{1s}/.bundlecache'\n", .{ arc, gdir, "/dkcache/gems" }));
                } else try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "ln -sfn '/dkdeps/gems/{s}' 'vendor/cache/{s}'\n", .{ f, f }));
            }
        }
        // Dart packages: unpacked into .dkpub as pub's own cache lays them
        // out (hosted/pub.dev/<name>-<version>, and the archive's sha256 in
        // hosted-hashes)
        for (pub_lists.items) |pl| {
            const text = Dir.cwd().readFileAlloc(io, pl, arena, .limited(1 << 22)) catch return error.UnpackFailed;
            try lay.appendSlice(arena, "mkdir -p .dkpub/hosted/pub.dev .dkpub/hosted-hashes/pub.dev\n");
            var pl_lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (pl_lines.next()) |l| {
                var f = std.mem.tokenizeScalar(u8, l, ' ');
                const n = f.next() orelse continue;
                const v = f.next() orelse continue;
                const h = f.next() orelse continue;
                try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "mkdir -p '.dkpub/hosted/pub.dev/{0s}-{1s}' && tar -xzf '{3s}/{0s}-{1s}.tar.gz' -C '.dkpub/hosted/pub.dev/{0s}-{1s}' && printf '%s' '{2s}' > '.dkpub/hosted-hashes/pub.dev/{0s}-{1s}.sha256'\n", .{ n, v, h, "/dkcache/pub" }));
            }
        }
        // Haskell packages: .dkhackage, a cabal file+noindex repository of
        // links into the store
        if (hackage_pkgs) |hp| try lay.appendSlice(arena, try hackagedeps.layScript(arena, hp));
        // Python packages: .dkpython, links into the store
        if (py_pkgs) |pp| try lay.appendSlice(arena, try pydeps.layScript(arena, pp));
        if (zig_list) |zl| {
            const text = Dir.cwd().readFileAlloc(io, zl, arena, .limited(1 << 22)) catch return error.UnpackFailed;
            try lay.appendSlice(arena, "mkdir -p zig-pkg\n");
            var lines = std.mem.tokenizeScalar(u8, text, '\n');
            while (lines.next()) |n| try lay.appendSlice(arena, try std.fmt.allocPrint(arena, "ln -sfn '/dkdeps/zig/{s}' 'zig-pkg/{s}'\n", .{ n, n }));
        }
        if (lay.items.len > 0) {
            // The script goes through a file: a large crate list (cargo-c has 410)
            // makes it longer than one argument may be (128 KiB).
            const dk_rel = try std.fs.path.join(arena, &.{ root_rel, "dkbuild" });
            Dir.cwd().createDirPath(io, dk_rel) catch return error.UnpackFailed;
            const lay_file = try std.fs.path.join(arena, &.{ dk_rel, "lay.sh" });
            Dir.cwd().writeFile(io, .{ .sub_path = lay_file, .data = try std.fmt.allocPrint(arena, "cd '{s}'\n{s}", .{ srcdir, lay.items }) }) catch return error.UnpackFailed;
            var binds: std.ArrayList(sandbox.Bind) = .empty;
            try binds.appendSlice(arena, &.{
                .{ .src = try std.fs.path.join(arena, &.{ root_abs, "build" }), .dst = "/build" },
                .{ .src = try std.fs.path.join(arena, &.{ root_abs, "dkbuild" }), .dst = "/dkbuild", .read_only = true },
            });
            // each of the cache's directories by itself, so that one that is a link to another disk works
            for ([_][]const u8{ "sources", "cargodeps", "crates", "gems", "pub" }) |sub| {
                const abs = absPath(arena, io, try std.fs.path.join(arena, &.{ cache, sub })) catch continue;
                try binds.append(arena, .{ .src = abs, .dst = try std.fmt.allocPrint(arena, "/dkcache/{s}", .{sub}), .read_only = true });
            }
            if (cargo_lock_bind) |b| try binds.append(arena, b);
            // a layer of its own over the base image: no network, and nothing of it reaches the build's
            const ok = runTool(arena, io, base_root, try sbDirs(arena, io, work, "lay"), binds.items, &.{ "/usr/bin/sh", "-e", "/dkbuild/lay.sh" }, &log) catch false;
            if (!ok) {
                out("error: cannot lay out the vendored dependencies of {s}\n", .{r.name});
                return error.UnpackFailed;
            }
        }
    }

    // 3b. Gradle (gradledeps): the first build of a source resolves its
    // dependencies once, in this build root with the network, into the shared
    // Maven-layout store (SPEC.md 7.4); everything after runs offline.
    const uses_gradle = contains(r.options, "gradledeps") and first_tarball != null;
    if (uses_gradle) {
        // the list's name: what decides what the restore downloads
        const first_sha = try restoreKey(arena, io, opts, r, cache, "gradledeps", std.fs.path.basename(first_tarball.?));
        const maven_rel = try std.fs.path.join(arena, &.{ cache, "maven" });
        const glists_rel = try std.fs.path.join(arena, &.{ cache, "gradledeps" });
        Dir.cwd().createDirPath(io, maven_rel) catch return error.PrepareFailed;
        Dir.cwd().createDirPath(io, glists_rel) catch return error.PrepareFailed;
        const dk = try std.fs.path.join(arena, &.{ root_rel, "dkbuild" });
        for ([_][2][]const u8{ .{ "gradle-resolve.gradle", gradle_resolve }, .{ "gradle-store.sh", gradle_store_sh }, .{ "gradle-offline.gradle", gradle_offline } }) |f|
            Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dk, f[0] }), .data = f[1] }) catch return error.PrepareFailed;
        const glist = try std.fmt.allocPrint(arena, "{s}/{s}.list", .{ glists_rel, first_sha });
        if (Dir.cwd().access(io, glist, .{})) |_| {} else |_| {
            out("    resolving Gradle dependencies (network, once for this source)\n", .{});
            // The recipe's environment too (ghidra's JAVA_HOME: Gradle needs a JDK).
            const genv = try std.fmt.allocPrint(arena, "export name='{s}' version='{s}' srcdir='{s}' jobs={d}\n{s}\n", .{ r.name, r.version, srcdir, opts.jobs, r.environment orelse "" });
            var gpatches: std.ArrayList(u8) = .empty;
            for (r.patches) |pt| try gpatches.appendSlice(arena, try std.fmt.allocPrint(arena, "patch -Np1 -s -i '/dkbuild/patches/{s}'\n", .{pt}));
            const sh = try std.fmt.allocPrint(arena,
                \\set -e
                \\{s}
                \\z=$(ls /build/sources/gradle-*-bin.zip | head -n1)
                \\mkdir -p /tmp/gradle-dist && unzip -q "$z" -d /tmp/gradle-dist
                \\g=$(ls -d /tmp/gradle-dist/gradle-*)/bin/gradle
                \\# Gradle's native helpers (file events, ...) are glibc builds: off
                \\mkdir -p /tmp/ghome && printf 'org.gradle.native=false\norg.gradle.vfs.watch=false\n' > /tmp/ghome/gradle.properties
                \\# the forked daemon takes org.gradle.native from its JVM's system properties
                \\export JAVA_TOOL_OPTIONS=-Dorg.gradle.native=false
                \\# on a copy with the recipe's patches applied (the build applies them to
                \\# its own tree later): what is resolved is what the patched build uses
                \\rm -rf /tmp/gradle-src && cp -a '{s}' /tmp/gradle-src && cd /tmp/gradle-src
                \\{s}
                \\"$g" --no-daemon --continue -g /tmp/ghome -I /dkbuild/gradle-resolve.gradle dkbuildResolveAll
                \\sh /dkbuild/gradle-store.sh /tmp/ghome /dkstore/maven /dkstore/gradledeps/{s}.list
            , .{ genv, srcdir, gpatches.items, first_sha });
            if (restore_layer == null) {
                restore_layer = try sbDirs(arena, io, work, "restore");
                try unpackDeps(arena, io, base_root, restore_layer.?, root_files, local_abs, keys_dir, &log, logpath);
            }
            const rsb = restore_layer.?;
            const stage = try restoreStage(arena, io, work, "gradle");
            const ok = sandbox.run(arena, io, .{
                .lower = base_root,
                .upper = rsb.upper,
                .work = rsb.work,
                .merged = rsb.merged,
                .net = true,
                .binds = &.{
                    .{ .src = try std.fs.path.join(arena, &.{ root_abs, "build" }), .dst = "/build" },
                    // read-only: the host writes more files here afterwards, and would follow a link left there
                    .{ .src = try std.fs.path.join(arena, &.{ root_abs, "dkbuild" }), .dst = "/dkbuild", .read_only = true },
                    // empty ones: the store and the other lists are out of its reach
                    .{ .src = stage.store, .dst = "/dkstore/maven" },
                    .{ .src = stage.lists, .dst = "/dkstore/gradledeps" },
                    .{ .src = "/etc/resolv.conf", .dst = "/etc/resolv.conf", .read_only = true },
                },
                .env = &.{ "PATH=/usr/bin:/bin", "HOME=/tmp" },
                .argv = &.{ "/usr/bin/sh", "-c", sh },
            }, &log) catch false;
            if (!ok) {
                out("error: {s}: resolving its Gradle dependencies failed; log: {s}\n", .{ r.name, logpath });
                return error.PrepareFailed;
            }
            mergeRestored(arena, io, .maven, stage, maven_rel, glist, &log) catch |err| {
                out("error: {s}: cannot add the downloaded dependencies to the store: {s}\n", .{ r.name, @errorName(err) });
                return error.PrepareFailed;
            };
        }
    }

    // 3c. NuGet (nugetdeps): like Gradle, the first build of a source runs the
    // recipe's `restore` step once with the network, in this build root (so
    // with this tree's dotnet and runtime ID), and keeps the packages in the
    // shared store; every build restores offline from it.
    const uses_nuget = contains(r.options, "nugetdeps") and first_tarball != null;
    if (uses_nuget) {
        // the list's name: what decides what the restore downloads
        const first_sha = try restoreKey(arena, io, opts, r, cache, "nugetdeps", std.fs.path.basename(first_tarball.?));
        const store_rel = try std.fs.path.join(arena, &.{ cache, "nuget" });
        const lists_rel = try std.fs.path.join(arena, &.{ cache, "nugetdeps" });
        Dir.cwd().createDirPath(io, store_rel) catch return error.PrepareFailed;
        Dir.cwd().createDirPath(io, lists_rel) catch return error.PrepareFailed;
        const dk = try std.fs.path.join(arena, &.{ root_rel, "dkbuild" });
        Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dk, "nuget-store.sh" }), .data = nuget_store_sh }) catch return error.PrepareFailed;
        const nlist = try std.fmt.allocPrint(arena, "{s}/{s}.list", .{ lists_rel, first_sha });
        if (Dir.cwd().access(io, nlist, .{})) |_| {} else |_| {
            out("    restoring NuGet packages (network, once for this source)\n", .{});
            const sh = try std.fmt.allocPrint(arena,
                \\set -e
                \\export NUGET_PACKAGES=/tmp/nuget-restore HOME=/tmp DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
                \\export srcdir='{s}'
                \\cd "$srcdir"
                \\{s}
                \\sh /dkbuild/nuget-store.sh /tmp/nuget-restore /dkstore/nuget /dkstore/nugetdeps/{s}.list
            , .{ srcdir, r.restore.?, first_sha });
            if (restore_layer == null) {
                restore_layer = try sbDirs(arena, io, work, "restore");
                try unpackDeps(arena, io, base_root, restore_layer.?, root_files, local_abs, keys_dir, &log, logpath);
            }
            const rsb = restore_layer.?;
            const stage = try restoreStage(arena, io, work, "nuget");
            const ok = sandbox.run(arena, io, .{
                .lower = base_root,
                .upper = rsb.upper,
                .work = rsb.work,
                .merged = rsb.merged,
                .net = true,
                .binds = &.{
                    .{ .src = try std.fs.path.join(arena, &.{ root_abs, "build" }), .dst = "/build" },
                    // read-only: the host writes more files here afterwards, and would follow a link left there
                    .{ .src = try std.fs.path.join(arena, &.{ root_abs, "dkbuild" }), .dst = "/dkbuild", .read_only = true },
                    // empty ones: the store and the other lists are out of its reach
                    .{ .src = stage.store, .dst = "/dkstore/nuget" },
                    .{ .src = stage.lists, .dst = "/dkstore/nugetdeps" },
                    .{ .src = "/etc/resolv.conf", .dst = "/etc/resolv.conf", .read_only = true },
                },
                .env = &.{ "PATH=/usr/bin:/bin", "HOME=/tmp" },
                .argv = &.{ "/usr/bin/sh", "-c", sh },
            }, &log) catch false;
            if (!ok) {
                out("error: {s}: restoring its NuGet packages failed; log: {s}\n", .{ r.name, logpath });
                return error.PrepareFailed;
            }
            mergeRestored(arena, io, .nuget, stage, store_rel, nlist, &log) catch |err| {
                out("error: {s}: cannot add the downloaded dependencies to the store: {s}\n", .{ r.name, @errorName(err) });
                return error.PrepareFailed;
            };
        }
    }

    // 3d. Maven (mavendeps): like Gradle and NuGet, the first build of a source runs the recipe's `restore` step once with the network, in this
    // build root, with the recipe's own Maven and a private local repository; what it downloaded goes into the shared Maven-layout store.
    const uses_maven = contains(r.options, "mavendeps") and first_tarball != null;
    if (uses_maven) {
        // the list's name: what decides what the restore downloads
        const first_sha = try restoreKey(arena, io, opts, r, cache, "mavendeps", std.fs.path.basename(first_tarball.?));
        const maven_rel = try std.fs.path.join(arena, &.{ cache, "maven" });
        const mlists_rel = try std.fs.path.join(arena, &.{ cache, "mavendeps" });
        Dir.cwd().createDirPath(io, maven_rel) catch return error.PrepareFailed;
        Dir.cwd().createDirPath(io, mlists_rel) catch return error.PrepareFailed;
        const dk = try std.fs.path.join(arena, &.{ root_rel, "dkbuild" });
        Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dk, "maven-store.sh" }), .data = maven_store_sh }) catch return error.PrepareFailed;
        const mlist = try std.fmt.allocPrint(arena, "{s}/{s}.list", .{ mlists_rel, first_sha });
        if (Dir.cwd().access(io, mlist, .{})) |_| {} else |_| {
            out("    restoring Maven dependencies (network, once for this source)\n", .{});
            const menv = try std.fmt.allocPrint(arena, "export name='{s}' version='{s}' srcdir='{s}' jobs={d}\n{s}\n", .{ r.name, r.version, srcdir, opts.jobs, r.environment orelse "" });
            var mpatches: std.ArrayList(u8) = .empty;
            for (r.patches) |pt| try mpatches.appendSlice(arena, try std.fmt.allocPrint(arena, "patch -Np1 -s -i '/dkbuild/patches/{s}'\n", .{pt}));
            const sh = try std.fmt.allocPrint(arena,
                \\set -e
                \\{s}
                \\export HOME=/tmp
                \\mkdir -p /tmp/maven-dist /tmp/dkbin
                \\tar -xzf "$(ls /build/sources/apache-maven-*-bin.tar.gz | head -n1)" -C /tmp/maven-dist
                \\printf '%s\n' '<settings><localRepository>/tmp/m2-restore</localRepository></settings>' > /tmp/dk-restore-settings.xml
                \\printf '#!/bin/sh\nexec %s/bin/mvn -B -s /tmp/dk-restore-settings.xml "$@"\n' "$(ls -d /tmp/maven-dist/apache-maven-*)" > /tmp/dkbin/mvn
                \\chmod 755 /tmp/dkbin/mvn
                \\export PATH="/tmp/dkbin:$PATH"
                \\# on a copy with the recipe's patches applied (the build applies them to its own tree later)
                \\rm -rf /tmp/maven-src && cp -a '{s}' /tmp/maven-src && cd /tmp/maven-src
                \\{s}
                \\{s}
                \\sh /dkbuild/maven-store.sh /tmp/m2-restore /dkstore/maven /dkstore/mavendeps/{s}.list
            , .{ menv, srcdir, mpatches.items, r.restore.?, first_sha });
            if (restore_layer == null) {
                restore_layer = try sbDirs(arena, io, work, "restore");
                try unpackDeps(arena, io, base_root, restore_layer.?, root_files, local_abs, keys_dir, &log, logpath);
            }
            const rsb = restore_layer.?;
            const stage = try restoreStage(arena, io, work, "maven");
            const ok = sandbox.run(arena, io, .{
                .lower = base_root,
                .upper = rsb.upper,
                .work = rsb.work,
                .merged = rsb.merged,
                .net = true,
                .binds = &.{
                    .{ .src = try std.fs.path.join(arena, &.{ root_abs, "build" }), .dst = "/build" },
                    // read-only: the host writes more files here afterwards, and would follow a link left there
                    .{ .src = try std.fs.path.join(arena, &.{ root_abs, "dkbuild" }), .dst = "/dkbuild", .read_only = true },
                    // empty ones: the store and the other lists are out of its reach
                    .{ .src = stage.store, .dst = "/dkstore/maven" },
                    .{ .src = stage.lists, .dst = "/dkstore/mavendeps" },
                    .{ .src = "/etc/resolv.conf", .dst = "/etc/resolv.conf", .read_only = true },
                },
                .env = &.{ "PATH=/usr/bin:/bin", "HOME=/tmp" },
                .argv = &.{ "/usr/bin/sh", "-c", sh },
            }, &log) catch false;
            if (!ok) {
                out("error: {s}: restoring its Maven dependencies failed; log: {s}\n", .{ r.name, logpath });
                return error.PrepareFailed;
            }
            mergeRestored(arena, io, .maven, stage, maven_rel, mlist, &log) catch |err| {
                out("error: {s}: cannot add the downloaded dependencies to the store: {s}\n", .{ r.name, @errorName(err) });
                return error.PrepareFailed;
            };
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
    if (contains(r.options, "npmdeps")) {
        Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ root_rel, "dkbuild", "npm-offline.js" }), .data = npm_offline_js }) catch return error.PrepareFailed;
        Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ root_rel, "dkbuild", "pnpm-registry.js" }), .data = pnpm_registry_js }) catch return error.PrepareFailed;
    }

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
            .{ .use = cargo_list != null or extra_cargo.items.len > 0, .sub = "crates", .dst = "/dkdeps/crates" },
            .{ .use = zig_list != null, .sub = "zigpkg", .dst = "/dkdeps/zig" },
            .{ .use = uses_go, .sub = "gomod", .dst = "/dkdeps/go" },
            .{ .use = uses_npm, .sub = "npm", .dst = "/dkdeps/npm" },
            .{ .use = uses_gradle or uses_maven, .sub = "maven", .dst = "/dkdeps/maven" },
            .{ .use = uses_nuget, .sub = "nuget", .dst = "/dkdeps/nuget" },
            .{ .use = gem_lists.items.len > 0, .sub = "gems", .dst = "/dkdeps/gems" },
            .{ .use = hackage_pkgs != null, .sub = "hackage", .dst = "/dkdeps/hackage" },
            .{ .use = py_pkgs != null, .sub = "python", .dst = "/dkdeps/python" },
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
        for (problems.items) |p| {
            out("error: {s}: {s}; log: {s}\n", .{ r.name, p, logpath });
            // in the build's log too, where the rest of its story is
            try log.appendSlice(arena, try std.fmt.allocPrint(arena, "\n==> policy: {s}\n", .{p}));
        }
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
    var produced = inputs.outputHash(arena, io, parts.items) catch |err| {
        out("error: {s}: hashing what it produced failed: {s}\n", .{ r.name, @errorName(err) });
        return error.BuildFailed;
    };
    // The versions that `=@built` depends resolve to are in the packages' metadata, not their files: a build with
    // the same files and another pin is not the same, and must be published.
    {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        var pinned = false;
        for (r.subpackages) |sp| for (sp.depends) |dep| {
            if (!std.mem.endsWith(u8, dep, "=@built")) continue;
            pinned = true;
            h.update(try builtDep(arena, dep, root_files));
            h.update("\n");
        };
        if (pinned) { // other recipes' hashes stay as they were
            h.update(&produced.output);
            produced.output = std.fmt.bytesToHex(h.finalResult(), .lower);
        }
    }
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
        var main = try withScan(arena, io, destdir_abs, r.rundeps, r.noscan);
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
        for (sp_depends) |dep| try declared.append(arena, try builtDep(arena, dep, root_files));
        var sub = try withScan(arena, io, try std.fs.path.join(arena, &.{ subs_abs, m.name }), declared.items, r.noscan);
        sub.name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ r.name, m.name });
        sub.summary = summary;
        sub.install_if = sp_install_if;
        try pkg_list.append(arena, sub);
        out("    {s}-{s}: {d} files\n", .{ r.name, m.name, m.files });
    }
    try siblingPrivate(arena, pkg_list.items, r.version, r.release);
    // Packaging and signing get a layer of their own over the base image: the build was root over `sb`, and an
    // apk, loader or library it replaced there would run with the signing key.
    try publish(arena, io, r, opts, pub_id, base_root, try sbDirs(arena, io, work, "sign"), pkg_list.items, &log);
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
    /// Private libraries it ships (scan.Result.private).
    private: []const []const u8 = &.{},
};

/// A package that needs a private library a sibling package of the same
/// recipe ships (libpulse-libs needs /usr/lib/pulseaudio/libpulsecommon, left
/// in libpulse by the split) gets an exact dependency on that sibling instead
/// of a `so:` name nothing provides.
fn siblingPrivate(arena: Allocator, pkgs: []Pkg, version: []const u8, release: u32) Allocator.Error!void {
    for (pkgs, 0..) |*pk, i| {
        var deps: std.ArrayList([]const u8) = .empty;
        for (pk.depends) |d| {
            const owner = for (pkgs, 0..) |other, j| {
                if (j != i and contains(other.private, d)) break other.name;
            } else null;
            if (owner) |o| {
                const dep = try std.fmt.allocPrint(arena, "{s}={s}-r{d}", .{ o, version, release });
                if (!contains(deps.items, dep)) try deps.append(arena, dep);
            } else try deps.append(arena, d);
        }
        pk.depends = deps.items;
    }
}

/// Declared dependencies plus what the scan found, without duplicates.
fn withScan(arena: Allocator, io: std.Io, files: []const u8, declared: []const []const u8, noscan: []const []const u8) BuildError!Pkg {
    const res = scan.scanTreeExcept(arena, io, files, noscan) catch |err| {
        out("error: scanning {s}: {s}\n", .{ files, @errorName(err) });
        return error.BuildFailed;
    };
    var deps: std.ArrayList([]const u8) = .empty;
    try deps.appendSlice(arena, declared);
    for (res.depends) |d| if (!contains(deps.items, d)) try deps.append(arena, d);
    return .{ .name = "", .summary = "", .files = files, .depends = deps.items, .provides = res.provides, .private = res.private };
}

/// Lays the packages from repo/ a build needs over the base image in the layer `sb`.
fn unpackDeps(arena: Allocator, io: std.Io, base_root: []const u8, sb: SbDirs, files: []const []const u8, local_abs: ?[]const u8, keys_dir: ?[]const u8, log: *std.ArrayList(u8), logpath: []const u8) BuildError!void {
    if (files.len == 0) return;
    var binds: std.ArrayList(sandbox.Bind) = .empty;
    try binds.append(arena, .{ .src = local_abs.?, .dst = "/dkrepo", .read_only = true });
    if (keys_dir) |kd| try binds.append(arena, .{ .src = kd, .dst = "/dkkeys", .read_only = true });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "/usr/bin/apk", "--force-overwrite", "--keys-dir", "/dkkeys", "extract", "--destination", "/" });
    for (files) |f| try argv.append(arena, try std.fmt.allocPrint(arena, "/dkrepo/{s}", .{f}));
    const ok = runTool(arena, io, base_root, sb, binds.items, argv.items, log) catch false;
    if (!ok) {
        out("error: unpacking packages from repo/ failed; see {s}\n", .{logpath});
        return error.PrepareFailed;
    }
}

/// `sb` must be a layer that no recipe code has written to: apk runs in it with the private key.
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
    // repo/<arch> may be a symlink to another disk (a fast one for the packages): createDirPath does not follow a symlink it finds in the
    // last component and reports NotDir, so an existing directory is opened first.
    if (Dir.cwd().openDir(io, repo_rel, .{})) |existing| {
        existing.close(io);
    } else |_| {
        Dir.cwd().createDirPath(io, repo_rel) catch return error.PrepareFailed;
    }
    const repo_abs = absPath(arena, io, repo_rel) catch return error.PrepareFailed;

    // Mount points live under /tmp (a tmpfs) so the rootfs stays untouched.
    const out_bind = sandbox.Bind{ .src = repo_abs, .dst = "/tmp/out" };

    // mkpkg, once per package, all under .part names: they reach repo/ together, or (when one fails) not at all
    var staged: std.ArrayList([]const u8) = .empty; // the final names
    errdefer for (staged.items) |f| Dir.cwd().deleteFile(io, std.fmt.allocPrint(arena, "{s}/{s}.part", .{ repo_rel, f }) catch continue) catch {};
    for (pkgs) |pk| {
        var argv: std.ArrayList([]const u8) = .empty;
        const binds = [_]sandbox.Bind{ out_bind, .{ .src = pk.files, .dst = "/tmp/files" }, .{ .src = key_abs, .dst = "/tmp/key", .read_only = true } };
        // zstd level 19: about half the size of apk's default deflate (python: 57 MB to 27 MB), and
        // it unpacks faster; every apk 3 here (build roots, installer, DKRescue's) links libzstd
        try argv.appendSlice(arena, &.{ "/usr/bin/apk", "mkpkg", "--compression", "zstd:19", "--sign-key", "/tmp/key" });
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
        if (std.mem.eql(u8, pk.name, r.name) and r.replaces.len > 0)
            try argv.appendSlice(arena, &.{ "--info", try std.fmt.allocPrint(arena, "replaces:{s}", .{try std.mem.join(arena, " ", r.replaces)}) });
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
            // the metadata it was given, for the log (an invalid depends or version is the usual cause)
            try log.appendSlice(arena, "\n==> apk mkpkg was run as:");
            for (argv.items) |a| {
                try log.append(arena, ' ');
                try log.appendSlice(arena, a);
            }
            try log.append(arena, '\n');
            out("error: apk mkpkg failed for {s}\n", .{pk.name});
            return error.BuildFailed;
        }
        try staged.append(arena, file);
    }
    // The record goes first: were this interrupted between the renames, the next run must build again rather
    // than call a half-replaced set up to date.
    Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}/{s}.dkhash", .{ repo_rel, r.name })) catch {};
    for (staged.items) |file| {
        const part = try std.fmt.allocPrint(arena, "{s}/{s}.part", .{ repo_rel, file });
        Dir.cwd().rename(part, Dir.cwd(), try std.fmt.allocPrint(arena, "{s}/{s}", .{ repo_rel, file }), io) catch {
            out("error: cannot move {s} into place\n", .{part});
            return error.BuildFailed;
        };
    }
    // At a version built before (--force), a subpackage that is no longer made must not stay beside the new ones.
    const ver_now = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
    var existing = Dir.cwd().openDir(io, repo_rel, .{ .iterate = true }) catch return error.PrepareFailed;
    defer existing.close(io);
    var gone: std.ArrayList([]const u8) = .empty;
    var files_in_repo = existing.iterate();
    const tail = try std.fmt.allocPrint(arena, "-{s}.apk", .{ver_now});
    while (files_in_repo.next(io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, tail) or contains(staged.items, e.name)) continue;
        const pkg = e.name[0 .. e.name.len - tail.len];
        // one of this recipe's subpackage names, and not another recipe's own name (base-devel beside base's -devel)
        if (!std.mem.startsWith(u8, pkg, r.name) or pkg.len <= r.name.len or pkg[r.name.len] != '-') continue;
        if (opts.tree) |t| if (t.find(pkg) != null) continue;
        if (opts.tree) |t| if (t.provider(pkg)) |other| if (!std.mem.eql(u8, t.recipes[other].name, r.name)) continue;
        try gone.append(arena, try arena.dupe(u8, e.name));
    }
    for (gone.items) |f| {
        out("    removing {s}: this build no longer makes it\n", .{f});
        existing.deleteFile(io, f) catch {};
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
        .{ .option = "gemdeps", .dir = "gemdeps", .store = "gems", .field = 0 },
    };
    var removed: usize = 0;
    for (kinds) |k| {
        // The source tarballs of the recipes that use this kind.
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (t.recipes) |r| {
            if (!contains(r.options, k.option)) continue;
            // every tarball: npm lockfiles can be in any of them (others keep
            // lists only for their first, and an unused name keeps nothing)
            for (r.source) |src| if (src == .tarball) {
                try wanted.put(arena, src.tarball.sha256, {});
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
                // without this list its store entries would count as unused: stop, having removed none
                const text = d.readFileAlloc(io, e.name, arena, .limited(1 << 22)) catch |err| {
                    out("error: cannot read {s}/{s}: {s}; nothing removed from {s}\n", .{ k.dir, e.name, @errorName(err), k.store orelse k.dir });
                    return error.PrepareFailed;
                };
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
    // cargo's own copies in its download cache: the extracted crate sources and
    // the git checkouts, a few hundred thousand small files that cargo makes
    // again from the .crate archives and git/db when a vendor needs them. The
    // builds read cache/crates, never these. (Safe here: prune must not run
    // while a fetch does.)
    for ([_][]const u8{ "cargo-home/registry/src", "cargo-home/git/checkouts" }) |rel| {
        const path = try std.fs.path.join(arena, &.{ cache, rel });
        var cd = Dir.cwd().openDir(io, path, .{}) catch continue;
        cd.close(io);
        out("{s} {s}\n", .{ if (dry_run) "would remove" else "removing", rel });
        removed += 1;
        if (!dry_run) Dir.cwd().deleteTree(io, path) catch {};
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
    if (dry_run) {
        out("{d} stale package(s) (dry run: nothing removed)\n", .{stale.items.len});
        return;
    }
    // Always rebuilt on a real run, even with nothing stale: a run killed after
    // removing packages and before the index was written would otherwise leave
    // an index that lists files which are gone.
    const base_root = absPath(arena, io, try std.fs.path.join(arena, &.{ opts.root, "rootfs", "dkrescue" })) catch return error.PrepareFailed;
    const work = try std.fs.path.join(arena, &.{ opts.root, "work", "prune" });
    if (!removeBuildDir(arena, io, work)) {
        out("error: cannot remove the old directory {s}; remove it by hand\n", .{work});
        return error.PrepareFailed;
    }
    defer _ = removeBuildDir(arena, io, work);
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
        .source = &.{}, .setup = "echo the-setup", .build = "%make", .check = "echo the-check", .install = "%make_install",
    };
    var bad: []const u8 = "";
    const s = try script(a, r, .{ .target = p, .host = p }, "/build/t-1", .{ .root = ".", .jobs = 4 }, &bad);
    try std.testing.expect(std.mem.indexOf(u8, s, "export jobs=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "--target=x86_64-fenriros-linux-musl") != null);
    const b = std.mem.indexOf(u8, s, "==> build").?;
    const i = std.mem.indexOf(u8, s, "==> install").?;
    const su = std.mem.indexOf(u8, s, "==> setup").?;
    const c = std.mem.indexOf(u8, s, "==> check").?;
    try std.testing.expect(su < b and b < c and c < i);
    try std.testing.expect(std.mem.indexOf(u8, s, "DESTDIR=$pkgdir install") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "==> patch") == null);
}

test "the script hash does not depend on --no-check" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const r: recipe.Recipe = .{ .name = "t", .version = "1", .release = 1, .summary = "s", .license = "MIT", .source = &.{}, .install = "x", .check = "make check" };
    // the tree this test is run from has the profiles
    const with = try scriptHash(a, std.testing.io, r, .{ .root = ".", .jobs = 4 });
    const without = try scriptHash(a, std.testing.io, r, .{ .root = ".", .jobs = 4, .no_check = true });
    try std.testing.expectEqualStrings(&with, &without);
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
