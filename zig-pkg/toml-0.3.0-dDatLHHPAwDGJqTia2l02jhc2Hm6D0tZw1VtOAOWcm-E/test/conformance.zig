//! Runs the decoder cases of the official TOML conformance suite,
//! https://github.com/toml-lang/toml-test, which is not vendored:
//!
//!   git clone https://github.com/toml-lang/toml-test
//!   zig build conformance -Dsuite=PATH/toml-test/tests
//!
//! For both TOML versions: every `invalid/` file must be rejected, and every
//! `valid/` file must decode to the values in its `.json` file, both when read
//! and after being written by this library and read again. This is not
//! toml-test's encoder mode: no other parser checks the written text.

const std = @import("std");
const toml = @import("toml");
const Json = std.json.Value;

const max_file = 1 << 24;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: conformance PATH/toml-test/tests\n", .{});
        std.process.exit(2);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{});
    defer dir.close(io);

    var failures: usize = 0;
    for ([_]struct { toml.Version, []const u8 }{
        .{ .v1_0, "files-toml-1.0.0" },
        .{ .v1_1, "files-toml-1.1.0" },
    }) |run| {
        const version = run[0];
        const list = try dir.readFileAlloc(io, run[1], gpa, .limited(max_file));
        defer gpa.free(list);
        var valid: usize = 0;
        var invalid: usize = 0;
        var names = std.mem.tokenizeAny(u8, list, "\r\n");
        while (names.next()) |name| {
            if (!std.mem.endsWith(u8, name, ".toml")) continue;
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const text = try dir.readFileAlloc(io, name, a, .limited(max_file));
            const options: toml.Options = .{ .version = version };

            if (std.mem.startsWith(u8, name, "invalid/")) {
                invalid += 1;
                if (toml.Document.parse(a, text, options, null)) |_| {
                    failures += 1;
                    std.debug.print("{t}: accepted {s}\n", .{ version, name });
                } else |_| {}
                continue;
            }

            valid += 1;
            const json_name = try std.mem.concat(a, u8, &.{ name[0 .. name.len - "toml".len], "json" });
            const json_text = try dir.readFileAlloc(io, json_name, a, .limited(max_file));
            const want = try std.json.parseFromSliceLeaky(Json, a, json_text, .{});
            checkValid(a, text, options, want) catch |e| {
                failures += 1;
                std.debug.print("{t}: {s}: {t}\n", .{ version, name, e });
            };
        }
        std.debug.print("TOML {t}: {d} valid, {d} invalid\n", .{ version, valid, invalid });
        if (valid == 0 or invalid == 0) return error.EmptySuite;
    }
    std.debug.print("failures: {d}\n", .{failures});
    if (failures != 0) std.process.exit(1);
}

/// `a` is an arena: nothing here is freed.
fn checkValid(a: std.mem.Allocator, text: []const u8, options: toml.Options, want: Json) !void {
    const doc = try toml.Document.parse(a, text, options, null);
    if (!try tableMatches(a, doc.root, want)) return error.DecodedValuesDiffer;
    const out = try doc.toOwnedString(a);
    const again = try toml.Document.parse(a, out, options, null);
    if (!try tableMatches(a, again.root, want)) return error.RewrittenValuesDiffer;
}

fn tableMatches(a: std.mem.Allocator, table: *const toml.Table, want: Json) !bool {
    if (want != .object or want.object.count() != table.count()) return false;
    for (table.entries.keys(), table.entries.values()) |k, v| {
        if (!try valueMatches(a, v, want.object.get(k) orelse return false)) return false;
    }
    return true;
}

fn valueMatches(a: std.mem.Allocator, v: toml.Value, want: Json) anyerror!bool {
    switch (v) {
        .table => |t| return tableMatches(a, t, want),
        .array => |arr| {
            if (want != .array or want.array.items.len != arr.items.items.len) return false;
            for (arr.items.items, want.array.items) |item, w| {
                if (!try valueMatches(a, item, w)) return false;
            }
            return true;
        },
        else => {},
    }
    // A scalar is `{"type": ..., "value": "..."}`.
    if (want != .object) return false;
    const kind = (want.object.get("type") orelse return false).string;
    const value = (want.object.get("value") orelse return false).string;
    return switch (v) {
        .string => |s| std.mem.eql(u8, kind, "string") and std.mem.eql(u8, s, value),
        .integer => |i| std.mem.eql(u8, kind, "integer") and i == try std.fmt.parseInt(i64, value, 10),
        .boolean => |b| std.mem.eql(u8, kind, "bool") and std.mem.eql(u8, if (b) "true" else "false", value),
        .float => |f| blk: {
            if (!std.mem.eql(u8, kind, "float")) break :blk false;
            const w = try std.fmt.parseFloat(f64, value);
            break :blk (std.math.isNan(f) and std.math.isNan(w)) or f == w;
        },
        .datetime => |d| blk: {
            const our_kind = if (d.date == null)
                "time-local"
            else if (d.time == null)
                "date-local"
            else if (d.offset_minutes == null)
                "datetime-local"
            else
                "datetime";
            if (!std.mem.eql(u8, kind, our_kind)) break :blk false;
            const got = try std.fmt.allocPrint(a, "{f}", .{d});
            break :blk std.mem.eql(u8, got, try canonicalDatetime(a, value));
        },
        .table, .array => unreachable,
    };
}

/// Rewrites an expected date-time into the spelling `Datetime.format` uses:
/// `T` and `Z` in capitals, `Z` for a zero offset, seconds always present and
/// no trailing zeros in the fraction.
fn canonicalDatetime(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const has_date = s.len >= 10 and s[4] == '-';
    if (has_date) {
        try out.appendSlice(a, s[0..10]);
        if (s.len == 10) return out.items;
        try out.append(a, 'T');
        i = 11;
    }
    try out.appendSlice(a, s[i..][0..5]); // HH:MM
    i += 5;
    if (i < s.len and s[i] == ':') {
        try out.appendSlice(a, s[i..][0..3]);
        i += 3;
    } else try out.appendSlice(a, ":00");
    if (i < s.len and s[i] == '.') {
        const start = i;
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        const fraction = std.mem.trimEnd(u8, s[start..i], "0");
        if (fraction.len > 1) try out.appendSlice(a, fraction);
    }
    const offset = s[i..];
    if (std.ascii.eqlIgnoreCase(offset, "z") or std.mem.eql(u8, offset, "+00:00") or std.mem.eql(u8, offset, "-00:00")) {
        try out.append(a, 'Z');
    } else try out.appendSlice(a, offset);
    return out.items;
}
