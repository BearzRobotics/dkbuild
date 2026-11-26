//! Serializes a table tree back to TOML text.
//!
//! Output is deterministic: keys appear in insertion order, scalar and dotted
//! keys before sub-tables. Dotted keys are written as dotted keys.
//!
//! Comments (and the blank lines kept with them) are written back next to the
//! item they were attached to; other formatting is not preserved, and comments
//! inside arrays and inline tables are dropped. Unknown keys are preserved
//! because the whole tree is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const Table = value.Table;
const Comments = value.Comments;
const Writer = std.Io.Writer;

pub const Error = Writer.Error || Allocator.Error || error{
    /// More than `max_nesting` tables and arrays inside one another, which
    /// includes any table or array that contains itself.
    NestingTooDeep,
    /// Something in the tree has no TOML form: a string, key or comment that is
    /// not UTF-8, a comment that `checkComments` rejects, a `Datetime` that
    /// is not `isValid`, or an `is_table_array` array holding a non-table.
    InvalidValue,
};

/// The most levels of tables and arrays the writer will descend. It recurses
/// once per level, so this bounds its stack use.
pub const max_nesting = 1024;

/// Looks over the whole tree before anything is written, so that a tree that
/// cannot be written produces no partial output. The fields it checks are all
/// public, so nothing else guarantees them.
fn check(v: Value, depth: usize) Error!void {
    switch (v) {
        .string => |s| try checkText(s),
        .datetime => |d| if (!d.isValid()) return error.InvalidValue,
        .table => |t| try checkTable(t, depth),
        .array => |a| {
            if (depth > max_nesting) return error.NestingTooDeep;
            for (a.items.items) |item| {
                if (a.is_table_array and item != .table) return error.InvalidValue;
                try check(item, depth + 1);
            }
        },
        .integer, .float, .boolean => {},
    }
}

fn checkTable(t: *const Table, depth: usize) Error!void {
    if (depth > max_nesting) return error.NestingTooDeep;
    try checkComment(t.header);
    for (t.key_comments.values()) |c| try checkComment(c);
    for (t.entries.keys(), t.entries.values()) |k, sub| {
        try checkText(k);
        try check(sub, depth + 1);
    }
}

fn checkText(s: []const u8) error{InvalidValue}!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidValue;
}

fn checkComment(c: Comments) error{InvalidValue}!void {
    value.checkComments(c) catch return error.InvalidValue;
}

pub fn writeTable(gpa: Allocator, w: *Writer, root: *const Table) Error!void {
    try checkTable(root, 0);
    try checkComment(.{ .before = root.footer });
    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(gpa);
    var first = true;
    try emit(gpa, w, root, &path, &first);
    try lines(w, if (first) fromTop(root.footer) else root.footer);
}

fn lines(w: *Writer, ls: []const []const u8) Writer.Error!void {
    for (ls) |l| {
        try w.writeAll(l);
        try w.writeByte('\n');
    }
}

/// `ls` without leading blank lines, for what is written at the top of the
/// output. The parser drops them there, so keeping them would make the next
/// save differ.
fn fromTop(ls: []const []const u8) []const []const u8 {
    var i: usize = 0;
    while (i < ls.len and ls[i].len == 0) i += 1;
    return ls[i..];
}

fn after(w: *Writer, c: Comments) Writer.Error!void {
    if (c.after) |a| {
        try w.writeByte(' ');
        try w.writeAll(a);
    }
    try w.writeByte('\n');
}

/// Can `t` be written as a `[header]` section? Inline tables, and anything
/// nested inside a static array, are written inline instead.
fn isSection(v: Value) bool {
    return switch (v) {
        .table => |t| t.kind != .inline_table,
        .array => |a| a.is_table_array and a.items.items.len > 0,
        else => false,
    };
}

/// The table, if `v` is to be written as dotted keys (`a.b = 1`) in the
/// section that holds it, rather than under a header of its own. That is how a
/// table made by dotted keys was written. It still needs a header to hold
/// header comments, or to exist at all once it has no entries.
fn asDotted(parent: *const Table, key: []const u8, v: Value) ?*const Table {
    return switch (v) {
        .table => |t| if (t.kind == .dotted and t.count() != 0 and
            headerComments(parent, key, t).isEmpty()) t else null,
        else => null,
    };
}

/// The comments for the header of `t`, found under `key` in `parent`. If the
/// table has none of its own, those on the key are used: they are there when
/// a `key = value` line has since become a table.
fn headerComments(parent: *const Table, key: []const u8, t: *const Table) Comments {
    if (!t.header.isEmpty()) return t.header;
    return parent.commentsOf(key) orelse .{};
}

/// The dotted-key segments leading to the entry being written, innermost first.
/// The nodes live on the stack of the functions that recurse into each table.
const Prefix = struct {
    outer: ?*const Prefix,
    key: []const u8,

    fn write(self: *const Prefix, w: *Writer) Writer.Error!void {
        if (self.outer) |o| try o.write(w);
        try writeKey(w, self.key);
        try w.writeByte('.');
    }
};

/// Writes one table: its `key = value` lines first, then its sections, since
/// every line after a header belongs to that header.
fn emit(gpa: Allocator, w: *Writer, t: *const Table, path: *std.ArrayList([]const u8), first: *bool) Error!void {
    try keyLines(w, t, null, first);
    try sections(gpa, w, t, path, first);
}

fn keyLines(w: *Writer, t: *const Table, prefix: ?*const Prefix, first: *bool) Writer.Error!void {
    for (t.entries.keys(), t.entries.values()) |k, v| {
        if (asDotted(t, k, v)) |sub| {
            try keyLines(w, sub, &.{ .outer = prefix, .key = k }, first);
            continue;
        }
        if (isSection(v)) continue;
        const c = t.commentsOf(k) orelse Comments{};
        try lines(w, if (first.*) fromTop(c.before) else c.before);
        if (prefix) |p| try p.write(w);
        try writeKey(w, k);
        try w.writeAll(" = ");
        try writeInline(w, v);
        try after(w, c);
        first.* = false;
    }
}

fn sections(gpa: Allocator, w: *Writer, t: *const Table, path: *std.ArrayList([]const u8), first: *bool) Error!void {
    for (t.entries.keys(), t.entries.values()) |k, v| {
        if (!isSection(v)) continue;
        try path.append(gpa, k);
        defer _ = path.pop();
        // Its lines are already written; only sections below it remain.
        if (asDotted(t, k, v)) |sub| {
            try sections(gpa, w, sub, path, first);
            continue;
        }
        switch (v) {
            .table => |sub| {
                // An implicit parent with only sub-tables needs no header of its own.
                const c = headerComments(t, k, sub);
                if (!c.isEmpty() or !onlySections(sub)) {
                    try header(w, path.items, false, first, c);
                }
                try emit(gpa, w, sub, path, first);
            },
            .array => |a| for (a.items.items, 0..) |item, i| {
                const c = if (i == 0) headerComments(t, k, item.table) else item.table.header;
                try header(w, path.items, true, first, c);
                try emit(gpa, w, item.table, path, first);
            },
            else => unreachable,
        }
    }
}

fn onlySections(t: *const Table) bool {
    // With no entries at all, only a header keeps the table in the output.
    return t.kind == .implicit and t.count() != 0 and !hasKeyLines(t);
}

fn hasKeyLines(t: *const Table) bool {
    for (t.entries.keys(), t.entries.values()) |k, v| {
        if (asDotted(t, k, v)) |sub| {
            if (hasKeyLines(sub)) return true;
        } else if (!isSection(v)) return true;
    }
    return false;
}

fn header(w: *Writer, path: []const []const u8, array: bool, first: *bool, c: Comments) Writer.Error!void {
    // A blank line sets a section apart, unless its comments already start with one.
    if (!first.* and (c.before.len == 0 or c.before[0].len != 0)) try w.writeByte('\n');
    try lines(w, if (first.*) fromTop(c.before) else c.before);
    first.* = false;
    try w.writeAll(if (array) "[[" else "[");
    for (path, 0..) |seg, i| {
        if (i != 0) try w.writeByte('.');
        try writeKey(w, seg);
    }
    try w.writeAll(if (array) "]]" else "]");
    try after(w, c);
}

pub fn writeKey(w: *Writer, key: []const u8) Writer.Error!void {
    var bare = key.len != 0;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) bare = false;
    }
    if (bare) try w.writeAll(key) else try writeString(w, key);
}

pub fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            0...0x07, 0x0B, 0x0E...0x1F, 0x7F => try w.print("\\u{X:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeInline(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .string => |s| try writeString(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |d| try d.format(w),
        .float => |f| try writeFloat(w, f),
        .array => |a| {
            try w.writeByte('[');
            for (a.items.items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try writeInline(w, item);
            }
            try w.writeByte(']');
        },
        .table => |t| {
            if (t.count() == 0) return w.writeAll("{}");
            try w.writeAll("{ ");
            var separate = false;
            try inlineEntries(w, t, null, &separate);
            try w.writeAll(" }");
        },
    }
}

/// The `key = value` pairs between the braces of an inline table. Tables made
/// by dotted keys stay dotted: nesting braces instead could exceed the depth
/// the parser accepts.
fn inlineEntries(w: *Writer, t: *const Table, prefix: ?*const Prefix, separate: *bool) Writer.Error!void {
    for (t.entries.keys(), t.entries.values()) |k, v| {
        if (v == .table and v.table.kind == .dotted and v.table.count() != 0) {
            try inlineEntries(w, v.table, &.{ .outer = prefix, .key = k }, separate);
            continue;
        }
        if (separate.*) try w.writeAll(", ");
        separate.* = true;
        if (prefix) |p| try p.write(w);
        try writeKey(w, k);
        try w.writeAll(" = ");
        try writeInline(w, v);
    }
}

fn writeFloat(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("nan");
    if (std.math.isInf(f)) return w.writeAll(if (f < 0) "-inf" else "inf");
    // Shortest representation that round-trips; TOML requires a '.' or exponent.
    var buf: [64]u8 = undefined;
    // {d} would print 300+ digits for 1e300, so use exponent form at the extremes.
    const abs = @abs(f);
    const s = if (abs != 0 and (abs >= 1e16 or abs < 1e-4))
        std.fmt.bufPrint(&buf, "{e}", .{f}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    try w.writeAll(s);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) try w.writeAll(".0");
}
