//! Ruby gems, vendored at fetch time (SPEC.md 7.4).
//!
//! The store, cache/gems/, holds each gem file once (<name>-<version>.gem, as
//! rubygems.org names them). At fetch time every Gemfile.lock in the source is
//! read, and each gem it locks is downloaded unless the store has it, checked
//! against the lockfile's CHECKSUMS (Bundler 2.6+) or else rubygems.org's
//! published sha256 for that version. A build gets the gems laid into
//! vendor/cache (links into the store), where `bundle install --local` finds
//! them with no network. The ruby-platform gem is used for every entry
//! (prebuilt platform gems are built for glibc). Nothing from a gem runs here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fetch = @import("fetch.zig");

pub fn listPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/gemdeps/{s}.list", .{ cache, tarball_sha256 });
}

pub const no_lockfile = "gems: the source has no Gemfile.lock";

const Gem = struct { name: []const u8, version: []const u8, sha256: ?[]const u8 = null };
/// A gem from a GIT section (GitHub only: its archive of the revision).
const GitGem = struct { name: []const u8, remote: []const u8, revision: []const u8 };

/// A platform suffix on a locked version (`1.16.5-x86_64-linux`): those are
/// prebuilt gems; the plain version is the source gem.
fn splitPlatform(v: []const u8) []const u8 {
    const dash = std.mem.indexOfScalar(u8, v, '-') orelse return v;
    const rest = v[dash + 1 ..];
    const plats = [_][]const u8{ "x86", "x64", "arm", "aarch64", "java", "universal", "mingw", "mswin", "darwin", "linux", "ruby", "riscv", "musl" };
    for (plats) |p| if (std.mem.startsWith(u8, rest, p)) return v[0..dash];
    return v;
}

/// The gems of one Gemfile.lock: the specs of its GEM sections (4-space
/// entries), with sha256 from CHECKSUMS when present. GIT sections are
/// reported; PATH sections are the source's own gems.
fn collect(arena: Allocator, text: []const u8, out: *std.ArrayList(Gem), gits: *std.ArrayList(GitGem)) !void {
    var section: []const u8 = "";
    var remote: []const u8 = "";
    var revision: []const u8 = "";
    var git_specs = false;
    var in_specs = false;
    var sums: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] != ' ') {
            section = line;
            in_specs = false;
            git_specs = false;
            continue;
        }
        if (std.mem.eql(u8, section, "GIT")) {
            const t = std.mem.trim(u8, line, " ");
            if (std.mem.startsWith(u8, t, "remote: ")) remote = t["remote: ".len..];
            if (std.mem.startsWith(u8, t, "revision: ")) revision = t["revision: ".len..];
            if (std.mem.eql(u8, t, "specs:")) git_specs = true;
            if (git_specs and line.len > 4 and std.mem.startsWith(u8, line, "    ") and line[4] != ' ') {
                const sp = std.mem.indexOf(u8, t, " (") orelse continue;
                try gits.append(arena, .{ .name = t[0..sp], .remote = remote, .revision = revision });
            }
            continue;
        }
        if (std.mem.eql(u8, section, "CHECKSUMS")) {
            // "  name (version[-platform]) sha256=hex"
            const t = std.mem.trim(u8, line, " ");
            const sp = std.mem.indexOf(u8, t, " (") orelse continue;
            const close = std.mem.indexOfScalarPos(u8, t, sp, ')') orelse continue;
            const key = try std.fmt.allocPrint(arena, "{s}-{s}", .{ t[0..sp], t[sp + 2 .. close] });
            if (std.mem.indexOf(u8, t[close..], "sha256=")) |i| {
                const hex = std.mem.trim(u8, t[close + i + 7 ..], " ,");
                if (hex.len >= 64) try sums.put(arena, key, hex[0..64]);
            }
            continue;
        }
        if (!std.mem.eql(u8, section, "GEM")) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line, " "), "specs:")) {
            in_specs = true;
            continue;
        }
        // a spec is indented by exactly four spaces (its dependencies by six)
        if (!in_specs or line.len < 5 or !std.mem.startsWith(u8, line, "    ") or line[4] == ' ') continue;
        const t = line[4..];
        const sp = std.mem.indexOf(u8, t, " (") orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, t, ')') orelse continue;
        try out.append(arena, .{ .name = t[0..sp], .version = splitPlatform(t[sp + 2 .. close]) });
    }
    for (out.items) |*g| if (g.sha256 == null) {
        g.sha256 = sums.get(try std.fmt.allocPrint(arena, "{s}-{s}", .{ g.name, g.version }));
    };
}

/// For recipes with the `gemdeps` option: every gem of every Gemfile.lock in
/// the source, downloaded into the store unless it is there, each checked.
pub fn fetchGemDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) fetch.Error!fetch.Status {
    const out_path = try listPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const dir = try std.fmt.allocPrint(arena, "{s}/gemdeps", .{cache});
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, tarball_sha256 });
    std.Io.Dir.cwd().createDirPath(io, tmp) catch return error.DownloadFailed;
    defer std.Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const tarball = try fetch.cachePath(arena, cache, tarball_sha256);
    const find = try std.fmt.allocPrint(arena, "set -e; mkdir -p '{0s}/src'; tar -xf '{1s}' -C '{0s}/src'; " ++
        "find '{0s}/src' -name Gemfile.lock -not -path '*/vendor/*' > '{0s}/locks'", .{ tmp, tarball });
    const r1 = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", find } }) catch return error.DownloadFailed;
    if (!(r1.term == .exited and r1.term.exited == 0)) {
        message.* = try std.fmt.allocPrint(arena, "gems: cannot unpack the source: {s}", .{std.mem.trim(u8, r1.stderr, "\n ")});
        return error.DownloadFailed;
    }
    const locks = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/locks", .{tmp}), arena, .limited(1 << 20)) catch return error.DownloadFailed;
    var gems: std.ArrayList(Gem) = .empty;
    var gits: std.ArrayList(GitGem) = .empty;
    var nlocks: usize = 0;
    var it = std.mem.tokenizeScalar(u8, locks, '\n');
    while (it.next()) |lp| {
        nlocks += 1;
        const text = std.Io.Dir.cwd().readFileAlloc(io, lp, arena, .limited(1 << 24)) catch return error.DownloadFailed;
        collect(arena, text, &gems, &gits) catch return error.DownloadFailed;
    }
    if (nlocks == 0) {
        message.* = no_lockfile;
        return error.DownloadFailed;
    }
    // Unique gems the store lacks; checksums the lockfile does not give come
    // from rubygems.org's API (fetched in parallel first).
    const store = try std.fmt.allocPrint(arena, "{s}/gems", .{cache});
    std.Io.Dir.cwd().createDirPath(io, store) catch return error.DownloadFailed;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var list: std.ArrayList(u8) = .empty;
    const Todo = struct { file: []const u8, url: []const u8, part: []const u8, api: []const u8, sha: ?[]const u8 };
    var todo: std.ArrayList(Todo) = .empty;
    for (gems.items) |g| {
        const file = try std.fmt.allocPrint(arena, "{s}-{s}.gem", .{ g.name, g.version });
        if (seen.contains(file)) continue;
        try seen.put(arena, file, {});
        try list.appendSlice(arena, file);
        try list.append(arena, '\n');
        if (std.Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ store, file }), .{})) |_| continue else |_| {}
        const n = todo.items.len;
        try todo.append(arena, .{
            .file = file,
            .url = try std.fmt.allocPrint(arena, "https://rubygems.org/gems/{s}", .{file}),
            .part = try std.fmt.allocPrint(arena, "{s}/dl-{d}", .{ tmp, n }),
            .api = try std.fmt.allocPrint(arena, "{s}/api-{d}", .{ tmp, n }),
            .sha = g.sha256,
        });
    }
    if (todo.items.len > 0) {
        var cfg: std.ArrayList(u8) = .empty;
        for (todo.items) |t| {
            try cfg.appendSlice(arena, try std.fmt.allocPrint(arena, "url = \"{s}\"\noutput = \"{s}\"\n", .{ t.url, t.part }));
            if (t.sha == null) {
                const nv = t.file[0 .. t.file.len - 4];
                const dash = std.mem.lastIndexOfScalar(u8, nv, '-').?;
                try cfg.appendSlice(arena, try std.fmt.allocPrint(arena, "url = \"https://rubygems.org/api/v2/rubygems/{s}/versions/{s}.json?platform=ruby\"\noutput = \"{s}\"\n", .{ nv[0..dash], nv[dash + 1 ..], t.api }));
            }
        }
        const cfgp = try std.fmt.allocPrint(arena, "{s}/curl.cfg", .{tmp});
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cfgp, .data = cfg.items }) catch return error.DownloadFailed;
        const r2 = std.process.run(arena, io, .{ .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "--retry-delay", "3", "--parallel", "--parallel-max", "12", "-K", cfgp } }) catch return error.DownloadFailed;
        if (!(r2.term == .exited and r2.term.exited == 0)) {
            message.* = try std.fmt.allocPrint(arena, "gems: downloads failed: {s}", .{std.mem.trim(u8, r2.stderr, "\n ")});
            return error.DownloadFailed;
        }
        for (todo.items) |t| {
            const want: []const u8 = t.sha orelse blk: {
                const js = std.Io.Dir.cwd().readFileAlloc(io, t.api, arena, .limited(1 << 20)) catch return error.DownloadFailed;
                const v = std.json.parseFromSliceLeaky(std.json.Value, arena, js, .{}) catch return error.DownloadFailed;
                const s = if (v == .object) v.object.get("sha") else null;
                if (s == null or s.? != .string) {
                    message.* = try std.fmt.allocPrint(arena, "gems: rubygems.org gives no checksum for {s}", .{t.file});
                    return error.DownloadFailed;
                }
                break :blk s.?.string;
            };
            const got = fetch.hashFile(io, t.part) catch return error.DownloadFailed;
            if (!std.mem.eql(u8, &got, want)) {
                message.* = try std.fmt.allocPrint(arena, "gems: {s} does not match its checksum", .{t.file});
                return error.BadChecksum;
            }
            std.Io.Dir.cwd().rename(t.part, std.Io.Dir.cwd(), try std.fs.path.join(arena, &.{ store, t.file }), io) catch return error.DownloadFailed;
        }
    }
    // Gems from git: GitHub's archive of the locked revision, kept in the
    // store as git-<name>-<revision>.tar.gz. GitHub publishes no checksum for
    // it: the first fetch records one (cache/gemsums/), later fetches must
    // match it. The list line is "<file> <name>-<revision[0..12]>": the store
    // file, then the directory Bundler looks for in vendor/cache.
    for (gits.items) |g| {
        const gh = "https://github.com/";
        if (!std.mem.startsWith(u8, g.remote, gh) or g.revision.len < 12) {
            message.* = try std.fmt.allocPrint(arena, "gems: {s} comes from {s}; only GitHub git gems are vendored", .{ g.name, g.remote });
            return error.DownloadFailed;
        }
        const repo = std.mem.trimEnd(u8, if (std.mem.endsWith(u8, g.remote, ".git")) g.remote[0 .. g.remote.len - 4] else g.remote, "/");
        const file = try std.fmt.allocPrint(arena, "git-{s}-{s}.tar.gz", .{ g.name, g.revision });
        const line = try std.fmt.allocPrint(arena, "{s} {s}-{s}\n", .{ file, g.name, g.revision[0..12] });
        if (std.mem.indexOf(u8, list.items, line) != null) continue;
        try list.appendSlice(arena, line);
        const full = try std.fs.path.join(arena, &.{ store, file });
        // the recorded checksum lives outside the store (prune cleans the store)
        const sums_dir = try std.fmt.allocPrint(arena, "{s}/gemsums", .{cache});
        std.Io.Dir.cwd().createDirPath(io, sums_dir) catch return error.DownloadFailed;
        const sumf = try std.fmt.allocPrint(arena, "{s}/{s}.sha256", .{ sums_dir, file });
        if (std.Io.Dir.cwd().access(io, full, .{})) |_| continue else |_| {}
        const part_g = try std.fmt.allocPrint(arena, "{s}/git-{s}", .{ tmp, g.name });
        const url = try std.fmt.allocPrint(arena, "{s}/archive/{s}.tar.gz", .{ repo, g.revision });
        const rg = std.process.run(arena, io, .{ .argv = &.{ "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4", "-o", part_g, url } }) catch return error.DownloadFailed;
        if (!(rg.term == .exited and rg.term.exited == 0)) {
            message.* = try std.fmt.allocPrint(arena, "gems: download of {s} failed: {s}", .{ url, std.mem.trim(u8, rg.stderr, "\n ") });
            return error.DownloadFailed;
        }
        const got = fetch.hashFile(io, part_g) catch return error.DownloadFailed;
        if (std.Io.Dir.cwd().readFileAlloc(io, sumf, arena, .limited(256))) |want| {
            if (!std.mem.eql(u8, &got, std.mem.trim(u8, want, "\n "))) {
                message.* = try std.fmt.allocPrint(arena, "gems: {s} differs from the archive first fetched", .{file});
                return error.BadChecksum;
            }
        } else |_| std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sumf, .data = &got }) catch return error.DownloadFailed;
        std.Io.Dir.cwd().rename(part_g, std.Io.Dir.cwd(), full, io) catch return error.DownloadFailed;
    }
    const part = try std.fmt.allocPrint(arena, "{s}.part", .{out_path});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = part, .data = list.items }) catch return error.DownloadFailed;
    std.Io.Dir.cwd().rename(part, std.Io.Dir.cwd(), out_path, io) catch return error.DownloadFailed;
    return .downloaded;
}

test "collect" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const lock =
        \\GIT
        \\  remote: https://github.com/rapid7/LicenseFinder
        \\  revision: 2b1aefcfd6d0745d17843050c1c89f973c1fa98c
        \\  specs:
        \\    license_finder (7.2.1)
        \\      bundler
        \\
        \\GEM
        \\  remote: https://rubygems.org/
        \\  specs:
        \\    nokogiri (1.16.5)
        \\      racc (~> 1.4)
        \\    nokogiri (1.16.5-x86_64-linux)
        \\    racc (1.8.1)
        \\
        \\PLATFORMS
        \\  ruby
        \\
        \\CHECKSUMS
        \\  racc (1.8.1) sha256=4a7f6929691dbec8b5209a0b373bc2614882b55fc5d2e447a21aaa691303d62f
        \\
    ;
    var out: std.ArrayList(Gem) = .empty;
    var gits: std.ArrayList(GitGem) = .empty;
    try collect(a.allocator(), lock, &out, &gits);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("1.16.5", out.items[1].version);
    try std.testing.expect(out.items[2].sha256 != null);
    try std.testing.expectEqual(@as(usize, 1), gits.items.len);
    try std.testing.expectEqualStrings("license_finder", gits.items[0].name);
}
