//! Console output with color: dkbuild's progress lines are colored by what
//! they report (built, failed, skipped, ...), on a terminal or with
//! `--color=always`, never with `--color=never` or NO_COLOR set.

const std = @import("std");

pub var color = false;

/// Decide from `--color=<auto|always|never>` (null: auto) and the environment.
pub fn setup(io: std.Io, mode: ?[]const u8, no_color: bool) void {
    const m = mode orelse "auto";
    if (std.mem.eql(u8, m, "always")) {
        color = true;
    } else if (std.mem.eql(u8, m, "never") or no_color) {
        color = false;
    } else {
        color = std.Io.File.stderr().isTty(io) catch false;
    }
}

const reset = "\x1b[0m";

fn styleOf(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " ");
    if (std.mem.startsWith(u8, t, "error:") or std.mem.indexOf(u8, line, " failed;") != null or std.mem.endsWith(u8, line, " failed") or
        (std.mem.indexOf(u8, t, " failed:") != null and t.len > 0 and std.ascii.isDigit(t[0]))) return "\x1b[1;31m";
    if (std.mem.startsWith(u8, t, "built ")) return "\x1b[32m";
    if (std.mem.startsWith(u8, t, "rebuilt ")) return "\x1b[2;32m";
    if (std.mem.indexOf(u8, line, ": skipped") != null or (t.len > 0 and std.ascii.isDigit(t[0]) and std.mem.indexOf(u8, t, " skipped:") != null)) return "\x1b[33m";
    if (std.mem.indexOf(u8, line, "came out different") != null or std.mem.indexOf(u8, line, "without a release bump") != null) return "\x1b[35m";
    if (std.mem.startsWith(u8, t, "note:") or std.mem.startsWith(u8, t, "warning:")) return "\x1b[2;33m";
    if (std.mem.startsWith(u8, t, "==> ") and std.mem.indexOf(u8, line, ": up to date") != null) return "\x1b[2m";
    if (std.mem.startsWith(u8, t, "==> ")) return "\x1b[1m";
    if (std.mem.startsWith(u8, t, "--> ")) return "\x1b[36m";
    if (std.mem.startsWith(u8, t, "summary:")) return "\x1b[1m";
    return null;
}

/// Write `text` to stderr, coloring each line by what it says.
pub fn emit(text: []const u8) void {
    if (!color) {
        std.debug.print("{s}", .{text});
        return;
    }
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0..i] else rest;
        const tail = if (nl != null) "\n" else "";
        if (styleOf(line)) |s| std.debug.print("{s}{s}{s}{s}", .{ s, line, reset, tail }) else std.debug.print("{s}{s}", .{ line, tail });
        rest = if (nl) |i| rest[i + 1 ..] else rest[rest.len..];
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch {
        const big = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return std.debug.print(fmt, args);
        defer std.heap.smp_allocator.free(big);
        return emit(big);
    };
    emit(text);
}

test "styleOf" {
    try std.testing.expect(styleOf("    built zlib-1-r1; log: x") != null);
    try std.testing.expect(styleOf("error: zlib-1-r1 failed; log: x") != null);
    try std.testing.expect(styleOf("==> foo: skipped, a package it needs failed") != null);
    try std.testing.expect(styleOf("    building") == null);
}
