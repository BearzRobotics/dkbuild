//! Deterministic TOML test data shared by the benchmarks.

const std = @import("std");

/// One `[section.N]` table of mixed value kinds, ~330 bytes.
pub fn appendSection(w: *std.Io.Writer, n: usize) !void {
    try w.print(
        \\[section.s{d}]
        \\name = "item number {d}"
        \\path = 'C:\Users\item{d}'
        \\enabled = true
        \\count = {d}
        \\ratio = {d}.5e-2
        \\hex = 0xdead_beef
        \\created = 2026-11-06T12:34:56Z
        \\tags = ["alpha", "beta", "gamma", "d{d}"]
        \\sizes = [1, 2, 3, 4, 5, 6, 7, 8]
        \\inline = {{ x = {d}, y = "why", z = [true, false] }}
        \\note = """
        \\multi line
        \\text for {d}"""
        \\# a comment line
        \\"quoted key" = "caf\u00e9 \t tab"
        \\a.b.c = {d}
        \\
        \\
    , .{ n, n, n, n, n, n, n, n, n });
}

pub fn generate(gpa: std.mem.Allocator, target_bytes: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var n: usize = 0;
    while (aw.writer.end < target_bytes) : (n += 1) try appendSection(&aw.writer, n);
    return aw.toOwnedSlice();
}
