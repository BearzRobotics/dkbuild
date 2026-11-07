//! Reader for the YAML subset of SPEC.md 5.1.
//!
//! Supported: block mappings, block sequences, plain / "double" / 'single'
//! quoted scalars, `|` literal block scalars, one-line flow sequences of
//! scalars (`[a, b]`), and `#` comments.
//! Rejected with an error: anchors, aliases, tags, flow mappings, nested flow
//! collections, folded (`>`) and chomped (`|-`, `|+`) scalars, document
//! markers, tabs in indentation, duplicate keys.
//!
//! Everything returned lives in the arena passed to `parse`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    scalar: []const u8,
    list: []const Value,
    map: Map,

    pub fn asScalar(v: Value) ?[]const u8 {
        return if (v == .scalar) v.scalar else null;
    }
    pub fn asList(v: Value) ?[]const Value {
        return if (v == .list) v.list else null;
    }
    pub fn asMap(v: Value) ?Map {
        return if (v == .map) v.map else null;
    }
};

pub const Map = struct {
    keys: []const []const u8,
    values: []const Value,

    pub fn count(m: Map) usize {
        return m.keys.len;
    }
    pub fn get(m: Map, key: []const u8) ?Value {
        for (m.keys, m.values) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }
};

/// Filled in when `parse` returns `error.Syntax`.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const Error = error{Syntax} || Allocator.Error;

const Line = struct {
    no: usize, // 1-based, for messages
    raw: usize, // index into `raw`
    indent: usize,
    text: []const u8, // without indentation, trailing space trimmed
};

const Parser = struct {
    arena: Allocator,
    diag: *Diagnostic,
    raw: []const []const u8,
    lines: []Line,
    pos: usize = 0,

    fn fail(p: *Parser, no: usize, comptime fmt: []const u8, args: anytype) Error {
        p.diag.message = try std.fmt.allocPrint(p.arena, "line {d}: " ++ fmt, .{no} ++ args);
        return error.Syntax;
    }

    fn parseBlock(p: *Parser, indent: usize) Error!Value {
        const l = p.lines[p.pos];
        std.debug.assert(l.indent == indent);
        return if (isSeqItem(l.text)) p.parseSeq(indent) else p.parseMap(indent);
    }

    fn parseSeq(p: *Parser, indent: usize) Error!Value {
        var items: std.ArrayList(Value) = .empty;
        while (p.pos < p.lines.len) {
            const l = p.lines[p.pos];
            if (l.indent < indent) break;
            if (l.indent > indent) return p.fail(l.no, "unexpected indentation", .{});
            if (!isSeqItem(l.text)) return p.fail(l.no, "expected '- ' (a sequence entry)", .{});
            const rest = std.mem.trimStart(u8, l.text[1..], " ");
            if (rest.len == 0) {
                p.pos += 1;
                if (p.pos >= p.lines.len or p.lines[p.pos].indent <= indent)
                    return p.fail(l.no, "empty sequence entry", .{});
                try items.append(p.arena, try p.parseBlock(p.lines[p.pos].indent));
            } else if (isSeqItem(rest) or looksLikeMapEntry(rest)) {
                // "- key: v" / "- - x": the rest of the line is a block that
                // starts further right; continuation lines sit at that column.
                const off = l.text.len - rest.len;
                p.lines[p.pos] = .{ .no = l.no, .raw = l.raw, .indent = l.indent + off, .text = rest };
                try items.append(p.arena, try p.parseBlock(l.indent + off));
            } else {
                p.pos += 1;
                try items.append(p.arena, try p.parseValue(l.no, rest));
            }
        }
        return .{ .list = try items.toOwnedSlice(p.arena) };
    }

    fn parseMap(p: *Parser, indent: usize) Error!Value {
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList(Value) = .empty;
        while (p.pos < p.lines.len) {
            const l = p.lines[p.pos];
            if (l.indent < indent) break;
            if (l.indent > indent) return p.fail(l.no, "unexpected indentation", .{});
            if (isSeqItem(l.text)) return p.fail(l.no, "unexpected '-' inside a mapping", .{});
            const kv = splitKey(l.text) orelse
                return p.fail(l.no, "expected 'key: value'", .{});
            if (kv.key.len == 0) return p.fail(l.no, "empty key", .{});
            if (std.mem.indexOfScalar(u8, "&*!{[|>\"'", kv.key[0]) != null)
                return p.fail(l.no, "unsupported key syntax '{s}'", .{kv.key});
            for (keys.items) |k| {
                if (std.mem.eql(u8, k, kv.key)) return p.fail(l.no, "duplicate key '{s}'", .{kv.key});
            }
            try keys.append(p.arena, try p.arena.dupe(u8, kv.key));

            if (kv.rest.len == 0) {
                p.pos += 1;
                if (p.pos < p.lines.len and p.lines[p.pos].indent > indent) {
                    try vals.append(p.arena, try p.parseBlock(p.lines[p.pos].indent));
                } else {
                    try vals.append(p.arena, .{ .scalar = "" });
                }
            } else if (kv.rest[0] == '|') {
                if (!std.mem.eql(u8, kv.rest, "|"))
                    return p.fail(l.no, "only a plain '|' block scalar is supported (not '{s}')", .{kv.rest});
                try vals.append(p.arena, .{ .scalar = try p.blockScalar(l, indent) });
            } else {
                p.pos += 1;
                try vals.append(p.arena, try p.parseValue(l.no, kv.rest));
            }
        }
        return .{ .map = .{ .keys = try keys.toOwnedSlice(p.arena), .values = try vals.toOwnedSlice(p.arena) } };
    }

    /// Reads the lines after `header` that are indented more than `parent`.
    fn blockScalar(p: *Parser, header: Line, parent: usize) Error![]const u8 {
        var end = header.raw + 1;
        var block_indent: ?usize = null;
        var last_content: usize = header.raw; // raw index of last non-blank line
        while (end < p.raw.len) : (end += 1) {
            const r = p.raw[end];
            if (isBlank(r)) continue;
            const ind = leadingSpaces(r);
            if (ind < r.len and r[ind] == '\t') return p.fail(end + 1, "tab in indentation", .{});
            if (ind <= parent) break;
            if (block_indent == null) block_indent = ind;
            if (ind < block_indent.?) return p.fail(end + 1, "bad indentation inside block scalar", .{});
            last_content = end;
        }
        var out: std.ArrayList(u8) = .empty;
        if (block_indent) |bi| {
            for (p.raw[header.raw + 1 .. last_content + 1]) |r| {
                if (!isBlank(r)) try out.appendSlice(p.arena, r[bi..]);
                try out.append(p.arena, '\n');
            }
        }
        while (p.pos < p.lines.len and p.lines[p.pos].raw < end) p.pos += 1;
        return out.toOwnedSlice(p.arena);
    }

    fn parseValue(p: *Parser, no: usize, text: []const u8) Error!Value {
        if (text[0] == '[') return p.flowSeq(no, text);
        return .{ .scalar = try p.scalar(no, text) };
    }

    fn flowSeq(p: *Parser, no: usize, text: []const u8) Error!Value {
        const close = std.mem.lastIndexOfScalar(u8, text, ']') orelse
            return p.fail(no, "flow sequence must be closed on the same line", .{});
        const tail = std.mem.trim(u8, text[close + 1 ..], " ");
        if (tail.len != 0 and tail[0] != '#') return p.fail(no, "unexpected text after ']'", .{});
        const inner = std.mem.trim(u8, text[1..close], " ");
        var items: std.ArrayList(Value) = .empty;
        var i: usize = 0;
        while (inner.len > 0) {
            // find the end of this element: next comma outside quotes
            var j = i;
            var quote: u8 = 0;
            while (j < inner.len) : (j += 1) {
                const c = inner[j];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '"' or c == '\'') quote = c else if (c == ',') break;
            }
            const el = std.mem.trim(u8, inner[i..j], " ");
            if (el.len == 0) return p.fail(no, "empty element in flow sequence", .{});
            if (el[0] == '[' or el[0] == '{') return p.fail(no, "nested flow collections are not supported", .{});
            try items.append(p.arena, .{ .scalar = try p.scalar(no, el) });
            if (j >= inner.len) break;
            i = j + 1;
        }
        return .{ .list = try items.toOwnedSlice(p.arena) };
    }

    fn scalar(p: *Parser, no: usize, text: []const u8) Error![]const u8 {
        const c = text[0];
        if (c == '"' or c == '\'') {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 1;
            while (i < text.len) : (i += 1) {
                if (c == '"' and text[i] == '\\') {
                    i += 1;
                    if (i >= text.len) break;
                    try out.append(p.arena, switch (text[i]) {
                        'n' => '\n',
                        't' => '\t',
                        '"', '\\', '/' => text[i],
                        else => return p.fail(no, "unsupported escape '\\{c}'", .{text[i]}),
                    });
                } else if (text[i] == c) {
                    if (c == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                        try out.append(p.arena, '\'');
                        i += 1;
                        continue;
                    }
                    const tail = std.mem.trim(u8, text[i + 1 ..], " ");
                    if (tail.len != 0 and tail[0] != '#') return p.fail(no, "unexpected text after closing quote", .{});
                    return out.toOwnedSlice(p.arena);
                } else try out.append(p.arena, text[i]);
            }
            return p.fail(no, "unterminated quoted string", .{});
        }
        if (std.mem.indexOfScalar(u8, "&*!{|>@`", c) != null)
            return p.fail(no, "unsupported YAML syntax '{c}' (anchors, aliases, tags, flow maps and folded scalars are not allowed)", .{c});
        var end = text.len;
        if (std.mem.indexOf(u8, text, " #")) |h| end = h;
        return p.arena.dupe(u8, std.mem.trimEnd(u8, text[0..end], " "));
    }
};

fn isSeqItem(t: []const u8) bool {
    return t.len > 0 and t[0] == '-' and (t.len == 1 or t[1] == ' ');
}

fn looksLikeMapEntry(t: []const u8) bool {
    if (t.len == 0 or std.mem.indexOfScalar(u8, "\"'[", t[0]) != null) return false;
    return splitKey(t) != null;
}

const KV = struct { key: []const u8, rest: []const u8 };

/// Splits at the first ':' that is followed by a space or the end of the line.
fn splitKey(t: []const u8) ?KV {
    for (t, 0..) |c, i| {
        if (c == ':' and (i + 1 == t.len or t[i + 1] == ' ')) {
            return .{
                .key = std.mem.trim(u8, t[0..i], " "),
                .rest = std.mem.trim(u8, t[i + 1 ..], " "),
            };
        }
    }
    return null;
}

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r").len == 0;
}

fn leadingSpaces(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ' ') n += 1;
    return n;
}

pub fn parse(arena: Allocator, text: []const u8, diag: *Diagnostic) Error!Value {
    var raw: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try raw.append(arena, std.mem.trimEnd(u8, l, "\r"));

    var p: Parser = .{ .arena = arena, .diag = diag, .raw = raw.items, .lines = &.{} };
    var lines: std.ArrayList(Line) = .empty;
    for (raw.items, 0..) |r, i| {
        if (isBlank(r)) continue;
        const ind = leadingSpaces(r);
        const t = std.mem.trimEnd(u8, r[ind..], " \t");
        if (t[0] == '#') continue;
        if (t[0] == '\t') return p.fail(i + 1, "tab in indentation", .{});
        if (std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "..."))
            return p.fail(i + 1, "document markers are not supported", .{});
        try lines.append(arena, .{ .no = i + 1, .raw = i, .indent = ind, .text = t });
    }
    p.lines = lines.items;
    if (p.lines.len == 0) return p.fail(1, "empty document", .{});
    if (p.lines[0].indent != 0) return p.fail(p.lines[0].no, "the document must start at column 1", .{});
    const v = try p.parseBlock(0);
    if (p.pos < p.lines.len) return p.fail(p.lines[p.pos].no, "unexpected content", .{});
    return v;
}

// ---- tests ----

fn parseT(arena: Allocator, text: []const u8) !Value {
    var d: Diagnostic = .{};
    return parse(arena, text, &d);
}

fn failMsg(arena: Allocator, text: []const u8) ![]const u8 {
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Syntax, parse(arena, text, &d));
    return d.message;
}

test "mapping, list, nested" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const v = try parseT(st.allocator(),
        \\name : zstd   # trailing comment
        \\deps : [a, "b c", 'd']
        \\source:
        \\    - https://x.org/a-1.tar.gz : abc
        \\    - git|https://x.org/r.git : v1
        \\subpackages:
        \\    devel:
        \\        summary : Headers
        \\
    );
    const m = v.asMap().?;
    try std.testing.expectEqualStrings("zstd", m.get("name").?.asScalar().?);
    const deps = m.get("deps").?.asList().?;
    try std.testing.expectEqual(@as(usize, 3), deps.len);
    try std.testing.expectEqualStrings("b c", deps[1].asScalar().?);
    const src = m.get("source").?.asList().?;
    try std.testing.expectEqualStrings("abc", src[0].asMap().?.get("https://x.org/a-1.tar.gz").?.asScalar().?);
    try std.testing.expectEqualStrings("v1", src[1].asMap().?.get("git|https://x.org/r.git").?.asScalar().?);
    try std.testing.expectEqualStrings("Headers", m.get("subpackages").?.asMap().?.get("devel").?.asMap().?.get("summary").?.asScalar().?);
}

test "literal block scalar" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const v = try parseT(st.allocator(),
        \\build : |
        \\    %configure --a \
        \\               --b
        \\
        \\    %make
        \\install: |
        \\    %make_install
        \\name: x
        \\
    );
    const m = v.asMap().?;
    try std.testing.expectEqualStrings("%configure --a \\\n           --b\n\n%make\n", m.get("build").?.asScalar().?);
    try std.testing.expectEqualStrings("%make_install\n", m.get("install").?.asScalar().?);
    try std.testing.expectEqualStrings("x", m.get("name").?.asScalar().?);
}

test "inline map in sequence continues on later lines" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const v = try parseT(st.allocator(), "users:\n  - name: a\n    groups: [x, y]\n  - name: b\n");
    const users = v.asMap().?.get("users").?.asList().?;
    try std.testing.expectEqual(@as(usize, 2), users.len);
    try std.testing.expectEqual(@as(usize, 2), users[0].asMap().?.get("groups").?.asList().?.len);
}

test "outside the subset is rejected" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    _ = try failMsg(a, "a: &x 1\n");
    _ = try failMsg(a, "a: *x\n");
    _ = try failMsg(a, "a: !!str 1\n");
    _ = try failMsg(a, "a: {b: 1}\n");
    _ = try failMsg(a, "a: >\n  x\n");
    _ = try failMsg(a, "a: |-\n  x\n");
    _ = try failMsg(a, "---\na: 1\n");
    _ = try failMsg(a, "a: 1\na: 2\n");
    _ = try failMsg(a, "a:\n\tb: 1\n");
    _ = try failMsg(a, "a: [[1]]\n");
    try std.testing.expectEqualStrings("line 2: duplicate key 'a'", try failMsg(a, "a: 1\na: 2\n"));
}
