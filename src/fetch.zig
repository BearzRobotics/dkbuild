//! Source fetching (SPEC.md 5.3, 7 step 1).
//!
//! Tarballs are downloaded once into `<cache>/sources/<sha256>` and the
//! checksum is verified before the file gets that name. `git|` sources are
//! not handled yet. A `snapshot:<kind> <args>` URL is made, not downloaded: a
//! script (snapshot-<kind>.sh) builds a reproducible tarball on the host from
//! pinned upstream checkouts, and it is checked like a download.

const std = @import("std");
const recipe = @import("recipe.zig");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Status = enum { cached, downloaded };

pub const Error = error{ BadChecksum, DownloadFailed, Unsupported, InvalidChecksum } || Allocator.Error || std.Io.File.OpenError || std.Io.Dir.RenameError;

/// Lowercase hex SHA-256 of the file at `path` (relative to the cwd).
pub fn hashFile(io: std.Io, path: []const u8) ![64]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var rdr = file.reader(io, &buf);
    var h = Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try rdr.interface.readSliceShort(&chunk);
        if (n == 0) break;
        h.update(chunk[0..n]);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

pub fn validSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

/// Whether a URL taken from a lock file, which upstream wrote, may be given to curl: http(s), and only visible
/// ASCII without quotes or backslashes, so it cannot end its quoted value in a curl config and add options.
pub fn safeUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return false;
    for (url) |c| if (c <= ' ' or c >= 0x7f or c == '"' or c == '\\') return false;
    return true;
}

/// Whether a package name or version from a lock file may be part of a file name in a store (and of a URL):
/// no '/', no quotes, not hidden and not read as an option.
pub fn safeName(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.' or s[0] == '-') return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '+')) return false;
    return true;
}

/// Adds one download to a curl config (`curl -K`). Every list made from a lock file goes through here, and is
/// run with `curl_list_args`. Plain http is asked for over https.
pub fn curlEntry(arena: Allocator, cfg: *std.ArrayList(u8), url: []const u8, output: []const u8) !void {
    if (!safeUrl(url)) return error.UnsafeUrl;
    const rest = url[(std.mem.indexOf(u8, url, "://").?)..];
    try cfg.appendSlice(arena, try std.fmt.allocPrint(arena, "url = \"https{s}\"\noutput = \"{s}\"\n", .{ rest, output }));
}

/// The curl command for such a config (its path follows): https only, redirects too, and no globbing, so
/// braces and brackets in a URL are themselves.
pub const curl_list_args = [_][]const u8{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "3", "--globoff", "--proto", "=https", "--proto-redir", "=https", "--parallel", "--parallel-max", "12", "-K" };

test "safeUrl, safeName and curlEntry" {
    try std.testing.expect(safeUrl("https://registry.npmjs.org/@a/b/-/b-1.0.0+x.tgz?q=1&r=%20"));
    try std.testing.expect(!safeUrl("https://e.org/a\"\noutput = \"x"));
    try std.testing.expect(!safeUrl("https://e.org/a b"));
    try std.testing.expect(!safeUrl("https://e.org/a\\b"));
    try std.testing.expect(!safeUrl("file:///etc/passwd"));
    try std.testing.expect(safeName("rake") and safeName("13.0.6") and safeName("a_b-c.d+e"));
    for ([_][]const u8{ "", ".hidden", "-o", "a/b", "../x", "a'b", "a b", "a#b" }) |bad| try std.testing.expect(!safeName(bad));
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var cfg: std.ArrayList(u8) = .empty;
    try curlEntry(st.allocator(), &cfg, "http://e.org/x.tgz", "/tmp/dl-0");
    try std.testing.expectEqualStrings("url = \"https://e.org/x.tgz\"\noutput = \"/tmp/dl-0\"\n", cfg.items);
}

/// Locks held against other dkbuild processes while one thing is fetched (a `dkbuild fetch` beside a `world` is
/// an ordinary use). Without them two fetches of the same thing shared work directories and part files: one could
/// delete the other's tree, or rewrite a download the other had just checked.
pub const Held = struct {
    prune: std.Io.File,
    own: std.Io.File,
    pub fn release(h: Held, io: std.Io) void {
        h.own.close(io);
        h.prune.close(io);
    }
};

/// Waits for `what` (a kind and what is fetched) to be free in `cache`. Fetches share cache/locks/prune.lock, which
/// `prune` takes alone.
pub fn keyLock(arena: Allocator, io: std.Io, cache: []const u8, kind: []const u8, what: []const u8) !Held {
    const dir = try std.fmt.allocPrint(arena, "{s}/locks", .{cache});
    // (createDirPath refuses a last component that is a link to a directory)
    std.Io.Dir.cwd().createDirPath(io, cache) catch {};
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(what, &h, .{});
    const prune = try std.Io.Dir.cwd().createFile(io, try std.fmt.allocPrint(arena, "{s}/prune.lock", .{dir}), .{ .truncate = false, .lock = .shared });
    errdefer prune.close(io);
    const own = try std.Io.Dir.cwd().createFile(io, try std.fmt.allocPrint(arena, "{s}/{s}-{s}.lock", .{ dir, kind, std.fmt.bytesToHex(h, .lower)[0..32] }), .{ .truncate = false, .lock = .exclusive });
    return .{ .prune = prune, .own = own };
}

/// The lock at `path`, taken without waiting; null while another process holds it.
pub fn tryExclusive(io: std.Io, path: []const u8) !?std.Io.File {
    return std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => null,
        else => err,
    };
}

/// Path of the cached file for `sha256`.
pub fn cachePath(arena: Allocator, cache: []const u8, sha256: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ cache, "sources", sha256 });
}

/// Make sure one source is in the cache with a matching checksum.
/// `message` gets a human-readable reason on failure.
pub fn fetchOne(arena: Allocator, io: std.Io, cache: []const u8, src: recipe.Source, message: *[]const u8) Error!Status {
    switch (src) {
        .git => {
            message.* = "git sources are not supported yet";
            return error.Unsupported;
        },
        .tarball => |t| {
            const held = keyLock(arena, io, cache, "source", t.sha256) catch return error.DownloadFailed;
            defer held.release(io);
            if (!validSha256(t.sha256)) {
                message.* = try std.fmt.allocPrint(arena, "'{s}': not a lowercase sha256", .{t.sha256});
                return error.InvalidChecksum;
            }
            const dir = try std.fs.path.join(arena, &.{ cache, "sources" });
            const final = try cachePath(arena, cache, t.sha256);
            if (std.Io.Dir.cwd().access(io, final, .{})) |_| {
                // Re-check what is on disk; a damaged cache entry is replaced.
                if (hashFile(io, final)) |have| {
                    if (std.mem.eql(u8, &have, t.sha256)) return .cached;
                } else |_| {}
                std.Io.Dir.cwd().deleteFile(io, final) catch {};
            } else |_| {}

            std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
                message.* = try std.fmt.allocPrint(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
                return error.DownloadFailed;
            };
            // Named after the URL too: two new snapshots whose recipes both
            // carry the placeholder checksum (zeros) must not share one file.
            var url_hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(t.url, &url_hash, .{});
            const tmp = try std.fmt.allocPrint(arena, "{s}.{x}.part", .{ final, url_hash[0..8] });
            if (std.mem.startsWith(u8, t.url, "snapshot:")) {
                try makeSnapshot(arena, io, cache, t.url["snapshot:".len..], tmp, message);
            } else {
                const res = std.process.run(arena, io, .{
                    .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "3", "--retry-all-errors", "--output", tmp, t.url },
                }) catch |err| {
                    message.* = try std.fmt.allocPrint(arena, "cannot run curl: {s}", .{@errorName(err)});
                    return error.DownloadFailed;
                };
                const ok = switch (res.term) {
                    .exited => |c| c == 0,
                    else => false,
                };
                if (!ok) {
                    message.* = try std.fmt.allocPrint(arena, "download of {s} failed: {s}", .{ t.url, std.mem.trim(u8, res.stderr, "\n ") });
                    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
                    return error.DownloadFailed;
                }
            }
            const got = hashFile(io, tmp) catch |err| {
                message.* = try std.fmt.allocPrint(arena, "cannot read downloaded file: {s}", .{@errorName(err)});
                return error.DownloadFailed;
            };
            if (!std.mem.eql(u8, &got, t.sha256)) {
                if (std.mem.startsWith(u8, t.url, "snapshot:")) {
                    // A new snapshot (the recipe cannot know its checksum before
                    // the first one is made): kept under the checksum it has.
                    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), try cachePath(arena, cache, &got), io) catch {};
                    message.* = try std.fmt.allocPrint(arena, "the snapshot made for {s} has sha256 {s} (recipe says {s}); it is kept in the cache: put that checksum in the recipe if this is a new snapshot", .{ t.url, &got, t.sha256 });
                    return error.BadChecksum;
                }
                message.* = try std.fmt.allocPrint(arena, "checksum mismatch for {s}: recipe says {s}, got {s}", .{ t.url, t.sha256, &got });
                std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
                return error.BadChecksum;
            }
            try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), final, io);
            return .downloaded;
        },
    }
}

const snapshot_scripts = [_][2][]const u8{
    .{ "electron", @embedFile("scripts/snapshot-electron.sh") },
    .{ "dotnet", @embedFile("scripts/snapshot-dotnet.sh") },
    .{ "git", @embedFile("scripts/snapshot-git.sh") },
    .{ "scratch-media", @embedFile("scripts/snapshot-scratch-media.sh") },
    .{ "dart", @embedFile("scripts/snapshot-dart.sh") },
    .{ "brave", @embedFile("scripts/snapshot-brave.sh") },
    .{ "euro-office", @embedFile("scripts/snapshot-euro-office.sh") },
};

/// Make the tarball of a `snapshot:` source into `tmp`. The script's output
/// goes to `<cache>/snapshots/<kind>-<args>.log`; its work directory
/// (`<cache>/snapshots/<kind>-<args>/`) is kept, so a failed run resumes.
fn makeSnapshot(arena: Allocator, io: std.Io, cache: []const u8, spec: []const u8, tmp: []const u8, message: *[]const u8) Error!void {
    var words = std.mem.tokenizeScalar(u8, spec, ' ');
    const kind = words.next() orelse "";
    const script = for (snapshot_scripts) |s| {
        if (std.mem.eql(u8, s[0], kind)) break s[1];
    } else {
        message.* = try std.fmt.allocPrint(arena, "unknown snapshot kind '{s}'", .{kind});
        return error.Unsupported;
    };
    var id: std.ArrayList(u8) = .empty;
    try id.appendSlice(arena, kind);
    var args: std.ArrayList([]const u8) = .empty;
    while (words.next()) |w| {
        try id.append(arena, '-');
        try id.appendSlice(arena, w);
        try args.append(arena, w);
    }
    // A repository URL among the arguments (snapshot:git) would make the
    // name a path: keep it one file name.
    for (id.items) |*c| if (c.* == '/' or c.* == ':') {
        c.* = '_';
    };
    // Pinned checksums make some argument lists longer than a file name may be: those names are cut, and told
    // apart by a hash of the whole list.
    if (id.items.len > 180) {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(spec, &h, .{});
        id.shrinkRetainingCapacity(100);
        try id.appendSlice(arena, try std.fmt.allocPrint(arena, "-{s}", .{std.fmt.bytesToHex(h, .lower)[0..16]}));
    }
    const dir = try std.fs.path.join(arena, &.{ cache, "snapshots" });
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    const adir = std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot resolve {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    // its own copy: one file per kind was rewritten while another snapshot's shell might be reading it
    const sh_path = try std.fmt.allocPrint(arena, "{s}/{s}.sh", .{ adir, id.items });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sh_path, .data = script }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot write {s}: {s}", .{ sh_path, @errorName(err) });
        return error.DownloadFailed;
    };
    const log = try std.fmt.allocPrint(arena, "{s}/{s}.log", .{ adir, id.items });
    const work = try std.fmt.allocPrint(arena, "{s}/{s}", .{ adir, id.items });
    const atmp = if (std.fs.path.isAbsolute(tmp)) tmp else blk: {
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", arena) catch return error.DownloadFailed;
        break :blk try std.fs.path.join(arena, &.{ cwd, tmp });
    };
    var argv: std.ArrayList([]const u8) = .empty;
    // One maker per snapshot at a time (a world's build and a separate
    // `dkbuild fetch` would otherwise share the work directory, the log and
    // the .part file): flock on <work>.lock, without waiting; held, it exits
    // 75 before anything runs.
    const lock = try std.fmt.allocPrint(arena, "{s}.lock", .{work});
    try argv.appendSlice(arena, &.{ "flock", "-n", "-E", "75", lock, "sh", "-c", "log=$1; shift; exec sh \"$@\" > \"$log\" 2>&1", "sh", log, sh_path, atmp, work });
    try argv.appendSlice(arena, args.items);
    const res = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot run the {s} snapshot: {s}", .{ kind, @errorName(err) });
        return error.DownloadFailed;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    const busy = switch (res.term) {
        .exited => |c| c == 75,
        else => false,
    };
    if (busy) {
        // another fetch is making it: leave its files alone
        message.* = try std.fmt.allocPrint(arena, "the {s} snapshot is being made by another fetch (lock {s}); try again when it is done", .{ kind, lock });
        return error.DownloadFailed;
    }
    if (!ok) {
        message.* = try std.fmt.allocPrint(arena, "the {s} snapshot failed; log: {s}", .{ kind, log });
        std.Io.Dir.cwd().deleteFile(io, atmp) catch {};
        return error.DownloadFailed;
    }
}

test "validSha256" {
    const zeros = @as([64]u8, @splat('0'));
    const upper = @as([64]u8, @splat('A'));
    const nonhex = @as([64]u8, @splat('g'));
    try std.testing.expect(validSha256(&zeros));
    try std.testing.expect(!validSha256(zeros[1..]));
    try std.testing.expect(!validSha256(&upper));
    try std.testing.expect(!validSha256(&nonhex));
}

// ---- Dependencies vendored on the host -------------------------------------
//
// Go modules, Rust crates and Zig packages are fetched on the host (the build
// sandbox has no network) into stores shared by every package, each kept once:
//
//   cache/gomod/       Go's module cache (GOMODCACHE): download cache and store
//   cache/cargo-home/  cargo's download cache (CARGO_HOME)
//   cache/crates/      vendored crates, one directory each: <name>-<16 hex of
//                      the sha256 of its .cargo-checksum.json>
//   cache/zig-global/  zig's download cache (ZIG_GLOBAL_CACHE_DIR)
//   cache/zigpkg/      Zig packages, by their own hash name (zig-pkg/<name>)
//
// A package keeps only a list of what it uses, named after its source
// tarball's sha256 (cache/{godeps,cargodeps,zigdeps}/<sha256>.list), written
// last: its presence means the fetch is complete. The build reads the stores
// read-only (SPEC 9.4).

/// The name of a dependency list: the source tarball's sha256, followed, when more than the source decides what
/// is downloaded, by a hash of that too (the recipe's patches, which are applied first, and `extra`: a lock the
/// recipe keeps, its restore step). By the source alone, an edited patch or lock was never fetched again, and two
/// recipes with one source shared one list.
pub fn depsKey(arena: Allocator, io: std.Io, tarball_sha256: []const u8, patch_dir: []const u8, patches: []const []const u8, extra: []const []const u8) ![]const u8 {
    if (patches.len == 0 and extra.len == 0) return tarball_sha256;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    // each part with its length, so that parts cannot run into each other
    const add = struct {
        fn f(x: *std.crypto.hash.sha2.Sha256, part: []const u8) void {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, part.len, .little);
            x.update(&len);
            x.update(part);
        }
    }.f;
    for (patches) |p| {
        add(&h, p);
        add(&h, try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ patch_dir, p }), arena, .limited(1 << 26)));
    }
    add(&h, "extra");
    for (extra) |x| add(&h, x);
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ tarball_sha256, std.fmt.bytesToHex(h.finalResult(), .lower)[0..16] });
}

/// A cache filled before lists had such names holds only `<sha256>.list`. The first recipe with extra inputs to
/// ask for its own takes a copy, so nothing is downloaded again; `<sha256>.adopted` records that, so that after a
/// later edit the new name is fetched. A recipe without extra inputs does not use a list another has taken.
pub fn adoptList(arena: Allocator, io: std.Io, cache: []const u8, dir: []const u8, tarball_sha256: []const u8, key: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const at = struct {
        fn f(a: Allocator, c: []const u8, d: []const u8, name: []const u8, ext: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "{s}/{s}/{s}{s}", .{ c, d, name, ext });
        }
    }.f;
    const marker = try at(arena, cache, dir, tarball_sha256, ".adopted");
    const taken = if (cwd.access(io, marker, .{})) |_| true else |_| false;
    if (std.mem.eql(u8, key, tarball_sha256)) {
        // its list was another recipe's: fetch this one's own
        if (taken) {
            cwd.deleteFile(io, try at(arena, cache, dir, tarball_sha256, ".list")) catch {};
            cwd.deleteFile(io, marker) catch {};
        }
        return;
    }
    if (taken) return;
    if (cwd.access(io, try at(arena, cache, dir, key, ".list"), .{})) |_| return else |_| {}
    const list = cwd.readFileAlloc(io, try at(arena, cache, dir, tarball_sha256, ".list"), arena, .limited(1 << 24)) catch return;
    if (cwd.readFileAlloc(io, try at(arena, cache, dir, tarball_sha256, ".config.toml"), arena, .limited(1 << 22))) |cfg_text| {
        try cwd.writeFile(io, .{ .sub_path = try at(arena, cache, dir, key, ".config.toml"), .data = cfg_text });
    } else |_| {}
    try cwd.writeFile(io, .{ .sub_path = try at(arena, cache, dir, key, ".list"), .data = list });
    try cwd.writeFile(io, .{ .sub_path = marker, .data = key });
}

test "depsKey and adoptList: lists follow what decides them, and an old cache is taken over once" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const sha: *const [64]u8 = &@as([64]u8, @splat('a'));
    try tmp.dir.createDirPath(io, "cargodeps");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.patch", .data = "one" });
    try std.testing.expectEqualStrings(sha, try depsKey(a, io, sha, base, &.{}, &.{}));
    const k1 = try depsKey(a, io, sha, base, &.{"a.patch"}, &.{});
    const locked = try depsKey(a, io, sha, base, &.{}, &.{ "cargolock", "sub", "lockfile" });
    try std.testing.expect(!std.mem.eql(u8, k1, sha) and !std.mem.eql(u8, k1, locked));
    try tmp.dir.writeFile(io, .{ .sub_path = "cargodeps/" ++ sha ++ ".list", .data = "old list" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cargodeps/" ++ sha ++ ".config.toml", .data = "old config" });
    // the first recipe with a patch takes the old list over
    try adoptList(a, io, base, "cargodeps", sha, k1);
    try std.testing.expectEqualStrings("old list", try tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(a, "cargodeps/{s}.list", .{k1}), a, .limited(100)));
    try std.testing.expectEqualStrings("old config", try tmp.dir.readFileAlloc(io, try std.fmt.allocPrint(a, "cargodeps/{s}.config.toml", .{k1}), a, .limited(100)));
    // the patch edited: a new name, and no old list to be had for it
    try tmp.dir.writeFile(io, .{ .sub_path = "a.patch", .data = "two" });
    const k2 = try depsKey(a, io, sha, base, &.{"a.patch"}, &.{});
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
    try adoptList(a, io, base, "cargodeps", sha, k2);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, try std.fmt.allocPrint(a, "cargodeps/{s}.list", .{k2}), .{}));
    // a recipe without extra inputs does not use the list that was taken
    try adoptList(a, io, base, "cargodeps", sha, sha);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "cargodeps/" ++ sha ++ ".list", .{}));
}

/// The crates' list name for a recipe's source: see depsKey.
pub fn cargoDepsKey(arena: Allocator, io: std.Io, tarball_sha256: []const u8, patch_dir: []const u8, patches: []const []const u8, lock: ?CargoLock) ![]const u8 {
    const extra: []const []const u8 = if (lock) |l| try arena.dupe([]const u8, &.{ "cargolock", l.dir, try std.Io.Dir.cwd().readFileAlloc(io, l.file, arena, .limited(1 << 24)) }) else &.{};
    return depsKey(arena, io, tarball_sha256, patch_dir, patches, extra);
}

/// The list of a source tarball's Go modules (`module@version` lines).
pub fn goDepsPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/godeps/{s}.list", .{ cache, tarball_sha256 });
}

/// The list of a source tarball's crates (`<vendor dir> <store dir>` lines);
/// `<sha256>.config.toml` beside it is the `.cargo/config.toml` the build uses.
pub fn cargoDepsPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.list", .{ cache, tarball_sha256 });
}

/// The list of a source tarball's Zig packages (`zig-pkg/` names).
pub fn zigDepsPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/zigdeps/{s}.list", .{ cache, tarball_sha256 });
}

/// Runs a dependency fetch script; `what` names it in errors.
fn runDepScript(arena: Allocator, io: std.Io, cache: []const u8, kind: []const u8, script: []const u8, what: []const u8, message: *[]const u8) Error!Status {
    const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ cache, kind });
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    const res = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", script } }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot run the {s} fetch: {s}", .{ what, @errorName(err) });
        return error.DownloadFailed;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        message.* = try std.fmt.allocPrint(arena, "{s} fetch failed: {s}", .{ what, std.mem.trim(u8, res.stderr, "\n ") });
        return error.DownloadFailed;
    }
    return .downloaded;
}

/// The start of every fetch script: an empty work directory {0s}, the source
/// unpacked in it ($top), and absolute $cache and $t.
const dep_prologue =
    \\set -e
    \\cache=$(cd '{1s}' && pwd)
    \\rm -rf '{0s}'; mkdir -p '{0s}/src'
    \\t=$(cd '{0s}' && pwd)
    \\
;
const dep_unpack =
    \\tar -xf '{2s}' -C "$t/src"
    \\# one top directory, or else (the archive has none: Helix's source release) the extraction directory itself
    \\set -- "$t"/src/*
    \\if [ $# -eq 1 ] && [ -d "$1" ]; then top="$1"; else top="$t/src"; fi
    \\
;

/// For recipes with the `godeps` option: download the modules the source
/// needs into the shared module cache (cache/gomod) with the `go` on the
/// host's PATH (GOTOOLCHAIN=auto fetches the Go version the module asks for),
/// and list them. The build uses the cache read-only, with GOPROXY=off.
pub fn fetchGoDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, patch_dir: []const u8, patches: []const []const u8, message: *[]const u8) Error!Status {
    const held = keyLock(arena, io, cache, "go", tarball_sha256) catch return error.DownloadFailed;
    defer held.release(io);
    const key = depsKey(arena, io, tarball_sha256, patch_dir, patches, &.{}) catch return error.DownloadFailed;
    adoptList(arena, io, cache, "godeps", tarball_sha256, key) catch return error.DownloadFailed;
    const out_path = try goDepsPath(arena, cache, key);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tmp = try std.fmt.allocPrint(arena, "{s}/godeps/tmp-{s}", .{ cache, key });
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const old = try std.fmt.allocPrint(arena, "{s}/godeps/{s}.tar", .{ cache, tarball_sha256 });
    // The recipe's patches first, as the build applies them: one that changes
    // go.mod (nuclei's moves a module to a newer version) changes what to fetch.
    var apply: std.ArrayList(u8) = .empty;
    for (patches) |pt| try apply.appendSlice(arena, try std.fmt.allocPrint(arena, "patch -Np1 -s -d \"$top\" -i \"$(cd '{s}' && pwd)/{s}\"\n", .{ patch_dir, pt }));
    const script = try std.fmt.allocPrint(arena, dep_prologue ++ dep_unpack ++ "{5s}" ++
        \\export GOMODCACHE="$cache/gomod" GOPATH="$t/gopath" GOCACHE="$t/gocache" GOTOOLCHAIN=auto GOFLAGS=-mod=mod
        \\( cd "$top" && timeout 1800 go mod download && go list -m -f '{{{{.Path}}}}@{{{{.Version}}}}' all ) > "$t/list"
        \\mv "$t/list" '{3s}.part'; mv '{3s}.part' '{3s}'
        \\rm -f '{4s}'
        \\chmod -R u+w "$t"; rm -rf "$t"
    , .{ tmp, cache, tarball, out_path, old, apply.items });
    return runDepScript(arena, io, cache, "godeps", script, "Go module (needs `go` on PATH)", message);
}

/// For recipes with the `cargodeps` option: `cargo vendor` the source's crates
/// (the `cargo` on the host's PATH, with the shared cache/cargo-home), move
/// each crate into cache/crates unless it is there already, and keep the list
/// and the `.cargo/config.toml` that points cargo at `vendor/` (the source's
/// own config, if it has one, with the vendoring lines added). A tarball made
/// by an older dkbuild (<sha256>.tar) is converted without the network.
/// A Cargo.lock a recipe keeps in files/ (option `cargolock=<dir>`), for a
/// Rust project at <dir> of the source whose release ships no lockfile.
pub const CargoLock = struct { dir: []const u8, file: []const u8 };

/// The recipe's CargoLock, from its `cargolock=<dir>` option and files/Cargo.lock.
pub fn recipeCargoLock(arena: Allocator, options: []const []const u8, recipe_dir: []const u8) !?CargoLock {
    for (options) |o| if (std.mem.startsWith(u8, o, "cargolock=")) {
        return .{ .dir = o["cargolock=".len..], .file = try std.fs.path.join(arena, &.{ recipe_dir, "files", "Cargo.lock" }) };
    };
    return null;
}

/// Whether a source archive has a Cargo project at its top (a Cargo.lock
/// there): a further source of a cargodeps recipe is vendored only then.
pub fn hasTopCargoLock(arena: Allocator, io: std.Io, tarball: []const u8) bool {
    const cmd = std.fmt.allocPrint(arena, "tar -tf '{s}' 2>/dev/null | grep -qE '^(\\./)?[^/]+/Cargo.lock$'", .{tarball}) catch return false;
    const r = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", cmd } }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

/// The second half of a vendored crate's name in the shared store (`<dir>-<key>`), under which every later
/// package that locks that crate finds it, so it must describe the directory's contents. The first 16 hex
/// digits of the sha256 of .cargo-checksum.json do when that file lists every file with its hash and the
/// directory agrees (cargo vendor's own work). Otherwise (a crate the project carries itself, with no list; or
/// one whose list does not match it) the key is `t` and a hash of everything in the directory: with the list's
/// hash alone, one project's code would be stored, and later used, under another's name.
pub fn crateKey(arena: Allocator, io: std.Io, dir: []const u8) ![]const u8 {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    const list_name = ".cargo-checksum.json";
    const list = try d.readFileAlloc(io, list_name, arena, .limited(1 << 26));
    const files: ?std.json.ObjectMap = blk: {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, list, .{}) catch break :blk null;
        if (v != .object) break :blk null;
        const f = v.object.get("files") orelse break :blk null;
        break :blk if (f == .object) f.object else null;
    };

    const Entry = struct { path: []const u8, kind: std.Io.File.Kind };
    var entries: std.ArrayList(Entry) = .empty;
    var w = try d.walk(arena);
    defer w.deinit();
    while (try w.next(io)) |e| try entries.append(arena, .{ .path = try arena.dupe(u8, e.path), .kind = e.kind });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    var tree_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var listed: usize = 0;
    var agrees = files != null and files.?.count() > 0;
    for (entries.items) |e| {
        if (e.kind == .directory) continue;
        var line: []const u8 = undefined;
        switch (e.kind) {
            .file => {
                const st = try d.statFile(io, e.path, .{ .follow_symlinks = false });
                const sum = try hashFile(io, try std.fs.path.join(arena, &.{ dir, e.path }));
                line = try std.fmt.allocPrint(arena, "f{s}{s}", .{ if (st.permissions.toMode() & 0o111 != 0) "x" else "-", &sum });
                if (agrees and !std.mem.eql(u8, e.path, list_name)) {
                    const want = files.?.get(e.path);
                    if (want != null and want.? == .string and std.mem.eql(u8, want.?.string, &sum)) listed += 1 else agrees = false;
                }
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                line = try std.fmt.allocPrint(arena, "l{s}", .{buf[0..try d.readLink(io, e.path, &buf)]});
                agrees = false; // cargo's list has files only
            },
            else => return error.UnexpectedFileKind,
        }
        // NUL cannot be in a path or a link's target, so the entries cannot run into each other
        for ([_][]const u8{ e.path, line }) |part| {
            tree_hash.update(part);
            tree_hash.update(&.{0});
        }
    }
    if (agrees and listed == files.?.count()) {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(list, &h, .{});
        return arena.dupe(u8, std.fmt.bytesToHex(h, .lower)[0..16]);
    }
    return std.fmt.allocPrint(arena, "t{s}", .{std.fmt.bytesToHex(tree_hash.finalResult(), .lower)[0..16]});
}

test "crateKey: the list's hash only for a directory that agrees with its list" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const S = struct {
        fn make(dir: std.Io.Dir, io_: std.Io, a_: Allocator, root: []const u8, name: []const u8, code: []const u8, list: []const u8) ![]const u8 {
            try dir.createDirPath(io_, try std.fmt.allocPrint(a_, "{s}/src", .{name}));
            try dir.writeFile(io_, .{ .sub_path = try std.fmt.allocPrint(a_, "{s}/src/lib.rs", .{name}), .data = code });
            try dir.writeFile(io_, .{ .sub_path = try std.fmt.allocPrint(a_, "{s}/.cargo-checksum.json", .{name}), .data = list });
            return crateKey(a_, io_, try std.fs.path.join(a_, &.{ root, name }));
        }
    };
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("genuine", &h, .{});
    const list = try std.fmt.allocPrint(a, "{{\"files\":{{\"src/lib.rs\":\"{s}\"}},\"package\":\"x\"}}", .{&std.fmt.bytesToHex(h, .lower)});
    var lh: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(list, &lh, .{});
    const genuine = try S.make(tmp.dir, io, a, base, "genuine", "genuine", list);
    try std.testing.expectEqualStrings(std.fmt.bytesToHex(lh, .lower)[0..16], genuine); // as before this check
    // the genuine list beside other code, or beside one file more, gets a key of its own
    const altered = try S.make(tmp.dir, io, a, base, "altered", "altered", list);
    try std.testing.expect(altered[0] == 't' and !std.mem.eql(u8, altered, genuine));
    try tmp.dir.writeFile(io, .{ .sub_path = "genuine/build.rs", .data = "extra" });
    try std.testing.expect((try crateKey(a, io, try std.fs.path.join(a, &.{ base, "genuine" })))[0] == 't');
    // crates a project carries, with no list: told apart by their contents, and stable
    const empty = "{\"files\":{},\"package\":null}";
    const one = try S.make(tmp.dir, io, a, base, "one", "project one", empty);
    const two = try S.make(tmp.dir, io, a, base, "two", "project two", empty);
    const again = try S.make(tmp.dir, io, a, base, "again", "project one", empty);
    try std.testing.expect(!std.mem.eql(u8, one, two));
    try std.testing.expectEqualStrings(one, again);
}

/// Run before cargo, which runs on the host: shell, in the fetch script ($t the work directory, $top the project).
const cargo_guard =
    \\    # The source is untrusted and cargo runs on the host. First: the project's directory is really inside the work
    \\    # directory (an archive's top "directory" may be a link to anywhere).
    \\    here=$(cd "$t" && pwd -P)
    \\    top=$(cd "$top" && pwd -P)
    \\    case $top/ in
    \\        "$here"/src/*) ;;
    \\        *) echo "the source's project directory is outside the source: $top" >&2; exit 1 ;;
    \\    esac
    \\    # The build gets the project's own cargo config as it is (it runs in the sandbox); keep it before cutting it down.
    \\    : > "$t/orig-config.toml"
    \\    if [ ! -L "$top/.cargo" ] && [ -f "$top/.cargo/config.toml" ]; then
    \\        case $(readlink -f -- "$top/.cargo/config.toml") in
    \\            "$here"/src/*) cp "$top/.cargo/config.toml" "$t/orig-config.toml" ;;
    \\        esac
    \\    fi
    \\    # For vendoring, every config cargo will read (this directory's and those above it, inside the source) keeps only
    \\    # what chooses the crates: [patch], [source], [registries], [resolver]. The others can name programs for cargo
    \\    # to run (build.rustc, wrappers, credential providers, aliases). A TOML table lasts until the next header, so
    \\    # nothing printed here can belong to another table.
    \\    d=$top
    \\    while :; do
    \\        if [ -L "$d/.cargo" ]; then rm -f -- "$d/.cargo"; fi
    \\        for f in "$d/.cargo/config.toml" "$d/.cargo/config"; do
    \\            [ -e "$f" ] || [ -L "$f" ] || continue
    \\            : > "$t/safe-config.toml"
    \\            case $(readlink -f -- "$f") in
    \\                "$here"/src/*)
    \\                    awk '
    \\                        /^[ \t]*\[/ { h = $0; sub(/^[ \t]*\[+[ \t]*/, "", h); sub(/[]. \t].*/, "", h); gsub(/["\047]/, "", h)
    \\                                      keep = (h == "patch" || h == "source" || h == "registries" || h == "resolver") }
    \\                        keep && !(h == "registries" && /credential/) { print }
    \\                    ' "$f" > "$t/safe-config.toml" ;;
    \\            esac
    \\            rm -f -- "$f"
    \\            cp "$t/safe-config.toml" "$f"
    \\        done
    \\        [ "$d" != "$here/src" ] || break
    \\        d=$(dirname -- "$d")
    \\    done
    \\    # rustup's toolchain file may name a directory of programs ("path"): a plain version or channel is honoured,
    \\    # anything else gets the host's own toolchain. The variable overrides the file.
    \\    if command -v rustup >/dev/null 2>&1; then
    \\        ch=
    \\        if [ -f "$top/rust-toolchain.toml" ]; then ch=$(sed -n "s/^[ \t]*channel[ \t]*=[ \t]*[\"']\([^\"']*\)[\"'].*/\1/p" "$top/rust-toolchain.toml" | head -n 1)
    \\        elif [ -f "$top/rust-toolchain" ]; then
    \\            ch=$(sed -n "s/^[ \t]*channel[ \t]*=[ \t]*[\"']\([^\"']*\)[\"'].*/\1/p" "$top/rust-toolchain" | head -n 1)
    \\            [ -n "$ch" ] || ch=$(head -n 1 "$top/rust-toolchain" | tr -d ' \t\r')
    \\        fi
    \\        printf '%s\n' "$ch" | grep -Eqx 'stable|beta|nightly(-[0-9]{4}-[0-9]{2}-[0-9]{2})?|[0-9]+\.[0-9]+(\.[0-9]+)?' \
    \\            || ch=$(cd "$t" && rustup show active-toolchain | cut -d' ' -f1)
    \\        export RUSTUP_TOOLCHAIN="$ch"
    \\    fi
    \\
;

pub fn fetchCargoDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, patch_dir: []const u8, patches: []const []const u8, lock: ?CargoLock, message: *[]const u8) Error!Status {
    const held = keyLock(arena, io, cache, "cargo", tarball_sha256) catch return error.DownloadFailed;
    defer held.release(io);
    const key = cargoDepsKey(arena, io, tarball_sha256, patch_dir, patches, lock) catch return error.DownloadFailed;
    adoptList(arena, io, cache, "cargodeps", tarball_sha256, key) catch return error.DownloadFailed;
    const out_path = try cargoDepsPath(arena, cache, key);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tmp = try std.fmt.allocPrint(arena, "{s}/cargodeps/tmp-{s}", .{ cache, key });
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const old = try std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.tar", .{ cache, tarball_sha256 });
    const config = try std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.config.toml", .{ cache, key });
    // The recipe's patches first, as the build applies them: one that changes
    // Cargo.lock (libopenraw's newer libc, for musl without open64) changes
    // the crates to vendor.
    var apply: std.ArrayList(u8) = .empty;
    for (patches) |pt| try apply.appendSlice(arena, try std.fmt.allocPrint(arena, "    patch -Np1 -s -d \"$top\" -i \"$(cd '{s}' && pwd)/{s}\"\n", .{ patch_dir, pt }));
    // a Cargo.lock the recipe keeps (the release has none): into its project
    // directory, which is where the crates are vendored from
    if (lock) |l| try apply.appendSlice(arena, try std.fmt.allocPrint(arena, "    top=\"$top/{s}\"; cp \"$(cd '{s}' && pwd)/{s}\" \"$top/Cargo.lock\"\n", .{ l.dir, std.fs.path.dirname(l.file) orelse ".", std.fs.path.basename(l.file) }));
    const script = try std.fmt.allocPrint(arena, dep_prologue ++
        \\if [ -f '{4s}' ]; then
        \\    top="$t/src/old"; mkdir -p "$top"; tar -xf '{4s}' -C "$top"
        \\    cp "$top/.cargo/config.toml" "$t/config.toml"
        \\else
        \\
    ++ dep_unpack ++ "{6s}{7s}" ++
        \\    export CARGO_HOME="$cache/cargo-home"
        \\    # the Cargo project at the top, or else the first one below it (hashcat's
        \\    # is in Rust/generic_hash); vendor/ and .cargo/ stay at the top, where
        \\    # cargo finds them from any directory under it
        \\    m=Cargo.toml
        \\    [ -f "$top/Cargo.lock" ] || m=$(cd "$top" && find . -name Cargo.lock -not -path './vendor/*' | sort | head -n1 | sed 's|Cargo.lock$|Cargo.toml|')
        \\    ( cd "$top" && RUSTC_BOOTSTRAP=1 timeout 1800 cargo vendor --locked --manifest-path "${{m:-Cargo.toml}}" vendor > "$t/vendor.toml" )
        \\    {{ if [ -s "$t/orig-config.toml" ]; then cat "$t/orig-config.toml"; printf '\n'; fi; cat "$t/vendor.toml"; }} > "$t/config.toml"
        \\fi
        \\store="$cache/crates"; mkdir -p "$store"
        \\: > "$t/list"
        \\for d in "$top"/vendor/*/; do
        \\    [ -d "$d" ] || continue   # nothing to vendor: the pattern stays as written
        \\    n=$(basename "$d")
        \\    # a crate the project carries in its own vendor/ (a [patch] path copy) has no checksum file, which cargo's vendored source
        \\    # needs: an empty one, as `cargo vendor` writes for a crate with no checked files
        \\    [ -f "$d/.cargo-checksum.json" ] || printf '{{"files":{{}},"package":null}}' > "$d/.cargo-checksum.json"
        \\    # the key describes the directory's contents (crateKey); not read through a pipe, whose status would be lost
        \\    key=$('{8s}' crate-key "$d")
        \\    k="$n-$key"
        \\    [ -e "$store/$k" ] || mv -T "$d" "$store/$k" 2>/dev/null || [ -e "$store/$k" ]
        \\    echo "$n $k" >> "$t/list"
        \\done
        \\mv "$t/config.toml" '{5s}'
        \\mv "$t/list" '{3s}.part'; mv '{3s}.part' '{3s}'
        \\rm -f '{4s}'
        \\rm -rf "$t"
    , .{ tmp, cache, tarball, out_path, old, config, apply.items, cargo_guard, std.process.executablePathAlloc(io, arena) catch return error.DownloadFailed });
    return runDepScript(arena, io, cache, "cargodeps", script, "crate (needs `cargo` on PATH)", message);
}

/// For recipes with the `zigdeps` option: `zig build --fetch=all` (the `zig`
/// on the host's PATH, which must be a version the project accepts; the
/// shared cache/zig-global), then move each package of zig-pkg/ into
/// cache/zigpkg unless it is there already, and list them. The build lays
/// zig-pkg/ back for `zig build --system zig-pkg` (SPEC 9.4 item 3). A tarball
/// made by an older dkbuild (<sha256>.tar) is converted without the network.
pub fn fetchZigDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) Error!Status {
    const held = keyLock(arena, io, cache, "zig", tarball_sha256) catch return error.DownloadFailed;
    defer held.release(io);
    const out_path = try zigDepsPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tmp = try std.fmt.allocPrint(arena, "{s}/zigdeps/tmp-{s}", .{ cache, tarball_sha256 });
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const old = try std.fmt.allocPrint(arena, "{s}/zigdeps/{s}.tar", .{ cache, tarball_sha256 });
    const script = try std.fmt.allocPrint(arena, dep_prologue ++
        \\if [ -f '{4s}' ]; then
        \\    top="$t/src/old"; mkdir -p "$top"; tar -xf '{4s}' -C "$top"
        \\else
        \\
    ++ dep_unpack ++
        \\    # --fetch=all also fetches the lazy dependencies of other platforms and of options the
        \\    # build does not use (flow's freetype for its GUI), which can be unreachable or stale:
        \\    # if that fails, fetch what the default build needs (--fetch=needed, zig's default)
        \\    # zig takes a directory zig-pkg/<hash>/ on trust, and these go into the store every package shares. So
        \\    # one the source ships is kept only if its contents hash to its name, and then as zig's own copy of it,
        \\    # which has just the files the hash covers; the others are fetched.
        \\    ( cd "$top"
        \\      if [ -L zig-pkg ]; then rm -f zig-pkg; fi
        \\      for d in zig-pkg/*; do
        \\          [ -e "$d" ] || [ -L "$d" ] || continue
        \\          n=${{d##*/}}
        \\          h=
        \\          if [ ! -L "$d" ]; then h=$(ZIG_GLOBAL_CACHE_DIR="$t/verify" timeout 600 zig fetch "./$d" | tail -n 1) || h=; fi
        \\          rm -rf -- "$d"
        \\          if [ "$h" = "$n" ] && [ -f "$t/verify/p/$n.tar.gz" ]; then tar -xzf "$t/verify/p/$n.tar.gz" -C zig-pkg
        \\          else echo "zig: the source's zig-pkg/$n does not hash to its name; fetching it" >&2; fi
        \\      done )
        \\    ( cd "$top" && export ZIG_GLOBAL_CACHE_DIR="$cache/zig-global" && {{ timeout 1800 zig build --fetch=all || {{ echo "zig: --fetch=all failed, fetching what the default build needs" >&2; timeout 1800 zig build --fetch=needed; }}; }} )
        \\fi
        \\store="$cache/zigpkg"; mkdir -p "$store"
        \\: > "$t/list"
        \\if [ -d "$top/zig-pkg" ]; then
        \\    for d in "$top"/zig-pkg/*/; do
        \\        [ -d "$d" ] || continue
        \\        n=$(basename "$d")
        \\        [ -e "$store/$n" ] || mv -T "$d" "$store/$n" 2>/dev/null || [ -e "$store/$n" ]
        \\        echo "$n" >> "$t/list"
        \\    done
        \\fi
        \\mv "$t/list" '{3s}.part'; mv '{3s}.part' '{3s}'
        \\rm -f '{4s}'
        \\rm -rf "$t"
    , .{ tmp, cache, tarball, out_path, old });
    return runDepScript(arena, io, cache, "zigdeps", script, "Zig dependency (needs `zig` on PATH)", message);
}
