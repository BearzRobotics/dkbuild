//! A tiny command line program for comparing builds of the parser with
//! external tools such as `poop` (https://github.com/andrewrk/poop), which
//! measures whole processes (wall time, CPU cycles, instructions, cache and
//! branch misses, peak memory).
//!
//!   toml-parse gen <bytes>          write a generated TOML file to stdout
//!   toml-parse slice  <file> [n]    read the file whole, parse it n times
//!   toml-parse reader <file> [n]    stream the file through a 4 KiB Reader
//!
//! Exits 0 on success, 1 if the file does not parse.

const std = @import("std");
const toml = @import("toml");
const gen = @import("gen.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: {s} gen <bytes> | slice|reader <file> [repeat]\n", .{args[0]});
        return error.Usage;
    }

    if (std.mem.eql(u8, args[1], "gen")) {
        const text = try gen.generate(gpa, try std.fmt.parseInt(usize, args[2], 10));
        defer gpa.free(text);
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        try out.interface.writeAll(text);
        try out.interface.flush();
        return;
    }

    const repeat: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 1;
    const use_slice = std.mem.eql(u8, args[1], "slice");
    if (!use_slice and !std.mem.eql(u8, args[1], "reader")) return error.Usage;

    for (0..repeat) |_| {
        var diag: toml.Diagnostic = .{};
        var doc = blk: {
            if (use_slice) {
                const text = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(1 << 30));
                defer gpa.free(text);
                break :blk toml.Document.parse(gpa, text, .{ .max_bytes = 1 << 30 }, &diag);
            }
            var file = try std.Io.Dir.cwd().openFile(io, args[2], .{});
            defer file.close(io);
            var buf: [4096]u8 = undefined;
            var reader = file.reader(io, &buf);
            break :blk toml.Document.parseReader(gpa, &reader.interface, .{ .max_bytes = 1 << 30 }, &diag);
        } catch |e| {
            std.debug.print("{s}: {f}: {t}\n", .{ args[2], diag, e });
            std.process.exit(1);
        };
        std.mem.doNotOptimizeAway(doc.root);
        doc.deinit();
    }
}
