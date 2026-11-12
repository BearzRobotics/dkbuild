//! npm dependencies, vendored at fetch time (SPEC.md 7.4).
//!
//! The store, cache/npm/, is laid out as npm's own cache content directory
//! (content-v2/<algorithm>/<hex>/...): each package tarball is kept once, named
//! by the integrity hash its lockfile gives. A build sees the store read-only,
//! linked into a private npm cache, and `npm ci --offline` finds every package
//! there by that hash. Nothing from a downloaded package runs at fetch time:
//! the lockfiles are read as JSON and the tarballs are only checked and stored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fetch = @import("fetch.zig");

/// The list of a source tarball's npm packages (store paths, one per line).
pub fn listPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/npmdeps/{s}.list", .{ cache, tarball_sha256 });
}

const Pkg = struct { url: []const u8, integrity: []const u8 };

/// A Subresource Integrity value (`sha512-<base64>`; the strongest of several).
const Digest = struct { algo: []const u8, hex: []const u8, raw: []const u8 };

fn parseIntegrity(arena: Allocator, integrity: []const u8) !?Digest {
    var best: ?Digest = null;
    var it = std.mem.tokenizeScalar(u8, integrity, ' ');
    while (it.next()) |part| {
        const dash = std.mem.indexOfScalar(u8, part, '-') orelse continue;
        const algo = part[0..dash];
        if (!std.mem.eql(u8, algo, "sha512") and !std.mem.eql(u8, algo, "sha256") and !std.mem.eql(u8, algo, "sha1")) continue;
        const b64 = part[dash + 1 ..];
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch continue;
        const raw = try arena.alloc(u8, n);
        dec.decode(raw, b64) catch continue;
        const hex = try arena.alloc(u8, n * 2);
        const chars = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            hex[2 * i] = chars[b >> 4];
            hex[2 * i + 1] = chars[b & 15];
        }
        const d: Digest = .{ .algo = algo, .hex = hex, .raw = raw };
        if (best == null or std.mem.eql(u8, algo, "sha512")) best = d;
    }
    return best;
}

/// npm's cache layout for a digest: content-v2/<algo>/<2 hex>/<2 hex>/<rest>.
fn storeRel(arena: Allocator, d: Digest) ![]const u8 {
    return std.fmt.allocPrint(arena, "content-v2/{s}/{s}/{s}/{s}", .{ d.algo, d.hex[0..2], d.hex[2..4], d.hex[4..] });
}

/// Packages of one package-lock.json: lockfileVersion 2/3 ("packages") and 1
/// ("dependencies", nested). Local links and workspace members have no URL.
fn collect(arena: Allocator, text: []const u8, out: *std.ArrayList(Pkg), missing: *usize) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.BadLockfile;
    if (root != .object) return error.BadLockfile;
    if (root.object.get("packages")) |pk| if (pk == .object) {
        var it = pk.object.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.len == 0 or e.value_ptr.* != .object) continue;
            try add(arena, e.value_ptr.*.object, out, missing);
        }
        return;
    };
    if (root.object.get("dependencies")) |deps| try collectV1(arena, deps, out, missing);
}

/// Packages of one pnpm-lock.yaml (lockfileVersion 9), read line by line:
/// the `packages:` section's entries (`  'name@version':`, two spaces in) and
/// their `resolution: {integrity: ...[, tarball: url]}`. Without a tarball the
/// URL is the npm registry's, as pnpm derives it. Local directories, links and
/// workspace members have no integrity and are skipped; git sources without
/// one count as missing.
fn collectPnpm(arena: Allocator, text: []const u8, out: *std.ArrayList(Pkg), missing: *usize) !void {
    if (std.mem.indexOf(u8, text, "lockfileVersion: '9") == null) return error.BadLockfile;
    var in_packages = false;
    var key: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] != ' ') {
            in_packages = std.mem.eql(u8, line, "packages:");
            key = null;
            continue;
        }
        if (!in_packages) continue;
        if (line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') {
            var k = std.mem.trimEnd(u8, line[2..], ":");
            k = std.mem.trim(u8, k, "'\"");
            key = k;
            continue;
        }
        const t = std.mem.trim(u8, line, " ");
        if (!std.mem.startsWith(u8, t, "resolution: {")) continue;
        const k = key orelse continue;
        const integ = field(t, "integrity: ");
        const tarball = field(t, "tarball: ");
        if (integ == null) {
            if (std.mem.indexOf(u8, t, "directory:") == null and std.mem.indexOf(u8, t, "type: directory") == null) missing.* += 1;
            continue;
        }
        const url = tarball orelse blk: {
            // name@version: the name may be scoped (@scope/name)
            const at = std.mem.lastIndexOfScalar(u8, k, '@') orelse continue;
            if (at == 0) continue;
            const pname = k[0..at];
            const ver = k[at + 1 ..];
            const base = if (std.mem.lastIndexOfScalar(u8, pname, '/')) |sl| pname[sl + 1 ..] else pname;
            break :blk try std.fmt.allocPrint(arena, "https://registry.npmjs.org/{s}/-/{s}-{s}.tgz", .{ pname, base, ver });
        };
        try out.append(arena, .{ .url = url, .integrity = integ.? });
    }
}

/// The value of `name: value` inside a flow mapping (`{a: x, b: y}`).
fn field(t: []const u8, name: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, t, name) orelse return null;
    const rest = t[i + name.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " '\"");
}

test "collectPnpm: registry and tarball entries, directories skipped" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const lock =
        \\lockfileVersion: '9.0'
        \\
        \\packages:
        \\
        \\  '@adobe/css-tools@4.5.0':
        \\    resolution: {integrity: sha512-AAAA==}
        \\
        \\  left-pad@1.3.0:
        \\    resolution: {integrity: sha512-BBBB==}
        \\    engines: {node: '>=10'}
        \\
        \\  odd@1.0.0:
        \\    resolution: {integrity: sha512-CCCC==, tarball: https://example.org/odd-1.0.0.tgz}
        \\
        \\  plugin@file:.eslint-plugin:
        \\    resolution: {directory: .eslint-plugin, type: directory}
        \\
        \\snapshots:
        \\
        \\  left-pad@1.3.0: {}
        \\
    ;
    var pkgs: std.ArrayList(Pkg) = .empty;
    var missing: usize = 0;
    try collectPnpm(a, lock, &pkgs, &missing);
    try std.testing.expectEqual(@as(usize, 3), pkgs.items.len);
    try std.testing.expectEqual(@as(usize, 0), missing);
    try std.testing.expectEqualStrings("https://registry.npmjs.org/@adobe/css-tools/-/css-tools-4.5.0.tgz", pkgs.items[0].url);
    try std.testing.expectEqualStrings("https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", pkgs.items[1].url);
    try std.testing.expectEqualStrings("https://example.org/odd-1.0.0.tgz", pkgs.items[2].url);
    try std.testing.expectEqualStrings("sha512-CCCC==", pkgs.items[2].integrity);
}

fn collectV1(arena: Allocator, deps: std.json.Value, out: *std.ArrayList(Pkg), missing: *usize) !void {
    if (deps != .object) return;
    var it = deps.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .object) continue;
        try add(arena, e.value_ptr.*.object, out, missing);
        if (e.value_ptr.*.object.get("dependencies")) |sub| try collectV1(arena, sub, out, missing);
    }
}

fn add(arena: Allocator, o: std.json.ObjectMap, out: *std.ArrayList(Pkg), missing: *usize) !void {
    if (o.get("link")) |l| if (l == .bool and l.bool) return;
    const resolved = o.get("resolved") orelse return;
    if (resolved != .string) return;
    const url = resolved.string;
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return;
    const integ = o.get("integrity") orelse {
        missing.* += 1;
        return;
    };
    if (integ != .string) return;
    try out.append(arena, .{ .url = url, .integrity = integ.string });
}

fn digestOf(algo: []const u8, data: []const u8, buf: []u8) []const u8 {
    if (std.mem.eql(u8, algo, "sha512")) {
        std.crypto.hash.sha2.Sha512.hash(data, buf[0..64], .{});
        return buf[0..64];
    } else if (std.mem.eql(u8, algo, "sha256")) {
        std.crypto.hash.sha2.Sha256.hash(data, buf[0..32], .{});
        return buf[0..32];
    }
    std.crypto.hash.Sha1.hash(data, buf[0..20], .{});
    return buf[0..20];
}

/// For recipes with the `npmdeps` option: every package of every
/// package-lock.json in the source (outside node_modules), downloaded into the
/// store unless it is there, each checked against its integrity hash.
/// fetchNpmDeps's message for a source without lockfiles (with several
/// sources, only one of them needs one).
pub const no_lockfile = "npm: the source has no package-lock.json or pnpm-lock.yaml";

pub fn fetchNpmDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) fetch.Error!fetch.Status {
    const out_path = try listPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const dir = try std.fmt.allocPrint(arena, "{s}/npmdeps", .{cache});
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, tarball_sha256 });
    std.Io.Dir.cwd().createDirPath(io, tmp) catch {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}", .{tmp});
        return error.DownloadFailed;
    };
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    // 1. Unpack and find the lockfiles (shell: tar and find only).
    const tarball = try fetch.cachePath(arena, cache, tarball_sha256);
    const find = try std.fmt.allocPrint(arena, "set -e; mkdir -p '{0s}/src'; tar -xf '{1s}' -C '{0s}/src'; " ++
        "find '{0s}/src' \\( -name package-lock.json -o -name pnpm-lock.yaml \\) -not -path '*/node_modules/*' > '{0s}/locks'", .{ tmp, tarball });
    const r1 = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", find } }) catch return error.DownloadFailed;
    if (!(r1.term == .exited and r1.term.exited == 0)) {
        message.* = try std.fmt.allocPrint(arena, "npm: cannot unpack the source: {s}", .{std.mem.trim(u8, r1.stderr, "\n ")});
        return error.DownloadFailed;
    }
    const locks = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/locks", .{tmp}), arena, .limited(1 << 20)) catch return error.DownloadFailed;
    return fromLocks(arena, io, cache, tmp, out_path, locks, message);
}

/// For a lockfile a recipe keeps in its files/ (a web UI whose upstream ships a
/// yarn.lock: the package-lock.json made from it once, then pinned there). Its
/// list is keyed by the lockfile's own sha256, so editing it refetches.
pub fn fetchNpmLockFile(arena: Allocator, io: std.Io, cache: []const u8, lock_path: []const u8, message: *[]const u8) fetch.Error!fetch.Status {
    const data = std.Io.Dir.cwd().readFileAlloc(io, lock_path, arena, .limited(1 << 28)) catch {
        message.* = try std.fmt.allocPrint(arena, "npm: cannot read {s}", .{lock_path});
        return error.DownloadFailed;
    };
    const key = try lockKey(arena, data);
    const out_path = try listPath(arena, cache, key);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tmp = try std.fmt.allocPrint(arena, "{s}/npmdeps/tmp-{s}", .{ cache, key });
    std.Io.Dir.cwd().createDirPath(io, tmp) catch {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}", .{tmp});
        return error.DownloadFailed;
    };
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    return fromLocks(arena, io, cache, tmp, out_path, try std.fmt.allocPrint(arena, "{s}\n", .{lock_path}), message);
}

/// The package-lock.json files a recipe keeps in its files/ directory
/// (`package-lock.json`, or `<name>.package-lock.json` for several).
pub fn recipeLocks(arena: Allocator, io: std.Io, files_dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(io, files_dir, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        if (std.mem.eql(u8, e.name, "package-lock.json") or std.mem.endsWith(u8, e.name, ".package-lock.json"))
            try out.append(arena, try std.fs.path.join(arena, &.{ files_dir, e.name }));
    }
    return out.items;
}

/// The sha256 (hex) a recipe lockfile's list is named by.
pub fn lockKey(arena: Allocator, data: []const u8) ![]const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.allocPrint(arena, "{x}", .{&h});
}

/// The packages of the lockfiles listed in `locks` (paths, one per line) into
/// the store, then their list to `out_path`.
fn fromLocks(arena: Allocator, io: std.Io, cache: []const u8, tmp: []const u8, out_path: []const u8, locks: []const u8, message: *[]const u8) fetch.Error!fetch.Status {
    var pkgs: std.ArrayList(Pkg) = .empty;
    var missing: usize = 0;
    var nlocks: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, locks, '\n');
    while (lines.next()) |lp| {
        nlocks += 1;
        const text = std.Io.Dir.cwd().readFileAlloc(io, lp, arena, .limited(1 << 28)) catch return error.DownloadFailed;
        if (std.mem.endsWith(u8, lp, "pnpm-lock.yaml")) {
            collectPnpm(arena, text, &pkgs, &missing) catch {
                message.* = try std.fmt.allocPrint(arena, "npm: {s} is not a pnpm lockfile (v9) dkbuild can read", .{lp});
                return error.DownloadFailed;
            };
        } else collect(arena, text, &pkgs, &missing) catch {
            message.* = try std.fmt.allocPrint(arena, "npm: {s} is not a lockfile npm wrote", .{lp});
            return error.DownloadFailed;
        };
    }
    if (nlocks == 0) {
        message.* = no_lockfile;
        return error.DownloadFailed;
    }
    if (missing > 0) {
        message.* = try std.fmt.allocPrint(arena, "npm: {d} lockfile entr(ies) have a URL but no integrity hash; npm could not find them offline", .{missing});
        return error.DownloadFailed;
    }
    // 2. What the store does not have yet, downloaded in parallel.
    const store = try std.fmt.allocPrint(arena, "{s}/npm", .{cache});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var list: std.ArrayList(u8) = .empty;
    var todo: std.ArrayList(struct { d: Digest, rel: []const u8, part: []const u8 }) = .empty;
    var cfg: std.ArrayList(u8) = .empty;
    for (pkgs.items) |p| {
        const d = (try parseIntegrity(arena, p.integrity)) orelse {
            message.* = try std.fmt.allocPrint(arena, "npm: unusable integrity {s} for {s}", .{ p.integrity, p.url });
            return error.DownloadFailed;
        };
        const rel = try storeRel(arena, d);
        if (seen.contains(rel)) continue;
        try seen.put(arena, rel, {});
        try list.appendSlice(arena, rel);
        try list.append(arena, '\n');
        const full = try std.fs.path.join(arena, &.{ store, rel });
        if (std.Io.Dir.cwd().access(io, full, .{})) |_| continue else |_| {}
        const part = try std.fmt.allocPrint(arena, "{s}/dl-{d}", .{ tmp, todo.items.len });
        try todo.append(arena, .{ .d = d, .rel = rel, .part = part });
        try cfg.appendSlice(arena, try std.fmt.allocPrint(arena, "url = \"{s}\"\noutput = \"{s}\"\n", .{ p.url, part }));
    }
    if (todo.items.len > 0) {
        const cfgp = try std.fmt.allocPrint(arena, "{s}/curl.cfg", .{tmp});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgp, .data = cfg.items }) catch return error.DownloadFailed;
        const r2 = std.process.run(arena, io, .{ .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "3", "--parallel", "--parallel-max", "16", "-K", cfgp } }) catch return error.DownloadFailed;
        if (!(r2.term == .exited and r2.term.exited == 0)) {
            message.* = try std.fmt.allocPrint(arena, "npm: downloads failed: {s}", .{std.mem.trim(u8, r2.stderr, "\n ")});
            return error.DownloadFailed;
        }
        // 3. Each file checked against its integrity hash, then moved into the store.
        for (todo.items) |t| {
            const data = std.Io.Dir.cwd().readFileAlloc(io, t.part, arena, .limited(1 << 31)) catch return error.DownloadFailed;
            var buf: [64]u8 = undefined;
            if (!std.mem.eql(u8, digestOf(t.d.algo, data, &buf), t.d.raw)) {
                message.* = try std.fmt.allocPrint(arena, "npm: {s} does not match its integrity hash", .{t.rel});
                return error.BadChecksum;
            }
            const full = try std.fs.path.join(arena, &.{ store, t.rel });
            std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(full).?) catch return error.DownloadFailed;
            std.Io.Dir.cwd().rename(t.part, std.Io.Dir.cwd(), full, io) catch return error.DownloadFailed;
        }
    }
    // 4. The list, written last: its presence means the fetch is complete.
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{out_path});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = list.items }) catch return error.DownloadFailed;
    std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), out_path, io) catch return error.DownloadFailed;
    return .downloaded;
}

test "integrity: sha512 is chosen and laid out like npm's cache" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const d = (try parseIntegrity(a, "sha1-2jmj7l5rSw0yVb/vlWAYkK/YBwk= sha512-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg==")).?;
    try std.testing.expectEqualStrings("sha512", d.algo);
    const rel = try storeRel(a, d);
    try std.testing.expectEqualStrings("content-v2/sha512/cf/83/e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e", rel);
}
