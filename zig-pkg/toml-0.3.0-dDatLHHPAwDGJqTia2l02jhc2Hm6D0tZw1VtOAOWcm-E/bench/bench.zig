//! Parse/write baseline. Run with `zig build bench` (ReleaseFast).
//!
//! Generates a deterministic TOML document of roughly the requested size and
//! reports best-of-N wall time for each operation. Meant for comparing one
//! parser design against another on the same machine, not for absolute claims.

const std = @import("std");
const toml = @import("toml");
const gen = @import("gen.zig");

const runs = 20;

fn report(io: std.Io, label: []const u8, bytes: usize, best_ns: i96) void {
    _ = io;
    const ns: f64 = @floatFromInt(best_ns);
    const mb_s = @as(f64, @floatFromInt(bytes)) / 1e6 / (ns / 1e9);
    std.debug.print("  {s:<22} {d:>10.3} ms  {d:>8.1} MB/s\n", .{ label, ns / 1e6, mb_s });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    for ([_]usize{ 4 * 1024, 256 * 1024, 8 * 1024 * 1024 }) |size| {
        const text = try gen.generate(gpa, size);
        defer gpa.free(text);
        std.debug.print("\ninput {d} bytes\n", .{text.len});

        // parse from a slice
        var best: i96 = std.math.maxInt(i96);
        for (0..runs) |_| {
            const t0 = std.Io.Clock.awake.now(io);
            var doc = try toml.Document.parse(gpa, text, .{}, null);
            const t1 = std.Io.Clock.awake.now(io);
            std.mem.doNotOptimizeAway(doc.root);
            doc.deinit();
            best = @min(best, t0.durationTo(t1).nanoseconds);
        }
        report(io, "parse (slice)", text.len, best);

        // parse through a Reader
        best = std.math.maxInt(i96);
        for (0..runs) |_| {
            var r: std.Io.Reader = .fixed(text);
            const t0 = std.Io.Clock.awake.now(io);
            var doc = try toml.Document.parseReader(gpa, &r, .{ .max_bytes = 1 << 30 }, null);
            const t1 = std.Io.Clock.awake.now(io);
            std.mem.doNotOptimizeAway(doc.root);
            doc.deinit();
            best = @min(best, t0.durationTo(t1).nanoseconds);
        }
        report(io, "parseReader (fixed)", text.len, best);

        // write
        var doc = try toml.Document.parse(gpa, text, .{}, null);
        defer doc.deinit();
        best = std.math.maxInt(i96);
        var out_len: usize = 0;
        for (0..runs) |_| {
            const t0 = std.Io.Clock.awake.now(io);
            const s = try doc.toOwnedString(gpa);
            const t1 = std.Io.Clock.awake.now(io);
            out_len = s.len;
            gpa.free(s);
            best = @min(best, t0.durationTo(t1).nanoseconds);
        }
        report(io, "write (toOwnedString)", out_len, best);
    }
}
