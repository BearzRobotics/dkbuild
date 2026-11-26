//! Maven repository metadata (maven-metadata.xml). A released artifact never changes, but the list of an
//! artifact's versions, and of a group's plugin prefixes, differs from one repository and one day to the next:
//! the shared store has to hold all of them (docs: mavendeps, gradledeps).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The two lists a metadata file can hold, and what makes two entries the same one.
const lists = [_]struct { all: []const u8, one: []const u8, key: []const u8 }{
    .{ .all = "versions", .one = "version", .key = "" },
    .{ .all = "plugins", .one = "plugin", .key = "prefix" },
};

/// What is between the first `<name>` and its `</name>`, with the offset of the closing tag.
fn element(xml: []const u8, name: []const u8) ?struct { inner: []const u8, close: usize } {
    var buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&buf, "<{s}>", .{name}) catch return null;
    const start = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    var buf2: [64]u8 = undefined;
    const close = std.fmt.bufPrint(&buf2, "</{s}>", .{name}) catch return null;
    const end = std.mem.indexOfPos(u8, xml, start, close) orelse return null;
    return .{ .inner = xml[start..end], .close = end };
}

fn identity(entry: []const u8, key: []const u8) []const u8 {
    if (key.len > 0) if (element(entry, key)) |e| return std.mem.trim(u8, e.inner, " \t\r\n");
    return std.mem.trim(u8, entry, " \t\r\n");
}

/// `old` (may be empty) and `new` as one: the one updated last, with the other's entries added to its lists.
pub fn mergeMetadata(arena: Allocator, old: []const u8, new: []const u8) Allocator.Error![]const u8 {
    if (old.len == 0) return new;
    const stamp = struct {
        fn of(x: []const u8) []const u8 { // yyyymmddhhmmss: compares as text
            return if (element(x, "lastUpdated")) |e| std.mem.trim(u8, e.inner, " \t\r\n") else "";
        }
    }.of;
    const old_is_later = std.mem.order(u8, stamp(old), stamp(new)) == .gt;
    var base: []const u8 = if (old_is_later) old else new;
    const other: []const u8 = if (old_is_later) new else old;
    for (lists) |l| {
        const theirs = element(other, l.all) orelse continue;
        var have: std.StringHashMapUnmanaged(void) = .empty;
        var buf: [64]u8 = undefined;
        const open = std.fmt.bufPrint(&buf, "<{s}>", .{l.one}) catch unreachable;
        var buf2: [64]u8 = undefined;
        const close = std.fmt.bufPrint(&buf2, "</{s}>", .{l.one}) catch unreachable;
        if (element(base, l.all)) |mine| {
            var rest = mine.inner;
            while (std.mem.indexOf(u8, rest, open)) |a| {
                const b = std.mem.indexOfPos(u8, rest, a, close) orelse break;
                try have.put(arena, identity(rest[a + open.len .. b], l.key), {});
                rest = rest[b + close.len ..];
            }
        }
        var added: std.ArrayList(u8) = .empty;
        var rest = theirs.inner;
        while (std.mem.indexOf(u8, rest, open)) |a| {
            const b = std.mem.indexOfPos(u8, rest, a, close) orelse break;
            const id = identity(rest[a + open.len .. b], l.key);
            if (!(try have.getOrPut(arena, id)).found_existing)
                try added.print(arena, "  {s}\n", .{rest[a .. b + close.len]});
            rest = rest[b + close.len ..];
        }
        if (added.items.len == 0) continue;
        if (element(base, l.all)) |mine| {
            base = try std.mem.concat(arena, u8, &.{ base[0..mine.close], added.items, base[mine.close..] });
        } else {
            // the one updated last has no such list: it goes in as a whole
            const at = if (std.mem.eql(u8, l.all, "versions")) std.mem.indexOf(u8, base, "</versioning>") orelse std.mem.lastIndexOf(u8, base, "</metadata>") else std.mem.lastIndexOf(u8, base, "</metadata>");
            const where = at orelse continue;
            base = try std.fmt.allocPrint(arena, "{s}<{s}>\n{s}</{s}>\n{s}", .{ base[0..where], l.all, added.items, l.all, base[where..] });
        }
    }
    return base;
}

test "metadata of two repositories or days becomes one (FV-19)" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const first = "<metadata><versioning><latest>2.0</latest><versions>\n<version>1.0</version>\n<version>2.0</version>\n</versions><lastUpdated>20260101000000</lastUpdated></versioning></metadata>";
    const second = "<metadata><versioning><latest>3.0</latest><versions>\n<version>2.0</version>\n<version>3.0</version>\n</versions><lastUpdated>20260601000000</lastUpdated></versioning></metadata>";
    for ([_][2][]const u8{ .{ first, second }, .{ second, first } }) |pair| {
        const m = try mergeMetadata(a, pair[0], pair[1]);
        for ([_][]const u8{ "1.0", "2.0", "3.0" }) |v| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, m, try std.fmt.allocPrint(a, "<version>{s}</version>", .{v})));
        try std.testing.expect(std.mem.indexOf(u8, m, "<latest>3.0</latest>") != null);
        try std.testing.expectEqualStrings(m, try mergeMetadata(a, m, pair[1]));
    }
    const p1 = "<metadata><plugins><plugin><name>A</name><prefix>a</prefix></plugin></plugins></metadata>";
    const p2 = "<metadata><plugins><plugin><name>B</name><prefix>b</prefix></plugin><plugin><name>A again</name><prefix>a</prefix></plugin></plugins></metadata>";
    const plugins = try mergeMetadata(a, p1, p2);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, plugins, "<prefix>"));
    try std.testing.expectEqualStrings(first, try mergeMetadata(a, "", first));
    // one kind of list on each side: both are kept
    const mixed = try mergeMetadata(a, first, p1);
    try std.testing.expect(std.mem.indexOf(u8, mixed, "<prefix>a</prefix>") != null and std.mem.indexOf(u8, mixed, "<version>1.0</version>") != null);
}
