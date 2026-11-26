//! The TOML data model: values, tables, arrays and datetimes.
//!
//! Ownership: every `Value`, `Table` and `Array` reachable from a `Document`
//! lives in that document's arena. Nothing here is freed individually.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,
};

/// One of the four TOML datetime forms, distinguished by which fields are set:
/// offset date-time (date, time, offset), local date-time (date, time),
/// local date (date) and local time (time).
pub const Datetime = struct {
    date: ?Date = null,
    time: ?Time = null,
    /// Minutes east of UTC. `0` means "Z" or "+00:00". Only set with date and time.
    offset_minutes: ?i16 = null,

    /// True if this is one of the four forms above and every field is in
    /// range, so that it can be written as TOML.
    pub fn isValid(self: Datetime) bool {
        if (self.date == null and self.time == null) return false;
        if (self.date) |d| {
            if (d.year > 9999 or d.month < 1 or d.month > 12) return false;
            if (d.day < 1 or d.day > daysInMonth(d.year, d.month)) return false;
        }
        if (self.time) |t| {
            if (t.hour > 23 or t.minute > 59 or t.second > 60) return false;
            if (t.nanosecond >= std.time.ns_per_s) return false;
        }
        if (self.offset_minutes) |off| {
            if (self.date == null or self.time == null) return false;
            if (off < -(23 * 60 + 59) or off > 23 * 60 + 59) return false;
        }
        return true;
    }

    pub fn format(self: Datetime, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.date) |d| try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
        if (self.date != null and self.time != null) try w.writeByte('T');
        if (self.time) |t| {
            try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
            if (t.nanosecond != 0) {
                var buf: [9]u8 = undefined;
                // Only a nanosecond count of a second or more does not fit.
                _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{t.nanosecond}) catch return error.WriteFailed;
                var n: usize = 9;
                while (buf[n - 1] == '0') n -= 1;
                try w.print(".{s}", .{buf[0..n]});
            }
        }
        if (self.offset_minutes) |off| {
            if (off == 0) {
                try w.writeByte('Z');
            } else {
                const abs: u16 = @abs(off);
                try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), abs / 60, abs % 60 });
            }
        }
    }
};

/// `month` is 1 to 12.
pub fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
    };
}

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: Datetime,
    array: *Array,
    table: *Table,

    pub fn typeName(self: Value) []const u8 {
        return @tagName(self);
    }
};

/// How a table came to exist. This decides which later definitions are legal
/// (TOML 1.0.0, "Table" and "Inline Table" sections).
pub const TableKind = enum {
    /// Created only as the parent of a `[a.b.c]` header; may still be defined once.
    implicit,
    /// Defined by its own `[header]` or `[[header]]`, or created by the API.
    explicit,
    /// Created by a dotted key (`a.b = 1`); closed to `[header]` definitions.
    dotted,
    /// Written as `{ ... }`; fully closed once parsed.
    inline_table,
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
    /// True for an array created by `[[header]]`. Only such arrays may be
    /// extended by another `[[header]]`. Every element must then be a table;
    /// `Document.write` refuses the tree otherwise.
    is_table_array: bool = false,
};

/// Comments attached to one item: a `key = value` line, a `[table]` or
/// `[[array]]` header. They survive parse -> edit -> write and travel with the
/// item if the writer reorders it (scalars are written before sub-tables).
pub const Comments = struct {
    /// Lines written above the item, verbatim and without the newline. Each is
    /// either `#...` or empty (a blank line, kept so paragraphs of settings stay
    /// apart). Both are arena-owned.
    before: []const []const u8 = &.{},
    /// A comment (`#...`) written after the item on the same line.
    after: ?[]const u8 = null,

    pub fn isEmpty(self: Comments) bool {
        return self.before.len == 0 and self.after == null;
    }
};

pub const Table = struct {
    /// Insertion-ordered, so a document written back keeps its key order.
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    kind: TableKind = .explicit,
    /// Comments on this table's own `[header]` / `[[header]]` line.
    header: Comments = .{},
    /// Comments on the `key = value` lines of this table, by key.
    key_comments: std.StringArrayHashMapUnmanaged(Comments) = .empty,
    /// Comment lines after the last item of the document (same form as
    /// `Comments.before`). Only meaningful on a document's root table.
    footer: []const []const u8 = &.{},

    pub fn count(self: *const Table) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn getPtr(self: *Table, key: []const u8) ?*Value {
        return self.entries.getPtr(key);
    }

    /// Returns the value only if it is a string.
    pub fn getString(self: *const Table, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: *const Table, key: []const u8) ?i64 {
        return switch (self.get(key) orelse return null) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Returns a float, accepting an integer too (so `size = 12` works for a float key).
    pub fn getFloat(self: *const Table, key: []const u8) ?f64 {
        return switch (self.get(key) orelse return null) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn getBool(self: *const Table, key: []const u8) ?bool {
        return switch (self.get(key) orelse return null) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getTable(self: *const Table, key: []const u8) ?*Table {
        return switch (self.get(key) orelse return null) {
            .table => |t| t,
            else => null,
        };
    }

    pub fn getArray(self: *const Table, key: []const u8) ?*Array {
        return switch (self.get(key) orelse return null) {
            .array => |a| a,
            else => null,
        };
    }

    /// Looks up `a.b.c` style paths through nested tables. Segments are split
    /// on '.', so keys that contain a dot cannot be reached this way; use
    /// `get` for those.
    pub fn lookup(self: *const Table, path: []const u8) ?Value {
        var cur: *const Table = self;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            const v = cur.get(seg) orelse return null;
            if (it.peek() == null) return v;
            switch (v) {
                .table => |t| cur = t,
                else => return null,
            }
        }
        return null;
    }

    /// Sets `key`, replacing any existing value. `key` and any string/array/table
    /// storage in `value` must outlive the table (allocate from the document arena).
    pub fn put(self: *Table, arena: Allocator, key: []const u8, value: Value) Allocator.Error!void {
        // A table made by a dotted key or a header path usually holds one
        // entry, and the default first allocation has room for several. In
        // input made of long dotted keys that unused room was half the memory.
        if (self.entries.capacity() == 0 and (self.kind == .dotted or self.kind == .implicit)) {
            try self.entries.entries.setCapacity(arena, 1);
        }
        const gop = try self.entries.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = key;
        } else switch (gop.value_ptr.*) {
            // A replaced table takes its header comments with it, so keep them
            // with the key. The writer finds them there.
            .table => |old| if (!old.header.isEmpty() and !(value == .table and value.table == old)) {
                const slot = try self.key_comments.getOrPut(arena, gop.key_ptr.*);
                if (!slot.found_existing) slot.value_ptr.* = old.header;
            },
            else => {},
        }
        gop.value_ptr.* = value;
    }

    /// Removes `key`, keeping the order of the remaining entries.
    pub fn remove(self: *Table, key: []const u8) bool {
        _ = self.key_comments.orderedRemove(key);
        return self.entries.orderedRemove(key);
    }

    /// The comments on `key`'s line, or null if it has none. For a sub-table
    /// written as a `[section]` they are on its `header` instead.
    pub fn commentsOf(self: *const Table, key: []const u8) ?Comments {
        return self.key_comments.get(key);
    }

    /// Replaces the comments on `key`'s line. `c` must be arena-owned and valid
    /// (see `checkComments`); `key` is not retained. `key` need not exist yet:
    /// the comments are kept and written once it does.
    pub fn setComments(self: *Table, arena: Allocator, key: []const u8, c: Comments) (Allocator.Error || error{InvalidComment})!void {
        try checkComments(c);
        if (c.isEmpty()) {
            _ = self.key_comments.orderedRemove(key);
            return;
        }
        const k = self.entries.getKey(key) orelse
            self.key_comments.getKey(key) orelse
            try arena.dupe(u8, key);
        try self.key_comments.put(arena, k, c);
    }
};

/// A comment line must be empty or start with `#` (after optional blanks); a
/// trailing comment must start with `#`; neither may contain a line break or a
/// control character other than tab, and both must be UTF-8.
pub fn checkComments(c: Comments) error{InvalidComment}!void {
    for (c.before) |l| {
        if (l.len != 0) try checkLine(std.mem.trimStart(u8, l, " \t"));
    }
    if (c.after) |a| try checkLine(a);
}

fn checkLine(l: []const u8) error{InvalidComment}!void {
    if (l.len == 0 or l[0] != '#') return error.InvalidComment;
    if (!std.unicode.utf8ValidateSlice(l)) return error.InvalidComment;
    for (l) |ch| {
        if (ch == '\t') continue;
        if (ch < 0x20 or ch == 0x7F) return error.InvalidComment;
    }
}
