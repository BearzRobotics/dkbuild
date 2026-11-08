//! Source fetching (SPEC.md 5.3, 7 step 1).
//!
//! Tarballs are downloaded once into `<cache>/sources/<sha256>` and the
//! checksum is verified before the file gets that name. `git|` sources are
//! not handled yet.

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
            const got = hashFile(io, tmp) catch |err| {
                message.* = try std.fmt.allocPrint(arena, "cannot read downloaded file: {s}", .{@errorName(err)});
                return error.DownloadFailed;
            };
            if (!std.mem.eql(u8, &got, t.sha256)) {
                message.* = try std.fmt.allocPrint(arena, "checksum mismatch for {s}: recipe says {s}, got {s}", .{ t.url, t.sha256, &got });
                std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
                return error.BadChecksum;
            }
            try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), final, io);
            return .downloaded;
        },
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

/// Where the vendored Go modules of a source tarball are cached.
pub fn goDepsPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/godeps/{s}.tar", .{ cache, tarball_sha256 });
}

/// For recipes with the `godeps` option: `go mod vendor` in the source tarball
/// (needs the network, so it runs on the host, never in the sandbox) and keep
/// the result as `cache/godeps/<sha256>.tar`, holding the `vendor/` directory
/// that `go build -mod=vendor` reads offline. Uses the `go` on the host's PATH;
/// GOTOOLCHAIN=auto lets it fetch the Go version the module asks for.
pub fn fetchGoDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) Error!Status {
    const out_path = try goDepsPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const dir = try std.fmt.allocPrint(arena, "{s}/godeps", .{cache});
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, tarball_sha256 });
    // The tarball has one top-level directory; the vendoring runs inside it.
    // The module cache is thrown away afterwards (Go makes it read-only).
    const script = try std.fmt.allocPrint(arena,
        \\set -e
        \\rm -rf '{0s}'; mkdir -p '{0s}/src'
        \\tar -xf '{1s}' -C '{0s}/src'
        \\top=$(ls -d '{0s}'/src/*/ | head -n1)
        \\t=$(cd '{0s}' && pwd)
        \\export GOPATH="$t/gopath" GOMODCACHE="$t/gopath/mod" GOCACHE="$t/gocache" GOTOOLCHAIN=auto GOFLAGS=-mod=mod
        \\( cd "$top" && timeout 1800 go mod vendor )
        \\tar -cf '{2s}.part' -C "$top" vendor
        \\mv '{2s}.part' '{2s}'
        \\chmod -R u+w '{0s}'; rm -rf '{0s}'
    , .{ tmp, tarball, out_path });
    const res = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", script } }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot run the Go module fetch: {s}", .{@errorName(err)});
        return error.DownloadFailed;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        message.* = try std.fmt.allocPrint(arena, "Go module fetch failed (needs `go` on PATH): {s}", .{std.mem.trim(u8, res.stderr, "\n ")});
        return error.DownloadFailed;
    }
    return .downloaded;
}

/// Where the vendored Rust crates of a source tarball are cached.
pub fn cargoDepsPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/cargodeps/{s}.tar", .{ cache, tarball_sha256 });
}

/// For recipes with the `cargodeps` option: `cargo vendor` in the source
/// tarball (needs the network, so it runs on the host, never in the sandbox)
/// and keep the result as `cache/cargodeps/<sha256>.tar`: the `vendor/`
/// directory and a `.cargo/config.toml` that points cargo at it (the source's
/// own config, if it has one, with the vendoring lines added), so an offline
/// `cargo build` finds every crate. Uses the `cargo` on the host's PATH.
pub fn fetchCargoDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) Error!Status {
    const out_path = try cargoDepsPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const dir = try std.fmt.allocPrint(arena, "{s}/cargodeps", .{cache});
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, tarball_sha256 });
    const script = try std.fmt.allocPrint(arena,
        \\set -e
        \\rm -rf '{0s}'; mkdir -p '{0s}/src'
        \\tar -xf '{1s}' -C '{0s}/src'
        \\top=$(ls -d '{0s}'/src/*/ | head -n1)
        \\t=$(cd '{0s}' && pwd)
        \\export CARGO_HOME="$t/cargo-home"
        \\( cd "$top" && timeout 1800 cargo vendor --locked vendor > "$t/vendor.toml" )
        \\mkdir -p "$top/.cargo"
        \\[ -f "$top/.cargo/config.toml" ] && printf '\n' >> "$top/.cargo/config.toml"
        \\cat "$t/vendor.toml" >> "$top/.cargo/config.toml"
        \\tar -cf '{2s}.part' -C "$top" vendor .cargo/config.toml
        \\mv '{2s}.part' '{2s}'
        \\rm -rf '{0s}'
    , .{ tmp, tarball, out_path });
    const res = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", script } }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot run the crate fetch: {s}", .{@errorName(err)});
        return error.DownloadFailed;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        message.* = try std.fmt.allocPrint(arena, "crate fetch failed (needs `cargo` on PATH): {s}", .{std.mem.trim(u8, res.stderr, "\n ")});
        return error.DownloadFailed;
    }
    return .downloaded;
}

/// Where the vendored Zig dependencies of a source tarball are cached.
pub fn zigDepsPath(arena: Allocator, cache: []const u8, tarball_sha256: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/zigdeps/{s}.tar", .{ cache, tarball_sha256 });
}

/// For recipes with the `zigdeps` option: fetch the Zig dependencies of the
/// source tarball (needs the network, so it runs on the host, never in the
/// sandbox) and keep them as `cache/zigdeps/<sha256>.tar`, holding the
/// `zig-pkg/` directory that `zig build --system zig-pkg` reads offline
/// (SPEC 9.4 item 3). Uses the `zig` on the host's PATH, which must be a
/// version the project accepts.
pub fn fetchZigDeps(arena: Allocator, io: std.Io, cache: []const u8, tarball_sha256: []const u8, message: *[]const u8) Error!Status {
    const out_path = try zigDepsPath(arena, cache, tarball_sha256);
    if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| return .cached else |_| {}
    const tarball = try cachePath(arena, cache, tarball_sha256);
    const dir = try std.fmt.allocPrint(arena, "{s}/zigdeps", .{cache});
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot create {s}: {s}", .{ dir, @errorName(err) });
        return error.DownloadFailed;
    };
    const tmp = try std.fmt.allocPrint(arena, "{s}/tmp-{s}", .{ dir, tarball_sha256 });
    // The tarball has one top-level directory; the fetch runs inside it.
    const script = try std.fmt.allocPrint(arena,
        \\set -e
        \\rm -rf '{0s}'; mkdir -p '{0s}/gc'
        \\tar -xf '{1s}' -C '{0s}'
        \\top=$(ls -d '{0s}'/*/ | grep -v '/gc/$' | head -n1)
        \\( cd "$top" && ZIG_GLOBAL_CACHE_DIR="$(pwd)/../gc" timeout 1800 zig build --fetch=all )
        \\tar -cf '{2s}.part' -C "$top" zig-pkg
        \\mv '{2s}.part' '{2s}'
        \\rm -rf '{0s}'
    , .{ tmp, tarball, out_path });
    const res = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", script } }) catch |err| {
        message.* = try std.fmt.allocPrint(arena, "cannot run the Zig dependency fetch: {s}", .{@errorName(err)});
        return error.DownloadFailed;
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        message.* = try std.fmt.allocPrint(arena, "Zig dependency fetch failed (needs `zig` on PATH): {s}", .{std.mem.trim(u8, res.stderr, "\n ")});
        return error.DownloadFailed;
    }
    return .downloaded;
}
