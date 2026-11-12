//! `dkbuild discs` (roadmap: "ISO package repositories, and a source ISO"):
//! the repository or the sources of the whole distribution as a set of ISO
//! images, either one large image (a USB stick, Ventoy) or a numbered set that
//! fits on DVDs or Blu-ray discs.
//!
//! Every disc holds the complete MANIFEST (signed with the repository key),
//! the public keys, `import.sh` and its share of the files under `data/`.
//! A file too large for the space left on a disc is cut into parts
//! (`<path>.dkpart.NNN`) on consecutive discs. `sh import.sh DIR` copies one
//! disc into DIR and checks every file against the MANIFEST; once all discs
//! are in (any order), the parts are joined and DIR is the complete set:
//!
//!   repo    DIR/apks/<arch>/ is a signed apk repository (Packages.adb and
//!           every current package of a recipe without `!repo-iso`)
//!   source  DIR/cache/ (every source tarball the recipes name and the
//!           vendored Go, Rust, Zig, npm, NuGet and Ruby stores),
//!           DIR/dkbuild.bundle (the git tree, `git clone` it) and
//!           DIR/dkrescue.iso (the build machine): a rebuild with no network
//!
//! A one-disc set is usable as it is: data/apks/<arch>/Packages.adb on the
//! mounted image is a repository. The private signing key is never on a disc.
//!
//! MANIFEST lines, tab-separated (disc 0: on every disc):
//!   F <sha256> <size> <disc> <path>             a file
//!   S <sha256> <size> -      <path> <parts>     a file cut into parts
//!   P <sha256> <size> <disc> <path>.dkpart.NNN  one part of it
//!   L -        0      <disc> <path> <target>    a symbolic link

const std = @import("std");
const cfg = @import("cfg.zig");
const sandbox = @import("sandbox.zig");
const tree = @import("tree.zig");
const build = @import("build.zig");
const fetch = @import("fetch.zig");
const split = @import("split.zig");
const recipe = @import("recipe.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Kind = enum { repo, source };

pub const Set = struct {
    name: []const u8,
    kind: Kind,
    arch: []const u8 = "x86_64",
    /// One of `media_names`: "usb" is one image of any size.
    media: []const u8 = "usb",
    /// The volume label (a disc of several gets "_<k>"); default: the name
    /// in capitals.
    label: []const u8 = "",
};

pub const Diagnostic = cfg.Diagnostic;
pub const Error = error{InvalidSet} || Allocator.Error;

/// Writable bytes of each medium (single-layer DVD±R: 2,295,104 sectors).
pub const media_names = [_][]const u8{ "usb", "cd", "dvd", "dvd-dl", "bd25", "bd50", "bd100" };
pub fn capacity(media: []const u8) ?u64 {
    const sizes = [_]u64{ std.math.maxInt(u64), 734_003_200, 4_700_372_992, 8_543_666_176, 25_025_314_816, 50_050_629_632, 100_103_356_416 };
    for (media_names, sizes) |n, s| if (std.mem.eql(u8, n, media)) return s;
    return null;
}

pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!Set {
    return parseChecked(arena, text, diag) catch |err| switch (err) {
        error.Invalid => error.InvalidSet,
        error.OutOfMemory => |e| e,
    };
}

fn parseChecked(arena: Allocator, text: []const u8, diag: *Diagnostic) cfg.Error!Set {
    const root = try cfg.parse(arena, text, diag);
    try cfg.onlyKeys(arena, diag, root, &.{ "name", "kind", "arch", "media", "label" }, "");
    const kind_s = try cfg.reqString(arena, diag, root, "kind");
    var set: Set = .{
        .name = try cfg.reqString(arena, diag, root, "name"),
        .kind = std.meta.stringToEnum(Kind, kind_s) orelse return cfg.fail(arena, diag, "kind '{s}': give repo or source", .{kind_s}),
    };
    if (try cfg.optString(arena, diag, root, "arch")) |a| set.arch = a;
    if (try cfg.optString(arena, diag, root, "media")) |m| set.media = m;
    if (try cfg.optString(arena, diag, root, "label")) |l| set.label = l else {
        const up = try arena.dupe(u8, set.name);
        for (up) |*c| c.* = if (c.* == '-') '_' else std.ascii.toUpper(c.*);
        set.label = up;
    }
    try check(arena, diag, set);
    return set;
}

/// Also run on a `--media` given on the command line.
pub fn check(arena: Allocator, diag: *Diagnostic, set: Set) cfg.Error!void {
    if (capacity(set.media) == null) return cfg.fail(arena, diag, "media '{s}': give one of usb, cd, dvd, dvd-dl, bd25, bd50, bd100", .{set.media});
    // "_NN" for a disc of several
    if (set.label.len == 0 or set.label.len > 29) return cfg.fail(arena, diag, "label '{s}': 1 to 29 characters", .{set.label});
    for ([_][]const u8{ set.name, set.label, set.arch }) |s| for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.')
            return cfg.fail(arena, diag, "'{s}': only letters, digits, '-', '_', '.'", .{s});
    };
}

/// A file (or link) of the set. `src` is relative to the project root, or
/// "work/<name>" for a file made for the set.
const Item = struct {
    path: []const u8,
    src: []const u8,
    size: u64,
    /// Known already (a source tarball is named by its sha256).
    sha: ?[]const u8 = null,
    link: ?[]const u8 = null,
};

/// Where an item, or one part of it, goes.
pub const Piece = struct { item: usize, disc: u32, offset: u64, len: u64, part: u32, parts: u32 };

/// What a disc's file system takes beyond the file's bytes: the 2 KiB
/// sector it is rounded up to, and a directory record with Rock Ridge.
fn cost(len: u64) u64 {
    return std.mem.alignForward(u64, len, 2048) + 512;
}
const min_part: u64 = 64 << 20;

/// Fill discs in order (items sorted by path, so a disc holds a stretch of
/// the alphabet). A file that does not fit the space left is cut, when both
/// it and the space are larger than `min_part`; otherwise it starts the next
/// disc. `usable` is per disc, after the files every disc carries.
pub fn plan(arena: Allocator, sizes: []const u64, usable: u64) Allocator.Error![]const Piece {
    var out: std.ArrayList(Piece) = .empty;
    var disc: u32 = 1;
    var used: u64 = 0;
    for (sizes, 0..) |size, i| {
        const first = out.items.len;
        var off: u64 = 0;
        while (true) {
            const left = size - off;
            const room = usable - used;
            if (cost(left) <= room) {
                try out.append(arena, .{ .item = i, .disc = disc, .offset = off, .len = left, .part = 0, .parts = 0 });
                used += cost(left);
                break;
            }
            if (left > min_part and room > min_part + 4096) {
                const n = std.mem.alignBackward(u64, room - 512 - 2048, 2048);
                try out.append(arena, .{ .item = i, .disc = disc, .offset = off, .len = n, .part = 0, .parts = 0 });
                off += n;
            }
            disc += 1;
            used = 0;
        }
        const pieces = out.items[first..];
        if (pieces.len > 1) for (pieces, 1..) |*p, k| {
            p.part = @intCast(k);
            p.parts = @intCast(pieces.len);
        };
    }
    return out.items;
}

/// Directories of cache/ that a rebuild needs besides the source tarballs:
/// the vendored stores and the lists of what each package uses from them.
/// Not cargo-home or zig-global (download caches) nor snapshots (work
/// directories; the snapshots themselves are tarballs in cache/sources).
const source_stores = [_][]const u8{ "crates", "cargodeps", "godeps", "gomod", "npm", "npmdeps", "zigpkg", "zigdeps", "gems", "gemdeps", "gemsums", "nuget", "pub", "pubdeps" };

pub const Options = struct {
    root: []const u8,
    key: []const u8 = "",
};

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn badPath(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, "\t\n\r'\\") != null or p.len == 0;
}

fn addFile(arena: Allocator, io: std.Io, items: *std.ArrayList(Item), path: []const u8, src: []const u8, sha: ?[]const u8) !void {
    const st = Dir.cwd().statFile(io, src, .{ .follow_symlinks = false }) catch |err| {
        say("error: {s}: {s}\n", .{ src, @errorName(err) });
        return error.PrepareFailed;
    };
    try items.append(arena, .{ .path = path, .src = src, .size = st.size, .sha = sha });
}

fn walkInto(arena: Allocator, io: std.Io, items: *std.ArrayList(Item), root: []const u8, rel: []const u8) !void {
    var d = Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ root, rel }), .{ .iterate = true }) catch return;
    defer d.close(io);
    var w = try d.walk(arena);
    defer w.deinit();
    while (try w.next(io)) |e| {
        // half-made entries of an interrupted fetch
        if (std.mem.startsWith(u8, e.path, "tmp-") or std.mem.indexOf(u8, e.path, "/tmp-") != null) continue;
        const path = try std.fs.path.join(arena, &.{ rel, e.path });
        switch (e.kind) {
            .file => {
                const st = try d.statFile(io, e.path, .{ .follow_symlinks = false });
                try items.append(arena, .{ .path = path, .src = try std.fs.path.join(arena, &.{ root, path }), .size = st.size });
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = try d.readLink(io, e.path, &buf);
                try items.append(arena, .{ .path = path, .src = try std.fs.path.join(arena, &.{ root, path }), .size = 0, .link = try arena.dupe(u8, buf[0..n]) });
            },
            else => {},
        }
    }
}

/// The package name of `<name>-<version>-r<N>.apk`.
fn apkName(file: []const u8) ?[]const u8 {
    const stem = file[0 .. file.len - ".apk".len];
    const r = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return null;
    const v = std.mem.lastIndexOfScalar(u8, stem[0..r], '-') orelse return null;
    return stem[0..v];
}

fn excluded(r: recipe.Recipe) bool {
    for (r.options) |o| if (std.mem.eql(u8, o, "!repo-iso")) return true;
    return false;
}

/// repo/<arch>/'s current packages of recipes without `!repo-iso`, as
/// apks/<arch>/<file>. Fails when one of them depends on a left-out package.
fn repoItems(arena: Allocator, io: std.Io, t: tree.Tree, set: Set, root: []const u8, items: *std.ArrayList(Item)) !void {
    const repo_rel = try std.fmt.allocPrint(arena, "{s}/repo/{s}", .{ root, set.arch });
    var d = Dir.cwd().openDir(io, repo_rel, .{ .iterate = true }) catch {
        say("error: {s} not found\n", .{repo_rel});
        return error.PrepareFailed;
    };
    defer d.close(io);
    var it = d.iterate();
    var stale: usize = 0;
    var left_out: std.ArrayList([]const u8) = .empty;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".apk")) continue;
        if (build.classify(t, e.name) != .current) {
            stale += 1;
            continue;
        }
        const pkg = apkName(e.name) orelse continue;
        const ri = t.provider(pkg) orelse continue;
        if (excluded(t.recipes[ri])) {
            try left_out.append(arena, try arena.dupe(u8, pkg));
            continue;
        }
        const name = try arena.dupe(u8, e.name);
        try addFile(arena, io, items, try std.fmt.allocPrint(arena, "apks/{s}/{s}", .{ set.arch, name }), try std.fmt.allocPrint(arena, "{s}/{s}", .{ repo_rel, name }), null);
    }
    // Nothing on the disc may need what was left out.
    var bad = false;
    for (t.recipes) |r| {
        if (excluded(r)) continue;
        var deps: std.ArrayList([]const u8) = .empty;
        try deps.appendSlice(arena, r.rundeps);
        for (r.subpackages) |sp| try deps.appendSlice(arena, sp.depends);
        for (deps.items) |dep| {
            const pi = t.provider(dep) orelse continue;
            if (excluded(t.recipes[pi])) {
                say("error: {s} depends on {s}, whose recipe {s} is !repo-iso\n", .{ r.name, dep, t.recipes[pi].name });
                bad = true;
            }
        }
    }
    if (bad) return error.PrepareFailed;
    if (stale > 0) say("note: {d} older package file(s) in {s} left out (`dkbuild prune` removes them)\n", .{ stale, repo_rel });
    if (left_out.items.len > 0) say("note: left out (!repo-iso): {s}\n", .{try std.mem.join(arena, " ", left_out.items)});
}

fn sourceItems(arena: Allocator, io: std.Io, t: tree.Tree, opts: Options, work_rel: []const u8, items: *std.ArrayList(Item)) !void {
    var seen = std.StringHashMap(void).init(arena);
    var missing: usize = 0;
    for (t.recipes) |r| for (r.source) |s| switch (s) {
        .tarball => |tb| {
            if (seen.contains(tb.sha256)) continue;
            try seen.put(tb.sha256, {});
            const path = try std.fmt.allocPrint(arena, "cache/sources/{s}", .{tb.sha256});
            const src = try std.fs.path.join(arena, &.{ opts.root, path });
            if (Dir.cwd().statFile(io, src, .{})) |st| {
                try items.append(arena, .{ .path = path, .src = src, .size = st.size, .sha = tb.sha256 });
            } else |_| {
                missing += 1;
                say("note: {s}: {s} is not fetched (dkbuild fetch {s})\n", .{ r.name, tb.url, r.name });
            }
        },
        .git => {},
    };
    if (missing > 0) say("note: {d} source(s) not in the cache are not on the discs\n", .{missing});
    for (source_stores) |s| try walkInto(arena, io, items, opts.root, try std.fmt.allocPrint(arena, "cache/{s}", .{s}));

    // The tree as git has it: the committed state (HEAD and every branch).
    const bundle = try std.fmt.allocPrint(arena, "{s}/dkbuild.bundle", .{work_rel});
    const res = std.process.run(arena, io, .{ .argv = &.{ "git", "-C", opts.root, "bundle", "create", try absFrom(arena, io, bundle), "--all" } }) catch |err| {
        say("error: cannot run git: {s}\n", .{@errorName(err)});
        return error.PrepareFailed;
    };
    const git_ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!git_ok) {
        say("error: git bundle failed: {s}\n", .{res.stderr});
        return error.PrepareFailed;
    }
    const status = std.process.run(arena, io, .{ .argv = &.{ "git", "-C", opts.root, "status", "--porcelain", "--untracked-files=no" } }) catch null;
    if (status) |s| if (s.stdout.len > 0) say("note: the tree has uncommitted changes; the bundle holds only what is committed\n", .{});
    try addFile(arena, io, items, "dkbuild.bundle", bundle, null);

    const iso = try std.fs.path.join(arena, &.{ opts.root, "dkrescue.iso" });
    if (Dir.cwd().statFile(io, iso, .{})) |_| {
        try addFile(arena, io, items, "dkrescue.iso", iso, null);
    } else |_| say("note: no dkrescue.iso in the tree: the discs have no build machine image\n", .{});
}

fn absFrom(arena: Allocator, io: std.Io, rel: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(rel) orelse ".";
    const base = try Dir.cwd().realPathFileAlloc(io, dir, arena);
    return std.fs.path.join(arena, &.{ base, std.fs.path.basename(rel) });
}

/// sha256 of each piece and of each cut file as a whole, reading every file
/// once. `pieces` are in item order.
fn hashAll(arena: Allocator, io: std.Io, items: []const Item, pieces: []const Piece, piece_sha: [][]const u8, item_sha: [][]const u8) !void {
    var total: u64 = 0;
    for (items) |it| total += it.size;
    var done: u64 = 0;
    var next_report: u64 = 0;
    var k: usize = 0;
    var buf: [256 * 1024]u8 = undefined;
    for (items, 0..) |it, i| {
        const first = k;
        while (k < pieces.len and pieces[k].item == i) k += 1;
        const mine = pieces[first..k];
        if (it.link != null) {
            item_sha[i] = "-";
            for (first..k) |j| piece_sha[j] = "-";
            continue;
        }
        if (it.sha != null and mine.len == 1) {
            item_sha[i] = it.sha.?;
            piece_sha[first] = it.sha.?;
            done += it.size;
            continue;
        }
        const file = Dir.cwd().openFile(io, it.src, .{}) catch |err| {
            say("error: {s}: {s}\n", .{ it.src, @errorName(err) });
            return error.PrepareFailed;
        };
        defer file.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        var rdr = file.reader(io, &rbuf);
        var whole = Sha256.init(.{});
        for (mine, first..) |p, j| {
            var part = Sha256.init(.{});
            var left = p.len;
            while (left > 0) {
                const want: usize = @intCast(@min(left, buf.len));
                const n = try rdr.interface.readSliceShort(buf[0..want]);
                if (n == 0) {
                    say("error: {s} changed while it was read (shorter than {d} bytes)\n", .{ it.src, it.size });
                    return error.PrepareFailed;
                }
                part.update(buf[0..n]);
                whole.update(buf[0..n]);
                left -= n;
            }
            piece_sha[j] = try arena.dupe(u8, &std.fmt.bytesToHex(part.finalResult(), .lower));
        }
        item_sha[i] = try arena.dupe(u8, &std.fmt.bytesToHex(whole.finalResult(), .lower));
        done += it.size;
        if (done >= next_report) {
            say("    checksums: {d} of {d} MiB\n", .{ done >> 20, total >> 20 });
            next_report = done + (2 << 30);
        }
    }
}

const import_sh = @embedFile("discs-import.sh");

pub fn make(arena: Allocator, io: std.Io, t: tree.Tree, set: Set, opts: Options) !void {
    const out_final = try std.fs.path.join(arena, &.{ opts.root, "out", set.name });
    const out_rel = try std.fs.path.join(arena, &.{ opts.root, "out", try std.fmt.allocPrint(arena, ".{s}.new", .{set.name}) });
    const work_rel = try std.fs.path.join(arena, &.{ opts.root, "work", try std.fmt.allocPrint(arena, "discs-{s}", .{set.name}) });
    for ([_][]const u8{ out_rel, work_rel }) |d| {
        _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", d } }) catch {};
        Dir.cwd().deleteTree(io, d) catch {};
        Dir.cwd().createDirPath(io, d) catch return error.PrepareFailed;
    }
    defer {
        _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", work_rel } }) catch {};
        Dir.cwd().deleteTree(io, work_rel) catch {};
    }

    // The key signs the index (repo) and the MANIFEST; it is only ever
    // bound into the sandbox, never copied.
    const have_key = opts.key.len > 0 and if (Dir.cwd().statFile(io, opts.key, .{})) |_| true else |_| false;
    if (set.kind == .repo and !have_key) {
        say("error: signing key {s} not found: the repository index must be signed\n", .{opts.key});
        return error.PrepareFailed;
    }
    const keys_rel = try std.fs.path.join(arena, &.{ opts.root, "keys" });
    var pubs: std.ArrayList([]const u8) = .empty;
    {
        var d = Dir.cwd().openDir(io, keys_rel, .{ .iterate = true }) catch {
            say("error: {s} not found\n", .{keys_rel});
            return error.PrepareFailed;
        };
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".pub")) try pubs.append(arena, try arena.dupe(u8, e.name));
    }
    if (pubs.items.len == 0) {
        say("error: no public key (*.pub) in {s}\n", .{keys_rel});
        return error.PrepareFailed;
    }

    say("==> discs {s} ({s}, {s})\n", .{ set.name, @tagName(set.kind), set.media });
    var items: std.ArrayList(Item) = .empty;
    switch (set.kind) {
        .repo => try repoItems(arena, io, t, set, opts.root, &items),
        .source => try sourceItems(arena, io, t, opts, work_rel, &items),
    }
    if (items.items.len == 0) {
        say("error: nothing to put on the discs\n", .{});
        return error.PrepareFailed;
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    var total: u64 = 0;
    for (items.items) |it| {
        if (badPath(it.path) or (it.link != null and badPath(it.link.?))) {
            say("error: {s}: tabs, newlines, quotes and backslashes cannot go in the MANIFEST\n", .{it.path});
            return error.PrepareFailed;
        }
        // Never a private key, whatever a store holds.
        if (std.mem.endsWith(u8, it.path, ".rsa") or std.mem.indexOf(u8, it.path, "signing.") != null and !std.mem.endsWith(u8, it.path, ".pub")) {
            say("error: {s} looks like a private key; it does not go on a disc\n", .{it.path});
            return error.PrepareFailed;
        }
        total += it.size;
    }

    // Every disc also carries the MANIFEST (about 200 bytes a line), the
    // index, keys, README and import.sh, and the file system's own tables.
    const cap = capacity(set.media).?;
    const per_disc: u64 = (64 << 20) + items.items.len * 200 + (if (set.kind == .repo) items.items.len * 2048 else 0);
    const usable: u64 = if (cap == std.math.maxInt(u64)) cap else blk: {
        const after = cap / 100 * 98;
        if (after <= per_disc + 2 * min_part) {
            say("error: {s} is too small for this set's MANIFEST and index\n", .{set.media});
            return error.PrepareFailed;
        }
        break :blk after - per_disc;
    };
    const sizes = try arena.alloc(u64, items.items.len);
    for (items.items, sizes) |it, *s| s.* = it.size;
    const pieces = try plan(arena, sizes, usable);
    const discs = pieces[pieces.len - 1].disc;
    say("    {d} file(s), {d} MiB, on {d} disc(s)\n", .{ items.items.len, total >> 20, discs });

    const piece_sha = try arena.alloc([]const u8, pieces.len);
    const item_sha = try arena.alloc([]const u8, items.items.len);
    try hashAll(arena, io, items.items, pieces, piece_sha, item_sha);

    const set_id = blk: {
        const res = std.process.run(arena, io, .{ .argv = &.{ "date", "-u", "+%Y%m%d-%H%M" } }) catch break :blk set.name;
        break :blk try std.fmt.allocPrint(arena, "{s}-{s}", .{ set.name, std.mem.trim(u8, res.stdout, " \n") });
    };

    // MANIFEST
    var m: std.ArrayList(u8) = .empty;
    try m.print(arena, "# dkbuild disc set {s}: kind {s}, arch {s}, {d} disc(s) ({s})\n", .{ set_id, @tagName(set.kind), set.arch, discs, set.media });
    try m.print(arena, "# F sha256 size disc path | S sha256 size - path parts | P sha256 size disc part | L - 0 disc path target (disc 0: every disc)\n", .{});
    for (pieces, piece_sha) |p, ps| {
        const it = items.items[p.item];
        if (it.link) |target| {
            try m.print(arena, "L\t-\t0\t{d}\t{s}\t{s}\n", .{ p.disc, it.path, target });
        } else if (p.parts == 0) {
            try m.print(arena, "F\t{s}\t{d}\t{d}\t{s}\n", .{ ps, p.len, p.disc, it.path });
        } else {
            if (p.part == 1) try m.print(arena, "S\t{s}\t{d}\t-\t{s}\t{d}\n", .{ item_sha[p.item], it.size, it.path, p.parts });
            try m.print(arena, "P\t{s}\t{d}\t{d}\t{s}.dkpart.{d:0>3}\n", .{ ps, p.len, p.disc, it.path, p.part });
        }
    }
    const work_abs = try Dir.cwd().realPathFileAlloc(io, work_rel, arena);
    try writeWork(arena, io, work_rel, "MANIFEST", m.items);
    try writeWork(arena, io, work_rel, "import.sh", import_sh);
    try writeWork(arena, io, work_rel, "README.txt", try readme(arena, set, set_id, discs));

    // One xorriso command file per disc.
    const label_of = struct {
        fn f(a: Allocator, s: Set, k: u32, n: u32) ![]const u8 {
            return if (n == 1) a.dupe(u8, s.label) else std.fmt.allocPrint(a, "{s}_{d}", .{ s.label, k });
        }
    }.f;
    var isos: std.ArrayList([]const u8) = .empty;
    var k: u32 = 1;
    var pi: usize = 0;
    while (k <= discs) : (k += 1) {
        const iso = if (discs == 1) try std.fmt.allocPrint(arena, "{s}.iso", .{set.name}) else try std.fmt.allocPrint(arena, "{s}-{d:0>2}-of-{d:0>2}.iso", .{ set.name, k, discs });
        try isos.append(arena, iso);
        var x: std.ArrayList(u8) = .empty;
        try x.print(arena, "-report_about WARNING\n-follow off\n-outdev 'stdio:/out/{s}'\n-volid '{s}'\n-compliance iso_9660_level=3\n-joliet off\n-rockridge on\n", .{ iso, try label_of(arena, set, k, discs) });
        for ([_][]const u8{ "MANIFEST", "README.txt", "import.sh" }) |f| try x.print(arena, "-map '/work/{s}' '/{s}'\n", .{ f, f });
        if (have_key) try x.print(arena, "-map '/work/MANIFEST.sig' '/MANIFEST.sig'\n", .{});
        try writeWork(arena, io, work_rel, try std.fmt.allocPrint(arena, "DISC-{d}", .{k}), try std.fmt.allocPrint(arena, "{s} {d} {d} {s} {s}\n", .{ set_id, k, discs, @tagName(set.kind), set.arch }));
        try x.print(arena, "-map '/work/DISC-{d}' '/DISC'\n", .{k});
        for (pubs.items) |p| try x.print(arena, "-map '/dkkeys/{s}' '/keys/{s}'\n", .{ p, p });
        if (set.kind == .repo) try x.print(arena, "-map '/work/Packages.adb' '/data/apks/{s}/Packages.adb'\n", .{set.arch});
        while (pi < pieces.len and pieces[pi].disc == k) : (pi += 1) {
            const p = pieces[pi];
            const it = items.items[p.item];
            const src = if (std.mem.startsWith(u8, it.src, work_rel)) try std.fmt.allocPrint(arena, "/work{s}", .{it.src[work_rel.len..]}) else try std.fmt.allocPrint(arena, "/tree/{s}", .{relTo(opts.root, it.src)});
            if (p.parts == 0) {
                try x.print(arena, "-map '{s}' '/data/{s}'\n", .{ src, it.path });
            } else {
                try x.print(arena, "-cut_out '{s}' {d} {d} '/data/{s}.dkpart.{d:0>3}'\n", .{ src, p.offset, p.len, it.path, p.part });
            }
        }
        try x.print(arena, "-commit\n-end\n", .{});
        try writeWork(arena, io, work_rel, try std.fmt.allocPrint(arena, "disc-{d}.xorriso", .{k}), x.items);
    }

    // In the sandbox: apk (the index), openssl (the signature), xorriso.
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(arena, "set -eu\n");
    if (set.kind == .repo) {
        // One call with every package (mkndx writes the index of what it is given).
        var list: std.ArrayList(u8) = .empty;
        for (items.items) |it| try list.print(arena, "/tree/{s}\n", .{relTo(opts.root, it.src)});
        try writeWork(arena, io, work_rel, "apks.list", list.items);
        try s.appendSlice(arena, "echo '==> index'\n/usr/bin/apk --keys-dir /dkkeys mkndx --sign-key /dkkey --output /work/Packages.adb $(cat /work/apks.list)\n");
        try s.print(arena, "printf 'F\\t%s\\t%s\\t0\\t%s\\n' \"$(sha256sum /work/Packages.adb | cut -d' ' -f1)\" \"$(stat -c %s /work/Packages.adb)\" 'apks/{s}/Packages.adb' >> /work/MANIFEST\n", .{set.arch});
    }
    if (have_key) try s.appendSlice(arena, "openssl dgst -sha256 -sign /dkkey -out /work/MANIFEST.sig /work/MANIFEST\n");
    k = 1;
    while (k <= discs) : (k += 1) try s.print(arena, "echo '==> disc {d} of {d}: {s}'\nxorriso -no_rc -options_from_file /work/disc-{d}.xorriso\n", .{ k, discs, isos.items[k - 1], k });
    try s.appendSlice(arena, "cd /out && sha256sum *.iso > SHA256SUMS\ncp /work/MANIFEST /work/README.txt /work/import.sh /out/\n");
    if (have_key) try s.appendSlice(arena, "cp /work/MANIFEST.sig /out/\n");
    try writeWork(arena, io, work_rel, "run.sh", s.items);

    // Every package goes on one apk mkndx command line (a split call would
    // make a partial index): well under the kernel's limit at this size.
    if (set.kind == .repo and items.items.len > 20000) {
        say("error: {d} packages: too many for one apk mkndx call\n", .{items.items.len});
        return error.PrepareFailed;
    }

    const lower = try std.fs.path.join(arena, &.{ opts.root, "rootfs", "dkrescue" });
    const lower_abs = Dir.cwd().realPathFileAlloc(io, lower, arena) catch {
        say("error: {s} is missing (dkbuild bootstrap-root)\n", .{lower});
        return error.PrepareFailed;
    };
    var sb: [3][]const u8 = undefined;
    for ([_][]const u8{ "upper", "ovl", "merged" }, &sb) |sub, *p| {
        const rel = try std.fs.path.join(arena, &.{ work_rel, sub });
        Dir.cwd().createDirPath(io, rel) catch return error.PrepareFailed;
        p.* = Dir.cwd().realPathFileAlloc(io, rel, arena) catch return error.PrepareFailed;
    }
    var binds: std.ArrayList(sandbox.Bind) = .empty;
    try binds.appendSlice(arena, &.{
        .{ .src = try Dir.cwd().realPathFileAlloc(io, opts.root, arena), .dst = "/tree", .read_only = true },
        .{ .src = try Dir.cwd().realPathFileAlloc(io, out_rel, arena), .dst = "/out" },
        .{ .src = work_abs, .dst = "/work" },
        .{ .src = try Dir.cwd().realPathFileAlloc(io, keys_rel, arena), .dst = "/dkkeys", .read_only = true },
    });
    if (have_key) try binds.append(arena, .{ .src = try Dir.cwd().realPathFileAlloc(io, opts.key, arena), .dst = "/dkkey", .read_only = true });
    var log: std.ArrayList(u8) = .empty;
    const ok = sandbox.run(arena, io, .{
        .lower = lower_abs,
        .upper = sb[0],
        .work = sb[1],
        .merged = sb[2],
        .binds = binds.items,
        .env = &.{ "PATH=/usr/bin:/usr/sbin:/bin:/sbin", "HOME=/root" },
        .argv = &.{ "/usr/bin/sh", "/work/run.sh" },
    }, &log) catch false;
    sandbox.makeRemovable(io, sb[1]);
    if (!ok) {
        const logpath = try std.fmt.allocPrint(arena, "{s}-failed.log", .{out_final});
        Dir.cwd().writeFile(io, .{ .sub_path = logpath, .data = log.items }) catch {};
        _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", out_rel } }) catch {};
        Dir.cwd().deleteTree(io, out_rel) catch {};
        const tail_start = if (log.items.len > 2000) log.items.len - 2000 else 0;
        say("{s}\nerror: discs {s} failed; log: {s} (out/{s}/ is unchanged)\n", .{ log.items[tail_start..], set.name, logpath, set.name });
        return error.BuildFailed;
    }
    Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/discs.log", .{out_rel}), .data = log.items }) catch {};
    _ = std.process.run(arena, io, .{ .argv = &.{ "chmod", "-R", "u+rwX", out_final } }) catch {};
    Dir.cwd().deleteTree(io, out_final) catch {};
    Dir.cwd().rename(out_rel, Dir.cwd(), out_final, io) catch |err| {
        say("error: cannot move {s} to {s}: {s}\n", .{ out_rel, out_final, @errorName(err) });
        return error.BuildFailed;
    };
    Dir.cwd().deleteFile(io, try std.fmt.allocPrint(arena, "{s}-failed.log", .{out_final})) catch {};
    say("    made {d} disc image(s) in {s}/: {s}\n", .{ discs, out_final, try std.mem.join(arena, " ", isos.items) });
    say("    set {s}; SHA256SUMS, MANIFEST and README.txt beside them\n", .{set_id});
}

fn relTo(root: []const u8, p: []const u8) []const u8 {
    if (std.mem.startsWith(u8, p, root) and p.len > root.len and p[root.len] == '/') return p[root.len + 1 ..];
    if (std.mem.startsWith(u8, p, "./")) return p[2..];
    return p;
}

fn writeWork(arena: Allocator, io: std.Io, work_rel: []const u8, name: []const u8, data: []const u8) !void {
    const p = try std.fs.path.join(arena, &.{ work_rel, name });
    Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data }) catch |err| {
        say("error: cannot write {s}: {s}\n", .{ p, @errorName(err) });
        return error.PrepareFailed;
    };
}

fn readme(arena: Allocator, set: Set, set_id: []const u8, discs: u32) ![]const u8 {
    var r: std.ArrayList(u8) = .empty;
    const what = switch (set.kind) {
        .repo => "the FenrirOS package repository: every package, signed",
        .source => "the FenrirOS sources: every source tarball, the vendored\ndependencies, the dkbuild tree and the build machine image",
    };
    try r.print(arena,
        \\FenrirOS disc set {s}
        \\
        \\This is {s}
        \\({s}, {d} disc(s)).
        \\
    , .{ set_id, what, set.arch, discs });
    if (discs > 1) try r.print(arena,
        \\
        \\Copy every disc into one directory, in any order (each copy is checked):
        \\
        \\    sh /media/cdrom/import.sh /srv/fenriros
        \\
        \\import.sh says which discs are still missing; when all are in, the
        \\directory holds the complete set.
        \\
    , .{}) else try r.print(arena,
        \\
        \\Use it from the mounted image, or copy it (checked) to a disk with
        \\
        \\    sh /media/usb/import.sh /srv/fenriros
        \\
    , .{});
    switch (set.kind) {
        .repo => try r.print(arena,
            \\
            \\As a repository: add this line to /etc/apk/repositories
            \\
            \\    /srv/fenriros/apks/{0s}/Packages.adb
            \\
            \\(or, using the one-image set where it is mounted,
            \\/media/usb/data/apks/{0s}/Packages.adb), then `apk update`; a newer
            \\set copied over the same directory brings updates (`apk upgrade`).
            \\A FenrirOS system trusts the key already; elsewhere, copy keys/*.pub
            \\to /etc/apk/keys/.
            \\
        , .{set.arch}),
        .source => try r.print(arena,
            \\
            \\To rebuild FenrirOS without the network:
            \\
            \\    git clone /srv/fenriros/dkbuild.bundle dkbuild
            \\    mv /srv/fenriros/cache dkbuild/cache
            \\    cd dkbuild && zig build
            \\    ./zig-out/bin/dkbuild bootstrap-root /srv/fenriros/dkrescue.iso
            \\
            \\The repository's signing key is not here; make a new one (dkbuild
            \\doctor) or restore yours from its own backup.
            \\
        , .{}),
    }
    try r.print(arena,
        \\
        \\MANIFEST lists every file with its sha256 and disc; MANIFEST.sig is
        \\its signature with the repository key (keys/*.pub), which import.sh
        \\checks when openssl is installed.
        \\
    , .{});
    return r.items;
}

test "plan fills discs in order and cuts large files" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const mib: u64 = 1 << 20;
    // 300 MiB per disc: 100 + 150 fit; 200 is cut (50 left on disc 1 is too
    // little to cut into, so it starts disc 2); 500 spans discs 2-4.
    const ps = try plan(a, &.{ 100 * mib, 150 * mib, 200 * mib, 500 * mib, 1 }, 300 * mib);
    try std.testing.expectEqual(@as(u32, 1), ps[0].disc);
    try std.testing.expectEqual(@as(u32, 1), ps[1].disc);
    try std.testing.expectEqual(@as(u32, 2), ps[2].disc);
    try std.testing.expectEqual(@as(u32, 0), ps[2].parts);
    // the 500 MiB file: the rest of disc 2, then disc 3, then disc 4
    try std.testing.expectEqual(@as(u32, 3), ps[3].parts);
    try std.testing.expectEqual(@as(u32, 2), ps[3].disc);
    try std.testing.expectEqual(@as(u32, 4), ps[5].disc);
    var sum: u64 = 0;
    for (ps[3..6]) |p| sum += p.len;
    try std.testing.expectEqual(500 * mib, sum);
    try std.testing.expectEqual(ps[3].len, ps[4].offset);
    // one image: never cut
    const one = try plan(a, &.{ 100 * mib, 50000 * mib }, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u32, 1), one[1].disc);
    try std.testing.expectEqual(@as(u32, 0), one[1].parts);
}

test "parse a set" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var diag: Diagnostic = .{};
    const s = try parse(st.allocator(), "name = \"fenriros-repo\"\nkind = \"repo\"\nmedia = \"bd25\"\n", &diag);
    try std.testing.expectEqual(Kind.repo, s.kind);
    try std.testing.expectEqualStrings("FENRIROS_REPO", s.label);
    try std.testing.expectError(error.InvalidSet, parse(st.allocator(), "name = \"x\"\nkind = \"repo\"\nmedia = \"floppy\"\n", &diag));
}

test "apkName" {
    try std.testing.expectEqualStrings("gvfs-backends", apkName("gvfs-backends-1.60.0-r1.apk").?);
    try std.testing.expectEqualStrings("openssh", apkName("openssh-10.6_p2-r4.apk").?);
}
