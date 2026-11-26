//! A seeded mutation fuzz test: damage valid documents at random and require
//! that whatever still parses is written back without loss. The seed is fixed,
//! so a failure repeats; raise `iterations` for a longer run.

const std = @import("std");
const toml = @import("root.zig");
const testing = std.testing;
const expectSameTree = @import("test_util.zig").expectSameTree;

const iterations = 20_000;

const seeds = [_][]const u8{
    "a.b.c = 1\n[a.b.d]\ne = [1, {f=2}]\n[[g]]\nh.i = \"s\"\n[g.j]\n[[g]]\n",
    "# c\nx = { y.z = 1, w = [] } # t\n\n[t.u] # h\nk = 07:32\nm = 1979-05-27 07:32:00.5-00:00\n# f\n",
    "s = \"\"\"\r\nq\\\r\n  \"\" \"\"\"\nl = '''a''''\nn = [nan, -inf, 1e300, -0.0, 0xff]\n\"\" = 1\n[\"a.b\".'']\n",
    "[[a.b]]\n[a]\nc=1\n[[a.b]]\n[a.b.c]\n[[a.b.c.d]]\n",
    "[a]\n# d\nb.c = 1 # e\nb.d.e = 2\nf = 3\n[a.b.g]\n[h.i.j]\n",
};

const fragments = [_][]const u8{
    "a",    "b",    ".",    "[",  "]", "[[", "]]", "{",  "}",   "=",      ",",   " ",
    "\n",   "\r",   "#",    "\"", "'", "\\", "1",  "0",  "_",   "-",      "+",   ":",
    "e",    "T",    "Z",    "x",  "u", "U",  "\t", "ff", "inf", "\"\"\"", "'''", "\xc3\xa9",
    "\xff", "\x00", "\x7f",
};

test "mutated documents are rejected or written back without loss" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x746f6d6c);
    const random = prng.random();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);

    for (0..iterations) |_| {
        src.clearRetainingCapacity();
        try src.appendSlice(gpa, seeds[random.uintLessThan(usize, seeds.len)]);
        for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
            const at = random.uintLessThan(usize, src.items.len + 1);
            if (random.boolean() and at < src.items.len) {
                _ = src.orderedRemove(at);
            } else {
                try src.insertSlice(gpa, at, fragments[random.uintLessThan(usize, fragments.len)]);
            }
        }
        errdefer std.debug.print("input: \"{f}\"\n", .{std.zig.fmtString(src.items)});
        try check(src.items);
    }
}

fn check(src: []const u8) !void {
    const gpa = testing.allocator;
    var a = toml.Document.parse(gpa, src, .{}, null) catch return;
    defer a.deinit();
    const out = try a.toOwnedString(gpa);
    defer gpa.free(out);
    // What the writer emits must be valid 1.0, the stricter of the two.
    var b = try toml.Document.parse(gpa, out, .{ .version = .v1_0 }, null);
    defer b.deinit();
    try expectSameTree(a.root, b.root);
    // Saving again must change nothing.
    const again = try b.toOwnedString(gpa);
    defer gpa.free(again);
    try testing.expectEqualStrings(out, again);
}
