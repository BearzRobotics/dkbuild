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
            const tmp = try std.fmt.allocPrint(arena, "{s}.part", .{final});
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
    .{ "electron", @embedFile("snapshot-electron.sh") },
    .{ "dotnet", @embedFile("snapshot-dotnet.sh") },
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
    const dir = try std.fs.path.join(arena, &.{ cache, "snapshots" });
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    const adir = std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot resolve {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    const sh_path = try std.fmt.allocPrint(arena, "{s}/snapshot-{s}.sh", .{ adir, kind });
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
    try argv.appendSlice(arena, &.{ "sh", "-c", "log=$1; shift; exec sh \"$@\" > \"$log\" 2>&1", "sh", log, sh_path, atmp, work });
    try argv.appendSlice(arena, args.items);
    const res = std.process.run(arena, io, .{ .argv = argv.items }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot run the {s} snapshot: {s}", .{ kind, @errorName(err) });
        return error.DownloadFailed;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
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
    \\top=$(ls -d "$t"/src/*/ | head -n1)
    \\
;

/// For recipes with the `godeps` option: download the modules the source
/// needs into the shared module cache (cache/gomod) with the `go` on the
/// host's PATH (GOTOOLCHAIN=auto fetches the Go version the module asks for),
/// and list them. The build uses the cache read-only, with GOPROXY=off.
pub fn fetchGoDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) Error!Status {
    const out_path = try goDepsPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tmp = try std.fmt.allocPrint(arena, "{s}/godeps/tmp-{s}", .{ cache, tarball_sha256 });
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const old = try std.fmt.allocPrint(arena, "{s}/godeps/{s}.tar", .{ cache, tarball_sha256 });
    const script = try std.fmt.allocPrint(arena, dep_prologue ++ dep_unpack ++
        \\export GOMODCACHE="$cache/gomod" GOPATH="$t/gopath" GOCACHE="$t/gocache" GOTOOLCHAIN=auto GOFLAGS=-mod=mod
        \\( cd "$top" && timeout 1800 go mod download && go list -m -f '{{{{.Path}}}}@{{{{.Version}}}}' all ) > "$t/list"
        \\mv "$t/list" '{3s}.part'; mv '{3s}.part' '{3s}'
        \\rm -f '{4s}'
        \\chmod -R u+w "$t"; rm -rf "$t"
    , .{ tmp, cache, tarball, out_path, old });
    return runDepScript(arena, io, cache, "godeps", script, "Go module (needs `go` on PATH)", message);
}

/// For recipes with the `cargodeps` option: `cargo vendor` the source's crates
/// (the `cargo` on the host's PATH, with the shared cache/cargo-home), move
/// each crate into cache/crates unless it is there already, and keep the list
/// and the `.cargo/config.toml` that points cargo at `vendor/` (the source's
/// own config, if it has one, with the vendoring lines added). A tarball made
/// by an older dkbuild (<sha256>.tar) is converted without the network.
pub fn fetchCargoDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) Error!Status {
    const out_path = try cargoDepsPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tmp = try std.fmt.allocPrint(arena, "{s}/cargodeps/tmp-{s}", .{ cache, tarball_sha256 });
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const old = try std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.tar", .{ cache, tarball_sha256 });
    const config = try std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.config.toml", .{ cache, tarball_sha256 });
    const script = try std.fmt.allocPrint(arena, dep_prologue ++
        \\if [ -f '{4s}' ]; then
        \\    top="$t/src/old"; mkdir -p "$top"; tar -xf '{4s}' -C "$top"
        \\    cp "$top/.cargo/config.toml" "$t/config.toml"
        \\else
        \\
    ++ dep_unpack ++
        \\    export CARGO_HOME="$cache/cargo-home"
        \\    # the Cargo project at the top, or else the first one below it (hashcat's
        \\    # is in Rust/generic_hash); vendor/ and .cargo/ stay at the top, where
        \\    # cargo finds them from any directory under it
        \\    m=Cargo.toml
        \\    [ -f "$top/Cargo.lock" ] || m=$(cd "$top" && find . -name Cargo.lock -not -path './vendor/*' | sort | head -n1 | sed 's|Cargo.lock$|Cargo.toml|')
        \\    ( cd "$top" && RUSTC_BOOTSTRAP=1 timeout 1800 cargo vendor --locked --manifest-path "${{m:-Cargo.toml}}" vendor > "$t/vendor.toml" )
        \\    {{ if [ -f "$top/.cargo/config.toml" ]; then cat "$top/.cargo/config.toml"; printf '\n'; fi; cat "$t/vendor.toml"; }} > "$t/config.toml"
        \\fi
        \\store="$cache/crates"; mkdir -p "$store"
        \\: > "$t/list"
        \\for d in "$top"/vendor/*/; do
        \\    n=$(basename "$d")
        \\    k="$n-$(sha256sum "$d/.cargo-checksum.json" | cut -c1-16)"
        \\    [ -e "$store/$k" ] || mv -T "$d" "$store/$k" 2>/dev/null || [ -e "$store/$k" ]
        \\    echo "$n $k" >> "$t/list"
        \\done
        \\mv "$t/config.toml" '{5s}'
        \\mv "$t/list" '{3s}.part'; mv '{3s}.part' '{3s}'
        \\rm -f '{4s}'
        \\rm -rf "$t"
    , .{ tmp, cache, tarball, out_path, old, config });
    return runDepScript(arena, io, cache, "cargodeps", script, "crate (needs `cargo` on PATH)", message);
}

/// For recipes with the `zigdeps` option: `zig build --fetch=all` (the `zig`
/// on the host's PATH, which must be a version the project accepts; the
/// shared cache/zig-global), then move each package of zig-pkg/ into
/// cache/zigpkg unless it is there already, and list them. The build lays
/// zig-pkg/ back for `zig build --system zig-pkg` (SPEC 9.4 item 3). A tarball
/// made by an older dkbuild (<sha256>.tar) is converted without the network.
pub fn fetchZigDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) Error!Status {
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
        \\    ( cd "$top" && ZIG_GLOBAL_CACHE_DIR="$cache/zig-global" timeout 1800 zig build --fetch=all )
        \\fi
        \\store="$cache/zigpkg"; mkdir -p "$store"
        \\: > "$t/list"
        \\if [ -d "$top/zig-pkg" ]; then
        \\    for d in "$top"/zig-pkg/*/; do
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
