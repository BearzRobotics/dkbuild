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
