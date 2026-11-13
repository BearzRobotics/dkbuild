//! Automatic dependencies and provides (SPEC.md 5.6): ELF `DT_NEEDED` and
//! `DT_SONAME`, pkg-config files, and commands in /usr/bin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const Result = struct {
    /// `so:<soname>`, `pc:<name>`, `cmd:<name>` this package supplies.
    provides: []const []const u8,
    /// What it needs, minus whatever it supplies itself.
    depends: []const []const u8,
    /// `so:<soname>` of the private libraries it ships (outside /usr/lib),
    /// which it does not provide. A sibling package of the same recipe that
    /// needs one depends on this package instead (build.zig).
    private: []const []const u8 = &.{},
};

pub const Elf = struct {
    soname: ?[]const u8 = null,
    needed: []const []const u8 = &.{},
};

const pt_load = 1;
const pt_dynamic = 2;
const dt_null = 0;
const dt_needed = 1;
const dt_strtab = 5;
const dt_soname = 14;

fn rd(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

/// Parses the dynamic section of a 64-bit little-endian ELF file. `src` needs
/// `fn readAt(src, buf: []u8, offset: u64) usize` (a short read at the end of
/// the file is fine). Returns null for anything that isn't such an ELF file or
/// has no dynamic section (static executables).
pub fn parseElf(arena: Allocator, src: anytype) Allocator.Error!?Elf {
    var eh: [64]u8 = undefined;
    if (src.readAt(&eh, 0) < 64) return null;
    if (!std.mem.eql(u8, eh[0..4], "\x7fELF") or eh[4] != 2 or eh[5] != 1) return null;
    const phoff = rd(u64, &eh, 32);
    const phentsize = rd(u16, &eh, 54);
    const phnum = rd(u16, &eh, 56);
    if (phentsize < 56 or phnum == 0 or phnum > 512) return null;

    const Seg = struct { offset: u64, vaddr: u64, filesz: u64 };
    var loads: std.ArrayList(Seg) = .empty;
    var dynamic: ?Seg = null;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        var ph: [56]u8 = undefined;
        if (src.readAt(&ph, phoff + i * phentsize) < 56) return null;
        const seg: Seg = .{ .offset = rd(u64, &ph, 8), .vaddr = rd(u64, &ph, 16), .filesz = rd(u64, &ph, 32) };
        switch (rd(u32, &ph, 0)) {
            pt_load => try loads.append(arena, seg),
            pt_dynamic => dynamic = seg,
            else => {},
        }
    }
    const dyn = dynamic orelse return null;

    // Collect tags first; names need DT_STRTAB, which can come after them.
    var needed_offs: std.ArrayList(u64) = .empty;
    var soname_off: ?u64 = null;
    var strtab_addr: ?u64 = null;
    var n: usize = 0;
    while (n < dyn.filesz / 16 and n < 4096) : (n += 1) {
        var d: [16]u8 = undefined;
        if (src.readAt(&d, dyn.offset + n * 16) < 16) return null;
        const tag = rd(i64, &d, 0);
        const val = rd(u64, &d, 8);
        if (tag == dt_null) break;
        switch (tag) {
            dt_needed => try needed_offs.append(arena, val),
            dt_soname => soname_off = val,
            dt_strtab => strtab_addr = val,
            else => {},
        }
    }
    const saddr = strtab_addr orelse return null;
    const strtab_file = for (loads.items) |l| {
        if (saddr >= l.vaddr and saddr < l.vaddr + l.filesz) break l.offset + (saddr - l.vaddr);
    } else return null;

    const names = struct {
        fn at(a: Allocator, s: anytype, off: u64) Allocator.Error!?[]const u8 {
            var buf: [256]u8 = undefined;
            const got = s.readAt(&buf, off);
            const end = std.mem.indexOfScalar(u8, buf[0..got], 0) orelse return null;
            return try a.dupe(u8, buf[0..end]);
        }
    };
    var out: Elf = .{};
    var list: std.ArrayList([]const u8) = .empty;
    for (needed_offs.items) |o| if (try names.at(arena, src, strtab_file + o)) |nm| try list.append(arena, nm);
    out.needed = list.items;
    if (soname_off) |o| out.soname = try names.at(arena, src, strtab_file + o);
    return out;
}

/// `Requires:` and `Requires.private:` package names of a .pc file.
pub fn pcRequires(arena: Allocator, text_in: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    // A line ending in a backslash continues on the next (poppler's
    // "Requires.private: \" with the names below it).
    const text = try std.mem.replaceOwned(u8, arena, text_in, "\\\n", " ");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest_line = if (std.mem.startsWith(u8, line, "Requires.private:"))
            line["Requires.private:".len..]
        else if (std.mem.startsWith(u8, line, "Requires:"))
            line["Requires:".len..]
        else
            continue;
        // '#' starts a comment, as for pkg-config: nettle's hogweed.pc has
        // "Requires: # nettle" when built shared (@IF_NOT_SHARED@ is "#").
        const rest = if (std.mem.indexOfScalar(u8, rest_line, '#')) |h| rest_line[0..h] else rest_line;
        // "a >= 1.0, b c" -> a, b, c. A token made only of operator characters
        // swallows the version after it; "name=1.0" keeps just the name.
        var toks = std.mem.tokenizeAny(u8, rest, ", \t\r");
        var skip_next = false;
        while (toks.next()) |t| {
            if (skip_next) {
                skip_next = false;
                continue;
            }
            const op = std.mem.indexOfAny(u8, t, "<>=!");
            if (op) |at| {
                if (at == 0) {
                    skip_next = std.mem.indexOfNone(u8, t, "<>=!") == null;
                    continue;
                }
                try out.append(arena, try arena.dupe(u8, t[0..at]));
                continue;
            }
            if (t[0] == '$') continue;
            try out.append(arena, try arena.dupe(u8, t));
        }
    }
    return out.items;
}

const FileSource = struct {
    file: std.Io.File,
    io: std.Io,
    pub fn readAt(s: FileSource, buf: []u8, off: u64) usize {
        return s.file.readPositionalAll(s.io, buf, off) catch 0;
    }
};

fn addUnique(arena: Allocator, list: *std.ArrayList([]const u8), item: []const u8) Allocator.Error!void {
    for (list.items) |x| if (std.mem.eql(u8, x, item)) return;
    try list.append(arena, try arena.dupe(u8, item));
}

/// Scans one package's file tree (`root` is a host directory path).
pub fn scanTree(arena: Allocator, io: std.Io, root: []const u8) !Result {
    var provides: std.ArrayList([]const u8) = .empty;
    var needs: std.ArrayList([]const u8) = .empty;
    // Libraries outside /usr/lib itself (ollama's /usr/lib/ollama, perl's CORE)
    // are private: found through an rpath, not by the loader's search path. They
    // are not provided to other packages, and a need they meet is not a
    // dependency. Without this, two packages that each carry a private ggml
    // would conflict over so:libggml-base.so.0.
    var private: std.ArrayList([]const u8) = .empty;

    var d = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer d.close(io);
    var w = try d.walk(arena);
    defer w.deinit();
    while (try w.next(io)) |e| {
        const dirname = std.fs.path.dirname(e.path) orelse "";
        if (e.kind == .sym_link or e.kind == .file) {
            if (std.mem.eql(u8, dirname, "usr/bin") or std.mem.eql(u8, dirname, "usr/sbin") or std.mem.eql(u8, dirname, "bin"))
                try addUnique(arena, &provides, try std.fmt.allocPrint(arena, "cmd:{s}", .{e.basename}));
        }
        if (e.kind != .file) continue;

        if (std.mem.endsWith(u8, e.path, ".pc") and std.mem.indexOf(u8, e.path, "pkgconfig/") != null) {
            const name = e.basename[0 .. e.basename.len - 3];
            try addUnique(arena, &provides, try std.fmt.allocPrint(arena, "pc:{s}", .{name}));
            const text = d.readFileAlloc(io, e.path, arena, .limited(1 << 20)) catch continue;
            for (try pcRequires(arena, text)) |r| try addUnique(arena, &needs, try std.fmt.allocPrint(arena, "pc:{s}", .{r}));
            continue;
        }

        const f = d.openFile(io, e.path, .{}) catch continue;
        defer f.close(io);
        const info = (try parseElf(arena, FileSource{ .file = f, .io = io })) orelse continue;
        const public = std.mem.eql(u8, dirname, "usr/lib") or std.mem.eql(u8, dirname, "lib");
        if (info.soname) |so| {
            try addUnique(arena, if (public) &provides else &private, try std.fmt.allocPrint(arena, "so:{s}", .{so}));
        } else if (public and std.mem.indexOf(u8, e.basename, ".so") != null and
            !std.mem.eql(u8, e.basename, "libc.so"))
        {
            // A library in /usr/lib without a soname (tcl's libtcl8.6.so) is
            // linked by its file name: provide that name.
            try addUnique(arena, &provides, try std.fmt.allocPrint(arena, "so:{s}", .{e.basename}));
        } else if (!public and std.mem.indexOf(u8, e.basename, ".so") != null) {
            // A private library without a soname (perl's CORE/libperl.so) is
            // linked, and so needed, by its file name.
            try addUnique(arena, &private, try std.fmt.allocPrint(arena, "so:{s}", .{e.basename}));
        }
        // musl's libc.so is the C library, the dynamic loader and the thing every
        // program links as `libc.so`, but it has no SONAME. Provide the name the
        // programs ask for.
        if (info.soname == null and (std.mem.eql(u8, e.path, "usr/lib/libc.so") or std.mem.eql(u8, e.path, "lib/libc.so")))
            try addUnique(arena, &provides, "so:libc.so");
        for (info.needed) |nd| try addUnique(arena, &needs, try std.fmt.allocPrint(arena, "so:{s}", .{nd}));
    }

    var deps: std.ArrayList([]const u8) = .empty;
    outer: for (needs.items) |n| {
        for (provides.items) |p| if (std.mem.eql(u8, n, p)) continue :outer;
        for (private.items) |p| if (std.mem.eql(u8, n, p)) continue :outer;
        try deps.append(arena, n);
    }
    std.mem.sort([]const u8, deps.items, {}, lessThan);
    std.mem.sort([]const u8, provides.items, {}, lessThan);
    return .{ .provides = provides.items, .depends = deps.items, .private = private.items };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---- tests ----

const SliceSource = struct {
    bytes: []const u8,
    pub fn readAt(s: SliceSource, buf: []u8, off: u64) usize {
        if (off >= s.bytes.len) return 0;
        const n = @min(buf.len, s.bytes.len - @as(usize, @intCast(off)));
        @memcpy(buf[0..n], s.bytes[@intCast(off)..][0..n]);
        return n;
    }
};

/// A minimal ELF64 shared object: one PT_LOAD covering the file, one
/// PT_DYNAMIC, a string table "\0libc.so\0libz.so.1\0libfoo.so.2\0".
fn fixtureElf(buf: *[512]u8) []const u8 {
    @memset(buf, 0);
    const strtab = "\x00libc.so\x00libz.so.1\x00libfoo.so.2\x00";
    const dyn_off = 64 + 2 * 56; // 176
    const str_off = dyn_off + 5 * 16; // 256
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2;
    buf[5] = 1;
    std.mem.writeInt(u64, buf[32..40], 64, .little); // phoff
    std.mem.writeInt(u16, buf[54..56], 56, .little); // phentsize
    std.mem.writeInt(u16, buf[56..58], 2, .little); // phnum
    // PT_LOAD: offset 0, vaddr 0x1000, filesz whole file
    std.mem.writeInt(u32, buf[64..68], 1, .little);
    std.mem.writeInt(u64, buf[64 + 8 ..][0..8], 0, .little);
    std.mem.writeInt(u64, buf[64 + 16 ..][0..8], 0x1000, .little);
    std.mem.writeInt(u64, buf[64 + 32 ..][0..8], 512, .little);
    // PT_DYNAMIC
    std.mem.writeInt(u32, buf[120..124], 2, .little);
    std.mem.writeInt(u64, buf[120 + 8 ..][0..8], dyn_off, .little);
    std.mem.writeInt(u64, buf[120 + 32 ..][0..8], 5 * 16, .little);
    const entries = [_][2]u64{
        .{ 5, 0x1000 + str_off }, // STRTAB (listed before NEEDED on purpose elsewhere is fine)
        .{ 1, 1 }, // NEEDED libc.so
        .{ 1, 9 }, // NEEDED libz.so.1
        .{ 14, 19 }, // SONAME libfoo.so.2
        .{ 0, 0 },
    };
    for (entries, 0..) |e, k| {
        std.mem.writeInt(u64, buf[dyn_off + k * 16 ..][0..8], e[0], .little);
        std.mem.writeInt(u64, buf[dyn_off + k * 16 + 8 ..][0..8], e[1], .little);
    }
    @memcpy(buf[str_off..][0..strtab.len], strtab);
    return buf;
}

test "parseElf reads DT_NEEDED and DT_SONAME through the string table" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var buf: [512]u8 = undefined;
    const elf = (try parseElf(st.allocator(), SliceSource{ .bytes = fixtureElf(&buf) })).?;
    try std.testing.expectEqual(@as(usize, 2), elf.needed.len);
    try std.testing.expectEqualStrings("libc.so", elf.needed[0]);
    try std.testing.expectEqualStrings("libz.so.1", elf.needed[1]);
    try std.testing.expectEqualStrings("libfoo.so.2", elf.soname.?);
}

test "parseElf ignores files that are not 64-bit little-endian ELF" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    try std.testing.expect((try parseElf(st.allocator(), SliceSource{ .bytes = "#!/bin/sh\necho this is a script, not an ELF file, but long enough to hold a header read\n" })) == null);
    var buf: [512]u8 = undefined;
    _ = fixtureElf(&buf);
    buf[4] = 1; // 32-bit
    try std.testing.expect((try parseElf(st.allocator(), SliceSource{ .bytes = &buf })) == null);
}

test "pcRequires drops versions and variables" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const r = try pcRequires(st.allocator(),
        \\Name: x
        \\Requires: glib-2.0 >= 2.50, zlib
        \\Requires.private: libpng=1.6 ${extra} freetype2
        \\Libs: -lx
        \\
    );
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqualStrings("glib-2.0", r[0]);
    try std.testing.expectEqualStrings("zlib", r[1]);
    try std.testing.expectEqualStrings("libpng", r[2]);
    try std.testing.expectEqualStrings("freetype2", r[3]);
}

test "pcRequires joins continued lines" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const r = try pcRequires(st.allocator(), "Requires.private: \\\n  cairo \\\n  zlib\nLibs: -lp\n");
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("cairo", r[0]);
    try std.testing.expectEqualStrings("zlib", r[1]);
}

test "pcRequires stops at a comment" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const r = try pcRequires(st.allocator(),
        \\Requires: # nettle
        \\Requires.private:  nettle
        \\
    );
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("nettle", r[0]);
}
