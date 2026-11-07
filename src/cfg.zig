//! Reading typed values out of a parsed TOML table, for recipes (SPEC.md 5)
//! and profiles (6.1). Every function fails with a message a recipe author can
//! act on, written into a `Diagnostic`.
//!
//! The TOML itself is parsed by toml-zig; this file only checks types and
//! rejects keys the format does not define, so that a typo cannot silently do
//! nothing.

const std = @import("std");
const toml = @import("toml");
const Allocator = std.mem.Allocator;

/// What went wrong, in words a recipe author can act on.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// Raised for any problem with the content; the reason is in the `Diagnostic`.
pub const Invalid = error{Invalid};

pub const Error = Invalid || Allocator.Error;

pub fn fail(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try std.fmt.allocPrint(arena, fmt, args);
    return error.Invalid;
}

/// Parses `text` as TOML. Syntax errors become a `Diagnostic` with the line
/// and column. The document's memory comes from `arena` and is never freed
/// separately.
pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!*toml.Table {
    var tdiag: toml.Diagnostic = .{};
    const doc = toml.Document.parse(arena, text, .{}, &tdiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, diag, "line {d}, column {d}: {s}", .{ tdiag.line, tdiag.column, tdiag.message }),
    };
    return doc.root;
}

/// Fails on the first key of `t` that is not in `known`.
pub fn onlyKeys(arena: Allocator, diag: *Diagnostic, t: *const toml.Table, known: []const []const u8, what: []const u8) Error!void {
    for (t.entries.keys()) |k| {
        for (known) |n| {
            if (std.mem.eql(u8, k, n)) break;
        } else {
            if (what.len == 0) return fail(arena, diag, "unknown key '{s}'", .{k});
            return fail(arena, diag, "{s}: unknown key '{s}'", .{ what, k });
        }
    }
}

pub fn optString(arena: Allocator, diag: *Diagnostic, t: *const toml.Table, key: []const u8) Error!?[]const u8 {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .string => |s| try arena.dupe(u8, s),
        else => fail(arena, diag, "'{s}' must be a string, not {s}", .{ key, v.typeName() }),
    };
}

pub fn reqString(arena: Allocator, diag: *Diagnostic, t: *const toml.Table, key: []const u8) Error![]const u8 {
    return (try optString(arena, diag, t, key)) orelse
        fail(arena, diag, "missing required key '{s}'", .{key});
}

/// A list of strings; absent means empty.
pub fn optStrings(arena: Allocator, diag: *Diagnostic, t: *const toml.Table, key: []const u8) Error![]const []const u8 {
    const v = t.get(key) orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return fail(arena, diag, "'{s}' must be a list, not {s}", .{ key, v.typeName() }),
    };
    const out = try arena.alloc([]const u8, arr.items.items.len);
    for (arr.items.items, out) |item, *dst| {
        dst.* = switch (item) {
            .string => |s| try arena.dupe(u8, s),
            else => return fail(arena, diag, "'{s}' entries must be strings, not {s}", .{ key, item.typeName() }),
        };
    }
    return out;
}

/// An integer in `1..=max`.
pub fn reqPositive(arena: Allocator, diag: *Diagnostic, t: *const toml.Table, key: []const u8, comptime T: type) Error!T {
    const v = t.get(key) orelse return fail(arena, diag, "missing required key '{s}'", .{key});
    const n = switch (v) {
        .integer => |i| i,
        else => return fail(arena, diag, "'{s}' must be an integer, not {s}", .{ key, v.typeName() }),
    };
    if (n < 1) return fail(arena, diag, "'{s}' starts at 1", .{key});
    return std.math.cast(T, n) orelse fail(arena, diag, "'{s}' is too large", .{key});
}
