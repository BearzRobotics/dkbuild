//! Helpers shared by the test files.

const std = @import("std");
const toml = @import("root.zig");

/// Fails unless the two trees hold the same keys, in any order, with the same
/// types and values. Order is left to the exact-output tests, because the
/// writer is allowed to move scalar keys ahead of sub-tables. Table kinds and
/// comments are not compared.
pub fn expectSameTree(a: *const toml.Table, b: *const toml.Table) error{TreesDiffer}!void {
    if (!sameTable(a, b)) return error.TreesDiffer;
}

fn sameTable(a: *const toml.Table, b: *const toml.Table) bool {
    if (a.count() != b.count()) return false;
    for (a.entries.keys(), a.entries.values()) |k, v| {
        if (!sameValue(v, b.get(k) orelse return false)) return false;
    }
    return true;
}

fn sameValue(a: toml.Value, b: toml.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |x| std.mem.eql(u8, x, b.string),
        .integer => |x| x == b.integer,
        .boolean => |x| x == b.boolean,
        // Bit comparison tells -0.0 from 0.0. Any NaN matches any NaN: TOML
        // does not preserve NaN payloads.
        .float => |x| (std.math.isNan(x) and std.math.isNan(b.float)) or
            @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.float)),
        .datetime => |x| std.meta.eql(x, b.datetime),
        .array => |x| blk: {
            if (x.items.items.len != b.array.items.items.len) break :blk false;
            for (x.items.items, b.array.items.items) |i, j| {
                if (!sameValue(i, j)) break :blk false;
            }
            break :blk true;
        },
        .table => |x| sameTable(x, b.table),
    };
}
