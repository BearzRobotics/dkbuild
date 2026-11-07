//! Imports Chimera cbuild templates (decision 0002, SPEC.md 5.9).
//!
//! A template is Python. It is read as *text* and never run: a small reader
//! evaluates the module-level `name = expression` statements it understands
//! (strings, f-strings over earlier names, numbers, lists, dicts, `+`), and
//! anything it cannot evaluate stays visible as an *unknown* value. The result
//! is a draft `package.toml` and a list of notes saying what was dropped,
//! guessed at or left as a `TODO(cbuild)` for a person.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct { key: []const u8, value: Value };

pub const Value = union(enum) {
    str: []const u8,
    int: i64,
    boolean: bool,
    none,
    list: []const Value,
    dict: []const Entry,
    /// An expression this reader cannot evaluate; its source text.
    unknown: []const u8,

    pub fn asStr(v: Value) ?[]const u8 {
        return switch (v) {
            .str => |s| s,
            else => null,
        };
    }
};

pub const Env = std.StringHashMapUnmanaged(Value);

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Does a string literal (with optional r/f/b/u prefix) start at `i`?
fn isStringStart(s: []const u8, i: usize) bool {
    var j = i;
    var n: usize = 0;
    while (j < s.len and n < 2 and std.mem.indexOfScalar(u8, "rRfFbBuU", s[j]) != null) : (n += 1) j += 1;
    return j < s.len and (s[j] == '"' or s[j] == '\'');
}

/// What `self.<attr>` means in a shell step, for the few attributes that have a
/// plain equivalent.
fn selfAttr(env: *const Env, attr: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, attr, "make_jobs")) return "$jobs";
    if (std.mem.eql(u8, attr, "files_path")) return "$pkgfiles";
    if (std.mem.eql(u8, attr, "destdir") or std.mem.eql(u8, attr, "chroot_destdir")) return "$pkgdir";
    if (std.mem.eql(u8, attr, "pkgname") or std.mem.eql(u8, attr, "pkgver")) {
        const key = attr;
        if (env.get(key)) |v| return v.asStr();
    }
    return null;
}

pub const Parser = struct {
    arena: Allocator,
    s: []const u8,
    i: usize = 0,
    env: *const Env,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    /// Whitespace, line continuations and comments.
    pub fn skipWs(p: *Parser) void {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.i += 1;
            } else if (c == '\\' and p.i + 1 < p.s.len and (p.s[p.i + 1] == '\n' or p.s[p.i + 1] == '\r')) {
                p.i += 2;
            } else if (c == '#') {
                while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
            } else break;
        }
    }

    /// At a quote (after any prefix): move past the closing quote.
    fn skipString(p: *Parser) void {
        while (p.i < p.s.len and p.s[p.i] != '"' and p.s[p.i] != '\'') p.i += 1;
        if (p.i >= p.s.len) return;
        const q = p.s[p.i];
        const triple = p.i + 2 < p.s.len and p.s[p.i + 1] == q and p.s[p.i + 2] == q;
        p.i += if (triple) 3 else 1;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '\\') {
                p.i += 2;
                continue;
            }
            if (c == q) {
                if (!triple) {
                    p.i += 1;
                    return;
                }
                if (p.i + 2 < p.s.len and p.s[p.i + 1] == q and p.s[p.i + 2] == q) {
                    p.i += 3;
                    return;
                }
            }
            p.i += 1;
        }
    }

    /// From an opening bracket: move past the matching close.
    fn skipBalanced(p: *Parser) void {
        var depth: usize = 0;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            switch (c) {
                '(', '[', '{' => {
                    depth += 1;
                    p.i += 1;
                },
                ')', ']', '}' => {
                    p.i += 1;
                    if (depth <= 1) return;
                    depth -= 1;
                },
                '"', '\'' => p.skipString(),
                '#' => while (p.i < p.s.len and p.s[p.i] != '\n') : (p.i += 1) {},
                else => p.i += 1,
            }
        }
    }

    fn text(p: *Parser, start: usize) []const u8 {
        return std.mem.trim(u8, p.s[start..p.i], " \t\r\n");
    }

    /// Skip to the next `,` or closing bracket at depth 0; the whole thing is unknown.
    fn finishUnknown(p: *Parser, start: usize) Value {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            switch (c) {
                ',', ')', ']', '}' => break,
                '(', '[', '{' => p.skipBalanced(),
                '"', '\'' => p.skipString(),
                '#' => while (p.i < p.s.len and p.s[p.i] != '\n') : (p.i += 1) {},
                else => p.i += 1,
            }
        }
        return .{ .unknown = p.text(start) };
    }

    pub fn parseExpr(p: *Parser) Allocator.Error!Value {
        p.skipWs();
        const start = p.i;
        var v = try p.parseAtom();
        while (true) {
            p.skipWs();
            const op = p.peek() orelse break;
            if (op != '+' and op != '/') break;
            p.i += 1;
            const rhs = try p.parseAtom();
            if (op == '/') {
                // `self.files_path / "x"`, `self.destdir / "usr/bin"`: a path join.
                if (v != .str or rhs != .str) return p.finishUnknown(start);
                v = .{ .str = try std.fmt.allocPrint(p.arena, "{s}/{s}", .{ std.mem.trimEnd(u8, v.str, "/"), std.mem.trimStart(u8, rhs.str, "/") }) };
                continue;
            }
            v = (try concat(p.arena, v, rhs)) orelse return p.finishUnknown(start);
        }
        p.skipWs();
        if (p.peek()) |c| switch (c) {
            ',', ')', ']', '}', ':' => {},
            // An operator or keyword we do not model (`%`, `*`, `if ... else`, `for`).
            else => return p.finishUnknown(start),
        };
        return v;
    }

    fn parseAtom(p: *Parser) Allocator.Error!Value {
        p.skipWs();
        const start = p.i;
        const c = p.peek() orelse return .{ .unknown = "" };
        if (isStringStart(p.s, p.i)) return p.parseStrings();
        if (std.ascii.isDigit(c) or (c == '-' and p.i + 1 < p.s.len and std.ascii.isDigit(p.s[p.i + 1]))) return p.parseNumber();
        switch (c) {
            '[' => return p.parseSeq(']', true),
            '(' => return p.parseSeq(')', false),
            '{' => return p.parseDict(),
            else => {},
        }
        if (isIdentStart(c)) return p.parseName();
        p.i += 1;
        return p.finishUnknown(start);
    }

    fn parseNumber(p: *Parser) Allocator.Error!Value {
        const start = p.i;
        if (p.peek() == '-') p.i += 1;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_' or p.s[p.i] == '.')) p.i += 1;
        const t = p.s[start..p.i];
        const n = std.fmt.parseInt(i64, t, 0) catch return .{ .unknown = t };
        return .{ .int = n };
    }

    /// `[a, b]` (a list) or `(a, b)` (a tuple, or just a parenthesised value).
    fn parseSeq(p: *Parser, close: u8, is_list: bool) Allocator.Error!Value {
        const start = p.i;
        p.i += 1;
        var items: std.ArrayList(Value) = .empty;
        var saw_comma = false;
        while (true) {
            p.skipWs();
            const c = p.peek() orelse return p.bail(start);
            if (c == close) {
                p.i += 1;
                break;
            }
            const item = try p.parseExpr();
            // `[x for x in y]`: any number of items, so the whole list is unknown.
            if (item == .unknown and std.mem.indexOf(u8, item.unknown, " for ") != null) return p.bail(start);
            try items.append(p.arena, item);
            p.skipWs();
            if (p.peek() == ',') {
                saw_comma = true;
                p.i += 1;
            } else if (p.peek() != close) return p.bail(start);
        }
        if (!is_list and !saw_comma and items.items.len == 1) return items.items[0];
        return .{ .list = items.items };
    }

    /// Back to `start`, skip the whole bracketed thing, and call it unknown.
    fn bail(p: *Parser, start: usize) Value {
        p.i = start;
        p.skipBalanced();
        return .{ .unknown = p.text(start) };
    }

    fn parseDict(p: *Parser) Allocator.Error!Value {
        const start = p.i;
        p.i += 1;
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            p.skipWs();
            const c = p.peek() orelse return p.bail(start);
            if (c == '}') {
                p.i += 1;
                break;
            }
            const k = try p.parseExpr();
            const key = k.asStr() orelse return p.bail(start);
            p.skipWs();
            if (p.peek() != ':') return p.bail(start);
            p.i += 1;
            const v = try p.parseExpr();
            try entries.append(p.arena, .{ .key = key, .value = v });
            p.skipWs();
            if (p.peek() == ',') p.i += 1 else if (p.peek() != '}') return p.bail(start);
        }
        return .{ .dict = entries.items };
    }

    fn parseName(p: *Parser) Allocator.Error!Value {
        const start = p.i;
        while (p.i < p.s.len and isIdentChar(p.s[p.i])) p.i += 1;
        const name = p.s[start..p.i];
        if (std.mem.eql(u8, name, "True")) return .{ .boolean = true };
        if (std.mem.eql(u8, name, "False")) return .{ .boolean = false };
        if (std.mem.eql(u8, name, "None")) return .none;

        // `name.replace("a", "b")` on a string we know.
        if (p.env.get(name)) |known| if (known == .str and std.mem.startsWith(u8, p.s[p.i..], ".replace(")) {
            const save = p.i;
            p.i += ".replace".len;
            if (try parseCall(p)) |call| {
                if (call.args.len == 2 and call.kwargs.len == 0 and call.args[0] == .str and call.args[1] == .str and call.args[0].str.len > 0) {
                    return .{ .str = try std.mem.replaceOwned(u8, p.arena, known.str, call.args[0].str, call.args[1].str) };
                }
            }
            p.i = save;
        };

        // Trailers: `.attr`, `(...)`, `[...]`.
        var first_attr: ?[]const u8 = null;
        var trailers: usize = 0;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '.' and p.i + 1 < p.s.len and isIdentStart(p.s[p.i + 1])) {
                p.i += 1;
                const a = p.i;
                while (p.i < p.s.len and isIdentChar(p.s[p.i])) p.i += 1;
                if (trailers == 0) first_attr = p.s[a..p.i];
                trailers += 1;
            } else if (c == '(' or c == '[') {
                p.skipBalanced();
                trailers += 1;
                first_attr = null;
            } else break;
        }
        if (trailers == 0) {
            if (p.env.get(name)) |v| return v;
            return .{ .unknown = name };
        }
        if (std.mem.eql(u8, name, "self") and trailers == 1) {
            if (first_attr) |a| if (selfAttr(p.env, a)) |t| return .{ .str = t };
        }
        return .{ .unknown = p.text(start) };
    }

    /// One or more adjacent string literals.
    fn parseStrings(p: *Parser) Allocator.Error!Value {
        const start = p.i;
        var buf: std.ArrayList(u8) = .empty;
        var ok = true;
        while (true) {
            if (!isStringStart(p.s, p.i)) break;
            if (!try p.parseOneString(&buf)) ok = false;
            const save = p.i;
            p.skipWs();
            if (!isStringStart(p.s, p.i)) {
                p.i = save;
                break;
            }
        }
        if (!ok) return .{ .unknown = p.text(start) };
        return .{ .str = buf.items };
    }

    /// Appends the literal at `p.i` to `buf`. False if an f-string had a part
    /// that could not be evaluated.
    fn parseOneString(p: *Parser, buf: *std.ArrayList(u8)) Allocator.Error!bool {
        var j = p.i;
        var is_f = false;
        var raw = false;
        while (j < p.s.len and p.s[j] != '"' and p.s[j] != '\'') : (j += 1) {
            switch (std.ascii.toLower(p.s[j])) {
                'f' => is_f = true,
                'r' => raw = true,
                else => {},
            }
        }
        if (j >= p.s.len) {
            p.i = j;
            return false;
        }
        const q = p.s[j];
        const triple = j + 2 < p.s.len and p.s[j + 1] == q and p.s[j + 2] == q;
        j += if (triple) 3 else 1;
        var resolved = true;
        const s = p.s;
        while (j < s.len) {
            const c = s[j];
            if (c == '\\' and j + 1 < s.len) {
                const n = s[j + 1];
                if (raw) {
                    try buf.appendSlice(p.arena, s[j .. j + 2]);
                    j += 2;
                    continue;
                }
                j += 2;
                switch (n) {
                    'n' => try buf.append(p.arena, '\n'),
                    't' => try buf.append(p.arena, '\t'),
                    'r' => try buf.append(p.arena, '\r'),
                    '\\', '\'', '"' => try buf.append(p.arena, n),
                    '\n' => {},
                    'x' => if (j + 2 <= s.len) {
                        const v = std.fmt.parseInt(u8, s[j .. j + 2], 16) catch 0;
                        try buf.append(p.arena, v);
                        j += 2;
                    },
                    else => {
                        try buf.append(p.arena, '\\');
                        try buf.append(p.arena, n);
                    },
                }
                continue;
            }
            if (c == q) {
                if (!triple) {
                    j += 1;
                    break;
                }
                if (j + 2 < s.len and s[j + 1] == q and s[j + 2] == q) {
                    j += 3;
                    break;
                }
            }
            if (is_f and c == '{') {
                if (j + 1 < s.len and s[j + 1] == '{') {
                    try buf.append(p.arena, '{');
                    j += 2;
                    continue;
                }
                // The expression runs to the matching '}'.
                var k = j + 1;
                var depth: usize = 1;
                while (k < s.len and depth > 0) : (k += 1) {
                    switch (s[k]) {
                        '{' => depth += 1,
                        '}' => depth -= 1,
                        '"', '\'' => {
                            const quote = s[k];
                            k += 1;
                            while (k < s.len and s[k] != quote) : (k += 1) {}
                        },
                        else => {},
                    }
                }
                const inner = s[j + 1 .. k - 1];
                j = k;
                var sub: Parser = .{ .arena = p.arena, .s = inner, .env = p.env };
                const v = try sub.parseExpr();
                sub.skipWs();
                const done = sub.i == sub.s.len;
                const piece: ?[]const u8 = if (!done) null else switch (v) {
                    .str => |t| t,
                    .int => |n| try std.fmt.allocPrint(p.arena, "{d}", .{n}),
                    else => null,
                };
                if (piece) |t| {
                    try buf.appendSlice(p.arena, t);
                } else {
                    resolved = false;
                    try buf.print(p.arena, "{{?{s}?}}", .{inner});
                }
                continue;
            }
            if (is_f and c == '}' and j + 1 < s.len and s[j + 1] == '}') {
                try buf.append(p.arena, '}');
                j += 2;
                continue;
            }
            try buf.append(p.arena, c);
            j += 1;
        }
        p.i = j;
        return resolved;
    }
};

fn concat(arena: Allocator, a: Value, b: Value) Allocator.Error!?Value {
    switch (a) {
        .str => |x| if (b == .str) return .{ .str = try std.mem.concat(arena, u8, &.{ x, b.str }) },
        .list => |x| if (b == .list) return .{ .list = try std.mem.concat(arena, Value, &.{ x, b.list }) },
        else => {},
    }
    return null;
}

// ---- statements --------------------------------------------------------------

pub const Stmt = struct {
    /// 1-based line of the first line.
    line: usize,
    text: []const u8,
};

fn startsTriple(line: []const u8, i: usize, q: u8) bool {
    return i + 2 < line.len and line[i] == q and line[i + 1] == q and line[i + 2] == q;
}

/// Splits Python source into logical statements: a statement starts at a line
/// whose first character is not whitespace, and runs over indented lines, open
/// brackets, triple-quoted strings and backslash continuations. Blank lines and
/// comment lines before the first statement are dropped.
pub fn splitStatements(arena: Allocator, src: []const u8) Allocator.Error![]const Stmt {
    var out: std.ArrayList(Stmt) = .empty;
    var depth: usize = 0;
    var triple: ?u8 = null;
    var cont = false;
    var cur_start: ?usize = null;
    var cur_line: usize = 0;
    var line_no: usize = 0;
    var pos: usize = 0;
    while (pos < src.len) {
        const eol = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const line = src[pos..eol];
        line_no += 1;
        const open = depth > 0 or triple != null or cont;
        if (!open and line.len > 0 and line[0] != ' ' and line[0] != '\t' and line[0] != '#') {
            if (cur_start) |st| try out.append(arena, .{ .line = cur_line, .text = src[st..pos] });
            cur_start = pos;
            cur_line = line_no;
        }
        // Scan the line for string and bracket state.
        cont = false;
        var i: usize = 0;
        while (i < line.len) {
            const c = line[i];
            if (triple) |q| {
                if (c == '\\') {
                    i += 2;
                } else if (startsTriple(line, i, q)) {
                    triple = null;
                    i += 3;
                } else i += 1;
                continue;
            }
            switch (c) {
                '#' => break,
                '"', '\'' => {
                    if (startsTriple(line, i, c)) {
                        triple = c;
                        i += 3;
                    } else {
                        i += 1;
                        while (i < line.len and line[i] != c) : (i += 1) {
                            if (line[i] == '\\') i += 1;
                        }
                        i += 1;
                    }
                },
                '(', '[', '{' => {
                    depth += 1;
                    i += 1;
                },
                ')', ']', '}' => {
                    if (depth > 0) depth -= 1;
                    i += 1;
                },
                '\\' => {
                    if (i + 1 == line.len or (i + 2 == line.len and line[i + 1] == '\r')) cont = true;
                    i += 1;
                },
                else => i += 1,
            }
        }
        pos = if (eol < src.len) eol + 1 else src.len;
    }
    if (cur_start) |st| try out.append(arena, .{ .line = cur_line, .text = src[st..] });
    return out.items;
}

// ---- the conversion ------------------------------------------------------------

pub const NoteKind = enum {
    /// Something a person must finish; also left as a `TODO(cbuild)` comment.
    todo,
    /// A template variable with no equivalent, dropped.
    dropped,
    /// A choice or a name to double-check.
    check,
};

pub const Note = struct { line: usize, kind: NoteKind, text: []const u8 };

pub const Inputs = struct {
    /// Where the template came from, for the header comment.
    origin: []const u8,
    /// File names found in the template's `patches/` directory, sorted.
    patches: []const []const u8 = &.{},
    has_files: bool = false,
};

pub const Converted = struct {
    name: []const u8,
    toml: []const u8,
    notes: []const Note,
};

/// cbuild's mirror variables: `$(GNU_SITE)` is `sites["gnu"]` (the name is
/// lower-cased and loses its `_SITE`). Copied from `sites` in
/// src/cbuild/core/template.py of chimera-linux/cports, which `_interp_url`
/// there applies to every source URL.
const sites = [_]struct { name: []const u8, url: []const u8 }{
    .{ .name = "sourceforge", .url = "https://downloads.sourceforge.net/sourceforge" },
    .{ .name = "freedesktop", .url = "https://distributions.freedesktop.org/software" },
    .{ .name = "mozilla", .url = "https://ftp.mozilla.org/pub" },
    .{ .name = "debian", .url = "https://ftp.debian.org/debian/pool" },
    .{ .name = "ubuntu", .url = "https://archive.ubuntu.com/ubuntu/pool" },
    .{ .name = "nongnu", .url = "https://download.savannah.nongnu.org/releases" },
    .{ .name = "kernel", .url = "https://www.kernel.org/pub/linux" },
    .{ .name = "gnome", .url = "https://download.gnome.org/sources" },
    .{ .name = "xorg", .url = "https://www.x.org/releases/individual" },
    .{ .name = "cpan", .url = "https://www.cpan.org/modules/by-module" },
    .{ .name = "pypi", .url = "https://files.pythonhosted.org/packages/source" },
    .{ .name = "gnu", .url = "https://ftp.gnu.org/gnu" },
    .{ .name = "kde", .url = "https://download.kde.org/stable" },
    .{ .name = "kde_unstable", .url = "https://download.kde.org/unstable" },
    .{ .name = "xfce", .url = "https://archive.xfce.org/src" },
};

/// Replaces every `$(NAME_SITE)` in `url`. Null if one is not a known mirror.
fn expandSites(arena: Allocator, url: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < url.len) {
        if (std.mem.startsWith(u8, url[i..], "$(")) {
            const close = std.mem.indexOfScalarPos(u8, url, i, ')') orelse return null;
            const raw = url[i + 2 .. close];
            const stripped = if (std.mem.endsWith(u8, raw, "_SITE")) raw[0 .. raw.len - "_SITE".len] else raw;
            var lower_buf: [32]u8 = undefined;
            if (stripped.len > lower_buf.len) return null;
            const lower = std.ascii.lowerString(&lower_buf, stripped);
            var found: ?[]const u8 = null;
            for (sites) |site| if (std.mem.eql(u8, site.name, lower)) {
                found = site.url;
            };
            try out.appendSlice(arena, found orelse return null);
            i = close + 1;
        } else {
            try out.append(arena, url[i]);
            i += 1;
        }
    }
    return out.items;
}

const known_options = [_][]const u8{ "check", "cross", "strip", "lto", "static", "bootstrap" };
const known_archs = [_][]const u8{ "x86_64", "aarch64", "riscv64" };

const Func = struct {
    name: []const u8,
    line: usize,
    decorators: []const []const u8,
    /// The body, one level of indentation removed.
    body: []const u8,
};

fn contains(hay: []const []const u8, needle: []const u8) bool {
    for (hay) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

fn firstLine(t: []const u8) []const u8 {
    const e = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return std.mem.trimEnd(u8, t[0..e], " \t\r");
}

/// `name = rhs`, with the name a plain identifier and the operator a plain `=`.
fn assignment(t: []const u8) ?struct { name: []const u8, rhs: []const u8 } {
    if (t.len == 0 or !isIdentStart(t[0])) return null;
    var i: usize = 0;
    while (i < t.len and isIdentChar(t[i])) i += 1;
    const name = t[0..i];
    while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
    if (i >= t.len or t[i] != '=') return null;
    if (i + 1 < t.len and t[i + 1] == '=') return null;
    return .{ .name = name, .rhs = t[i + 1 ..] };
}

/// Removes the indentation of the first non-blank line from every line.
fn dedent(arena: Allocator, body: []const u8) Allocator.Error![]const u8 {
    var indent: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| {
        if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
        while (indent < l.len and (l[indent] == ' ' or l[indent] == '\t')) indent += 1;
        break;
    }
    var out: std.ArrayList(u8) = .empty;
    it = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try out.append(arena, '\n');
        first = false;
        var k: usize = 0;
        while (k < indent and k < l.len and (l[k] == ' ' or l[k] == '\t')) k += 1;
        try out.appendSlice(arena, l[k..]);
    }
    return out.items;
}

// ---- shell and TOML text -----------------------------------------------------------

/// One word for a shell. `$name` is left to expand (it came from `make_jobs`
/// and `destdir`); anything else unusual is double-quoted.
fn shellWord(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (s.len == 0) return "''";
    var plain = true;
    for (s, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_@%+=:,./-~", c) != null or
            (c == '$' and i + 1 < s.len and (isIdentStart(s[i + 1]) or s[i + 1] == '{'));
        if (!ok) plain = false;
    }
    if (plain) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (s, 0..) |c, i| {
        switch (c) {
            '"', '\\', '`' => {
                try out.append(arena, '\\');
                try out.append(arena, c);
            },
            '$' => {
                if (!(i + 1 < s.len and (isIdentStart(s[i + 1]) or s[i + 1] == '{'))) try out.append(arena, '\\');
                try out.append(arena, c);
            },
            else => try out.append(arena, c),
        }
    }
    try out.append(arena, '"');
    return out.items;
}

fn tomlString(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        '\r' => try out.appendSlice(arena, "\\r"),
        else => if (c < 0x20 or c == 0x7f) try out.print(arena, "\\u{x:0>4}", .{c}) else try out.append(arena, c),
    };
    try out.append(arena, '"');
    return out.items;
}

fn tomlList(arena: Allocator, items: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (items, 0..) |it, k| {
        if (k > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, try tomlString(arena, it));
    }
    try out.append(arena, ']');
    return out.items;
}

/// `key = '''...'''`: a literal multi-line string, so the shell text is verbatim.
fn tomlScript(arena: Allocator, out: *std.ArrayList(u8), key: []const u8, body: []const u8) Allocator.Error!void {
    const text = std.mem.trimEnd(u8, body, " \t\r\n");
    try out.print(arena, "{s} = ", .{key});
    if (std.mem.indexOf(u8, text, "'''") == null and std.mem.indexOfScalar(u8, text, '\r') == null) {
        try out.print(arena, "'''\n{s}\n'''\n", .{text});
        return;
    }
    // Rare: the text has ''' in it. Fall back to an escaped basic string.
    try out.appendSlice(arena, "\"\"\"\n");
    for (text) |c| switch (c) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        '"' => try out.appendSlice(arena, "\\\""),
        '\r' => try out.appendSlice(arena, "\\r"),
        else => try out.append(arena, c),
    };
    try out.appendSlice(arena, "\n\"\"\"\n");
}

// ---- function bodies -----------------------------------------------------------------

const Call = struct { args: []const Value, kwargs: []const Entry };

fn parseCall(p: *Parser) Allocator.Error!?Call {
    p.i += 1; // '('
    var args: std.ArrayList(Value) = .empty;
    var kwargs: std.ArrayList(Entry) = .empty;
    while (true) {
        p.skipWs();
        const c = p.peek() orelse return null;
        if (c == ')') {
            p.i += 1;
            break;
        }
        var is_kw = false;
        if (isIdentStart(c)) {
            const save = p.i;
            while (p.i < p.s.len and isIdentChar(p.s[p.i])) p.i += 1;
            const kw = p.s[save..p.i];
            p.skipWs();
            if (p.peek() == '=' and !(p.i + 1 < p.s.len and p.s[p.i + 1] == '=')) {
                p.i += 1;
                try kwargs.append(p.arena, .{ .key = kw, .value = try p.parseExpr() });
                is_kw = true;
            } else p.i = save;
        }
        if (!is_kw) try args.append(p.arena, try p.parseExpr());
        p.skipWs();
        const d = p.peek() orelse return null;
        if (d == ',') {
            p.i += 1;
        } else if (d != ')') return null;
    }
    return .{ .args = args.items, .kwargs = kwargs.items };
}

fn argText(arena: Allocator, v: Value) Allocator.Error!?[]const u8 {
    return switch (v) {
        .str => |s| s,
        .int => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        else => null,
    };
}

fn kwInt(c: Call, key: []const u8) ?i64 {
    for (c.kwargs) |k| if (std.mem.eql(u8, k.key, key)) return if (k.value == .int) k.value.int else null;
    return null;
}

fn kwStr(c: Call, key: []const u8) ?[]const u8 {
    for (c.kwargs) |k| if (std.mem.eql(u8, k.key, key)) return k.value.asStr();
    return null;
}

fn onlyKwargs(c: Call, allowed: []const []const u8) bool {
    for (c.kwargs) |k| if (!contains(allowed, k.key)) return false;
    return true;
}

/// Translates one `self.method(...)` statement into shell lines. Returns false
/// when it is not one of the few calls with a plain shell equivalent.
fn translateCall(arena: Allocator, code: []const u8, env: *const Env, pkgname: []const u8, out: *std.ArrayList(u8)) Allocator.Error!bool {
    if (!std.mem.startsWith(u8, code, "self.")) return false;
    var p: Parser = .{ .arena = arena, .s = code, .env = env, .i = 5 };
    const m0 = p.i;
    while (p.i < code.len and isIdentChar(code[p.i])) p.i += 1;
    const method = code[m0..p.i];
    if (p.peek() != '(') return false;
    const call = (try parseCall(&p)) orelse return false;
    p.skipWs();
    if (p.i != code.len) return false;

    var words: std.ArrayList([]const u8) = .empty;
    for (call.args) |a| {
        const t = (try argText(arena, a)) orelse return false;
        try words.append(arena, t);
    }
    const w = words.items;

    if (std.mem.eql(u8, method, "do")) {
        if (w.len == 0 or call.kwargs.len != 0) return false;
        for (w, 0..) |word, k| {
            if (k > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, try shellWord(arena, word));
        }
        try out.append(arena, '\n');
        return true;
    }
    if (std.mem.eql(u8, method, "install_license")) {
        if (w.len != 1 or call.kwargs.len != 0) return false;
        try out.print(arena, "install -Dm644 {s} \"$pkgdir/usr/share/licenses/{s}/{s}\"\n", .{ try shellWord(arena, w[0]), pkgname, std.fs.path.basename(w[0]) });
        return true;
    }
    if (std.mem.eql(u8, method, "install_file")) {
        if (w.len != 2 or !onlyKwargs(call, &.{ "mode", "name" })) return false;
        const mode = kwInt(call, "mode") orelse 0o644;
        const name = kwStr(call, "name") orelse std.fs.path.basename(w[0]);
        const dest = std.mem.trim(u8, w[1], "/");
        try out.print(arena, "install -Dm{o} {s} \"$pkgdir/{s}/{s}\"\n", .{ mode, try shellWord(arena, w[0]), dest, name });
        return true;
    }
    if (std.mem.eql(u8, method, "install_bin")) {
        if (w.len != 1 or call.kwargs.len != 0) return false;
        try out.print(arena, "install -Dm755 {s} \"$pkgdir/usr/bin/{s}\"\n", .{ try shellWord(arena, w[0]), std.fs.path.basename(w[0]) });
        return true;
    }
    if (std.mem.eql(u8, method, "install_man")) {
        if (w.len != 1 or call.kwargs.len != 0) return false;
        const base = std.fs.path.basename(w[0]);
        const ext = std.fs.path.extension(base);
        if (ext.len != 2 or !std.ascii.isDigit(ext[1])) return false;
        try out.print(arena, "install -Dm644 {s} \"$pkgdir/usr/share/man/man{c}/{s}\"\n", .{ try shellWord(arena, w[0]), ext[1], base });
        return true;
    }
    if (std.mem.eql(u8, method, "install_link")) {
        // install_link(path, target): a symlink at `path` (inside the destdir) to `target`.
        if (w.len != 2 or call.kwargs.len != 0) return false;
        const dest = std.mem.trim(u8, w[0], "/");
        if (std.fs.path.dirname(dest)) |parent| try out.print(arena, "mkdir -p \"$pkgdir/{s}\"\n", .{parent});
        try out.print(arena, "ln -sf {s} \"$pkgdir/{s}\"\n", .{ try shellWord(arena, w[1]), dest });
        return true;
    }
    if (std.mem.eql(u8, method, "install_lib")) {
        if (w.len != 1 or call.kwargs.len != 0) return false;
        try out.print(arena, "install -Dm755 {s} \"$pkgdir/usr/lib/{s}\"\n", .{ try shellWord(arena, w[0]), std.fs.path.basename(w[0]) });
        return true;
    }
    if (std.mem.eql(u8, method, "install_dir")) {
        if (w.len != 1 or !onlyKwargs(call, &.{"mode"})) return false;
        try out.print(arena, "install -dm{o} \"$pkgdir/{s}\"\n", .{ kwInt(call, "mode") orelse 0o755, std.mem.trim(u8, w[0], "/") });
        return true;
    }
    if (std.mem.eql(u8, method, "uninstall")) {
        if (w.len != 1 or call.kwargs.len != 0) return false;
        // cbuild's uninstall removes a file or a whole directory.
        try out.print(arena, "rm -rf \"$pkgdir/{s}\"\n", .{std.mem.trim(u8, w[0], "/")});
        return true;
    }
    return false;
}

/// Splits a statement into its code and the comment-only lines after it.
fn splitTrailingComments(t: []const u8) struct { code: []const u8, comments: []const u8 } {
    var end = t.len;
    while (end > 0) {
        const ls = if (std.mem.lastIndexOfScalar(u8, t[0 .. end - @intFromBool(t[end - 1] == '\n')], '\n')) |k| k + 1 else 0;
        const line = std.mem.trimEnd(u8, t[ls..end], "\n\r");
        const tl = std.mem.trim(u8, line, " \t");
        if (tl.len == 0 or (line.len > 0 and line[0] == '#')) {
            if (ls == 0) {
                end = 0;
                break;
            }
            end = ls;
        } else break;
    }
    return .{ .code = std.mem.trimEnd(u8, t[0..end], "\n\r \t"), .comments = t[end..] };
}

fn emitComments(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    // Comment lines only; blank lines are kept between comments but not at the ends.
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |l| {
        const tl = std.mem.trimEnd(u8, l, " \t\r");
        if (tl.len == 0) {
            try out.append(arena, '\n');
        } else if (tl[0] == '#') {
            try out.appendSlice(arena, tl);
            try out.append(arena, '\n');
        }
    }
}

/// Appends the shell for a function body to `out`. Statements with no plain
/// translation become `# TODO(cbuild)` comments and a note.
fn translateBody(arena: Allocator, f: Func, env: *const Env, pkgname: []const u8, notes: *std.ArrayList(Note), out: *std.ArrayList(u8)) Allocator.Error!void {
    const body = try dedent(arena, f.body);
    // Keep comments and blank lines before the first statement.
    var rest_start: usize = 0;
    var lead_lines: usize = 0;
    {
        var pos: usize = 0;
        while (pos < body.len) {
            const eol = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
            const line = std.mem.trimEnd(u8, body[pos..eol], " \t\r");
            if (line.len != 0 and line[0] != '#') break;
            if (line.len != 0) {
                try out.appendSlice(arena, line);
                try out.append(arena, '\n');
            }
            pos = if (eol < body.len) eol + 1 else body.len;
            rest_start = pos;
            lead_lines += 1;
        }
    }
    const stmts = try splitStatements(arena, body[rest_start..]);
    for (stmts) |st| {
        const parts = splitTrailingComments(st.text);
        const code = parts.code;
        if (code.len > 0) {
            var line_out: std.ArrayList(u8) = .empty;
            const first = firstLine(code);
            const ok = if (std.mem.eql(u8, first, "return") or std.mem.eql(u8, first, "pass")) true else try translateCall(arena, code, env, pkgname, &line_out);
            if (ok) {
                try out.appendSlice(arena, line_out.items);
            } else {
                try notes.append(arena, .{ .line = f.line + lead_lines + st.line, .kind = .todo, .text = try std.fmt.allocPrint(arena, "in {s}(): {s}", .{ f.name, first }) });
                var it = std.mem.splitScalar(u8, code, '\n');
                var k: usize = 0;
                while (it.next()) |l| : (k += 1) {
                    try out.print(arena, "# {s}{s}\n", .{ if (k == 0) "TODO(cbuild): " else "    ", std.mem.trimEnd(u8, l, "\r") });
                }
            }
        }
        try emitComments(arena, out, parts.comments);
    }
}

// ---- mapping ---------------------------------------------------------------------------

fn macroLine(arena: Allocator, out: *std.ArrayList(u8), macro: []const u8, args: []const []const u8) Allocator.Error!void {
    try out.appendSlice(arena, macro);
    for (args) |a| {
        try out.appendSlice(arena, " \\\n    ");
        try out.appendSlice(arena, try shellWord(arena, a));
    }
    try out.append(arena, '\n');
}

const Phase = enum { configure, build, check, install };

/// The hooks of one phase, in the order cbuild runs them.
fn findFunc(funcs: []const Func, name: []const u8) ?Func {
    for (funcs) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

pub fn convert(arena: Allocator, src: []const u8, in: Inputs) Allocator.Error!Converted {
    var notes: std.ArrayList(Note) = .empty;
    var env: Env = .empty;
    var order: std.ArrayList([]const u8) = .empty;
    var lines_of: std.StringHashMapUnmanaged(usize) = .empty;
    var funcs: std.ArrayList(Func) = .empty;
    var decorators: std.ArrayList([]const u8) = .empty;

    for (try splitStatements(arena, src)) |st| {
        const t = st.text;
        if (t[0] == '@') {
            try decorators.append(arena, firstLine(t));
            continue;
        }
        if (std.mem.startsWith(u8, t, "def ")) {
            const first = firstLine(t);
            var i: usize = 4;
            while (i < first.len and isIdentChar(first[i])) i += 1;
            const nl = std.mem.indexOfScalar(u8, t, '\n');
            try funcs.append(arena, .{
                .name = first[4..i],
                .line = st.line,
                .decorators = try arena.dupe([]const u8, decorators.items),
                .body = if (nl) |k| t[k + 1 ..] else "",
            });
            decorators.clearRetainingCapacity();
            continue;
        }
        if (assignment(t)) |a| {
            var p: Parser = .{ .arena = arena, .s = a.rhs, .env = &env };
            var v = try p.parseExpr();
            p.skipWs();
            if (p.i < p.s.len) v = .{ .unknown = std.mem.trim(u8, a.rhs, " \t\r\n") };
            if (!env.contains(a.name)) try order.append(arena, a.name);
            try env.put(arena, a.name, v);
            try lines_of.put(arena, a.name, st.line);
            continue;
        }
        decorators.clearRetainingCapacity();
        try notes.append(arena, .{ .line = st.line, .kind = .todo, .text = try std.fmt.allocPrint(arena, "statement not understood: {s}", .{firstLine(t)}) });
    }

    var consumed: std.StringHashMapUnmanaged(void) = .empty;
    const strOf = struct {
        fn get(e: *const Env, c: *std.StringHashMapUnmanaged(void), a: Allocator, key: []const u8) Allocator.Error!?[]const u8 {
            try c.put(a, key, {});
            const v = e.get(key) orelse return null;
            return switch (v) {
                .str => |s| s,
                .int => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
                else => null,
            };
        }
    }.get;

    // A list of strings; unknown or non-string items are noted and skipped.
    const listOf = struct {
        fn get(e: *const Env, c: *std.StringHashMapUnmanaged(void), a: Allocator, n: *std.ArrayList(Note), lines: *const std.StringHashMapUnmanaged(usize), key: []const u8) Allocator.Error![]const []const u8 {
            try c.put(a, key, {});
            const v = e.get(key) orelse return &.{};
            const line = lines.get(key) orelse 0;
            switch (v) {
                .list => |items| {
                    var out: std.ArrayList([]const u8) = .empty;
                    for (items) |it| {
                        if (it.asStr()) |s| {
                            try out.append(a, s);
                        } else try n.append(a, .{ .line = line, .kind = .todo, .text = try std.fmt.allocPrint(a, "`{s}` has an item that is not a plain string and was skipped", .{key}) });
                    }
                    return out.items;
                },
                .str => |s| return try a.dupe([]const u8, &.{s}),
                else => {
                    try n.append(a, .{ .line = line, .kind = .todo, .text = try std.fmt.allocPrint(a, "`{s}` is not a list of strings and was skipped", .{key}) });
                    return &.{};
                },
            }
        }
    }.get;

    const name = (try strOf(&env, &consumed, arena, "pkgname")) orelse "unknown";
    const version = (try strOf(&env, &consumed, arena, "pkgver")) orelse "0";
    const pkgrel: i64 = if (env.get("pkgrel")) |v| (if (v == .int) v.int else 0) else 0;
    try consumed.put(arena, "pkgrel", {});
    if (env.get("pkgname") == null or env.get("pkgname").? != .str)
        try notes.append(arena, .{ .line = 0, .kind = .todo, .text = "`pkgname` is missing or not a plain string" });
    if (env.get("pkgver") == null or env.get("pkgver").? != .str)
        try notes.append(arena, .{ .line = 0, .kind = .todo, .text = "`pkgver` is missing or not a plain string" });
    const summary = (try strOf(&env, &consumed, arena, "pkgdesc")) orelse "TODO";
    const license = (try strOf(&env, &consumed, arena, "license")) orelse "TODO";
    const homepage = try strOf(&env, &consumed, arena, "url");

    const hostdeps = try listOf(&env, &consumed, arena, &notes, &lines_of, "hostmakedepends");
    const builddeps = try listOf(&env, &consumed, arena, &notes, &lines_of, "makedepends");
    const checkdeps = try listOf(&env, &consumed, arena, &notes, &lines_of, "checkdepends");
    const rundeps = try listOf(&env, &consumed, arena, &notes, &lines_of, "depends");
    for ([_][]const []const u8{ hostdeps, builddeps, checkdeps, rundeps }) |deps| {
        for (deps) |d| if (std.mem.indexOfScalar(u8, d, ':') != null)
            try notes.append(arena, .{ .line = 0, .kind = .check, .text = try std.fmt.allocPrint(arena, "dependency '{s}' is a cbuild virtual (cmd:/so:/pc:); check it against our packages", .{d}) });
    }
    if (hostdeps.len + builddeps.len + checkdeps.len + rundeps.len > 0)
        try notes.append(arena, .{ .line = 0, .kind = .check, .text = "dependency names are Chimera's (e.g. -devel suffixes, zlib-ng-compat); check them against this tree" });

    // options and archs: keep the ones we know.
    var options: std.ArrayList([]const u8) = .empty;
    for (try listOf(&env, &consumed, arena, &notes, &lines_of, "options")) |o| {
        const bare = if (o.len > 0 and o[0] == '!') o[1..] else o;
        if (contains(&known_options, bare)) {
            try options.append(arena, o);
        } else try notes.append(arena, .{ .line = lines_of.get("options") orelse 0, .kind = .dropped, .text = try std.fmt.allocPrint(arena, "option '{s}' has no equivalent", .{o}) });
    }
    var archs: std.ArrayList([]const u8) = .empty;
    for (try listOf(&env, &consumed, arena, &notes, &lines_of, "archs")) |a| {
        const bare = if (a.len > 0 and (a[0] == '!' or a[0] == '~')) a[1..] else a;
        if (contains(&known_archs, bare)) {
            try archs.append(arena, if (a[0] == '~') try std.fmt.allocPrint(arena, "!{s}", .{bare}) else a);
        } else try notes.append(arena, .{ .line = lines_of.get("archs") orelse 0, .kind = .dropped, .text = try std.fmt.allocPrint(arena, "arch '{s}' is not one of ours", .{a}) });
    }

    // Sources: url list and checksums paired by position.
    var src_urls: std.ArrayList([]const u8) = .empty;
    var src_shas: std.ArrayList([]const u8) = .empty;
    try consumed.put(arena, "source", {});
    try consumed.put(arena, "sha256", {});
    if (env.get("source")) |sv| {
        switch (sv) {
            .str => |s| try src_urls.append(arena, s),
            .list => |items| for (items) |it| {
                if (it.asStr()) |s| try src_urls.append(arena, s) else try notes.append(arena, .{ .line = lines_of.get("source") orelse 0, .kind = .todo, .text = "a `source` item is not a plain string (it may use an unresolved f-string)" });
            },
            else => try notes.append(arena, .{ .line = lines_of.get("source") orelse 0, .kind = .todo, .text = try std.fmt.allocPrint(arena, "`source` could not be evaluated: {s}", .{if (sv == .unknown) sv.unknown else "not a string or list"}) }),
        }
    } else try notes.append(arena, .{ .line = 0, .kind = .todo, .text = "no `source`" });
    if (env.get("sha256")) |hv| {
        switch (hv) {
            .str => |s| try src_shas.append(arena, s),
            .list => |items| for (items) |it| {
                if (it.asStr()) |s| try src_shas.append(arena, s);
            },
            else => {},
        }
    }
    if (src_urls.items.len != src_shas.items.len)
        try notes.append(arena, .{ .line = lines_of.get("sha256") orelse 0, .kind = .todo, .text = try std.fmt.allocPrint(arena, "{d} source(s) but {d} sha256 value(s)", .{ src_urls.items.len, src_shas.items.len }) });
    for (src_urls.items) |*u| {
        if (std.mem.indexOf(u8, u.*, "$(") == null) continue;
        if (try expandSites(arena, u.*)) |full| {
            u.* = full;
        } else try notes.append(arena, .{ .line = lines_of.get("source") orelse 0, .kind = .todo, .text = try std.fmt.allocPrint(arena, "source URL uses a mirror variable this importer does not know: {s}", .{u.*}) });
    }
    for (src_urls.items) |u| if (std.mem.indexOf(u8, u, "{?") != null)
        try notes.append(arena, .{ .line = lines_of.get("source") orelse 0, .kind = .todo, .text = try std.fmt.allocPrint(arena, "source URL has a part that could not be evaluated: {s}", .{u}) });

    // Environment from tool_flags / env.
    var environment: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "tool_flags", "env" }) |key| {
        try consumed.put(arena, key, {});
        const v = env.get(key) orelse continue;
        if (v != .dict) {
            try notes.append(arena, .{ .line = lines_of.get(key) orelse 0, .kind = .todo, .text = try std.fmt.allocPrint(arena, "`{s}` is not a plain dict and was skipped", .{key}) });
            continue;
        }
        for (v.dict) |e| {
            if (std.mem.eql(u8, key, "tool_flags")) {
                var flags: std.ArrayList([]const u8) = .empty;
                if (e.value == .list) for (e.value.list) |f| if (f.asStr()) |s| try flags.append(arena, s);
                if (flags.items.len == 0) continue;
                try environment.print(arena, "export {s}=\"${{{s}}} {s}\"\n", .{ e.key, e.key, try std.mem.join(arena, " ", flags.items) });
            } else if (e.value.asStr()) |s| {
                try environment.print(arena, "export {s}={s}\n", .{ e.key, try shellWord(arena, s) });
            }
        }
    }

    // Build style and the steps.
    const style = try strOf(&env, &consumed, arena, "build_style");
    const cfg_args = try listOf(&env, &consumed, arena, &notes, &lines_of, "configure_args");
    const make_build_args = try listOf(&env, &consumed, arena, &notes, &lines_of, "make_build_args");
    const make_install_args = try listOf(&env, &consumed, arena, &notes, &lines_of, "make_install_args");
    const make_check_args = try listOf(&env, &consumed, arena, &notes, &lines_of, "make_check_args");
    const no_check = contains(options.items, "!check");
    // cports: build_style_defaults of gnu_configure has configure_gen = autoreconf.
    const configure_gen: []const []const u8 = if (env.contains("configure_gen"))
        try listOf(&env, &consumed, arena, &notes, &lines_of, "configure_gen")
    else
        &.{ "autoreconf", "-if", "-W", "none" };
    const use_env = if (env.get("make_use_env")) |v| (v == .boolean and v.boolean) else false;
    try consumed.put(arena, "make_use_env", {});
    const check_target = (try strOf(&env, &consumed, arena, "make_check_target")) orelse "check";

    var steps: [4]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty };
    const phase_names = [_][]const u8{ "configure", "build", "check", "install" };

    for (phase_names, 0..) |ph, k| {
        const out = &steps[k];
        var buf: [32]u8 = undefined;
        const init_name = std.fmt.bufPrint(&buf, "init_{s}", .{ph}) catch unreachable;
        if (findFunc(funcs.items, init_name)) |f| {
            // init hooks set variables for the phase; none can be translated.
            try notes.append(arena, .{ .line = f.line, .kind = .todo, .text = try std.fmt.allocPrint(arena, "{s}() sets variables for the {s} phase; port it by hand", .{ init_name, ph }) });
            try out.print(arena, "# TODO(cbuild): {s}() sets variables for this phase (cbuild line {d}); port it by hand\n", .{ init_name, f.line });
        }
        var pre_buf: [32]u8 = undefined;
        const pre = std.fmt.bufPrint(&pre_buf, "pre_{s}", .{ph}) catch unreachable;
        if (findFunc(funcs.items, pre)) |f| try translateBody(arena, f, &env, name, &notes, out);

        var do_buf: [32]u8 = undefined;
        const do_name = std.fmt.bufPrint(&do_buf, "do_{s}", .{ph}) catch unreachable;
        const replaces = findFunc(funcs.items, do_name) orelse findFunc(funcs.items, ph);
        if (replaces) |f| {
            try translateBody(arena, f, &env, name, &notes, out);
        } else if (style) |st| {
            try styleStep(arena, out, st, @as(Phase, @enumFromInt(k)), cfg_args, make_build_args, make_install_args, make_check_args, check_target, use_env, configure_gen, no_check);
        }
        var post_buf: [32]u8 = undefined;
        const post = std.fmt.bufPrint(&post_buf, "post_{s}", .{ph}) catch unreachable;
        if (findFunc(funcs.items, post)) |f| try translateBody(arena, f, &env, name, &notes, out);
    }
    if (style) |st| {
        const known = [_][]const u8{ "gnu_configure", "configure", "meson", "cmake", "makefile" };
        if (!contains(&known, st))
            try notes.append(arena, .{ .line = lines_of.get("build_style") orelse 0, .kind = .todo, .text = try std.fmt.allocPrint(arena, "build_style '{s}' is not translated; write the steps by hand", .{st}) });
    }

    // Subpackages and hooks nobody maps.
    for (funcs.items) |f| {
        var is_sub = false;
        for (f.decorators) |d| if (std.mem.startsWith(u8, d, "@subpackage")) {
            is_sub = true;
            try notes.append(arena, .{ .line = f.line, .kind = .check, .text = try std.fmt.allocPrint(arena, "{s}: not translated (devel, static and doc exist by default; add others with [subpackages.*])", .{d}) });
        };
        if (is_sub) continue;
        const handled = [_][]const u8{ "pre_configure", "do_configure", "configure", "post_configure", "pre_build", "do_build", "build", "post_build", "pre_check", "do_check", "check", "post_check", "pre_install", "do_install", "install", "post_install", "init_configure", "init_build", "init_check", "init_install" };
        if (!contains(&handled, f.name))
            try notes.append(arena, .{ .line = f.line, .kind = .todo, .text = try std.fmt.allocPrint(arena, "function {s}() is not a build hook this importer knows", .{f.name}) });
    }

    // Everything assigned that nothing used.
    for (order.items) |n| {
        if (consumed.contains(n)) continue;
        try notes.append(arena, .{ .line = lines_of.get(n) orelse 0, .kind = .dropped, .text = try std.fmt.allocPrint(arena, "`{s}` has no equivalent and was dropped", .{n}) });
    }
    if (in.has_files) try notes.append(arena, .{ .line = 0, .kind = .check, .text = "the template has a files/ directory; it was copied, check how the steps use it" });

    // The TOML.
    var o: std.ArrayList(u8) = .empty;
    try o.print(arena,
        \\# Imported from Chimera Linux cports: {s}
        \\# cports is BSD-2-Clause, Copyright (c) Chimera Linux contributors.
        \\# DRAFT, made by `dkbuild import-cbuild`: review every "TODO(cbuild)" and the
        \\# dependency names (they are Chimera's) before building.
        \\
    , .{in.origin});
    try o.print(arena, "name = {s}\nversion = {s}\nrelease = {d}\nsummary = {s}\nlicense = {s}\n", .{ try tomlString(arena, name), try tomlString(arena, version), pkgrel + 1, try tomlString(arena, summary), try tomlString(arena, license) });
    if (homepage) |h| try o.print(arena, "homepage = {s}\n", .{try tomlString(arena, h)});
    if (in.patches.len > 0) try o.print(arena, "patches = {s}\n", .{try tomlList(arena, in.patches)});
    inline for (.{ .{ "archs", archs.items }, .{ "hostdeps", hostdeps }, .{ "builddeps", builddeps }, .{ "checkdeps", checkdeps }, .{ "rundeps", rundeps }, .{ "options", options.items } }) |kv| {
        if (kv[1].len > 0) try o.print(arena, "{s} = {s}\n", .{ kv[0], try tomlList(arena, kv[1]) });
    }
    try o.appendSlice(arena, "\nsource = [\n");
    for (src_urls.items, 0..) |u, k| {
        const cut = std.mem.indexOfScalar(u8, u, '>') orelse u.len; // cbuild's `url>filename` renames the download
        const sha = if (k < src_shas.items.len) src_shas.items[k] else "";
        try o.print(arena, "    {{ url = {s}, sha256 = {s} }},\n", .{ try tomlString(arena, u[0..cut]), try tomlString(arena, sha) });
    }
    try o.appendSlice(arena, "]\n\n");
    if (environment.items.len > 0) try tomlScript(arena, &o, "environment", environment.items);
    const keys = [_][]const u8{ "setup", "build", "check", "install" };
    for (keys, 0..) |key, k| {
        const text = std.mem.trim(u8, steps[k].items, " \t\r\n");
        if (std.mem.eql(u8, key, "install")) {
            try tomlScript(arena, &o, key, if (text.len == 0) "# TODO(cbuild): no install step could be derived\ntrue" else text);
            if (text.len == 0) try notes.append(arena, .{ .line = 0, .kind = .todo, .text = "no install step could be derived" });
        } else if (text.len > 0) try tomlScript(arena, &o, key, text);
    }
    return .{ .name = name, .toml = o.items, .notes = notes.items };
}

fn styleStep(arena: Allocator, out: *std.ArrayList(u8), style: []const u8, phase: Phase, cfg: []const []const u8, mk: []const []const u8, mi: []const []const u8, mc: []const []const u8, check_target: []const u8, use_env: bool, gen: []const []const u8, no_check: bool) Allocator.Error!void {
    const eq = std.mem.eql;
    if (eq(u8, style, "gnu_configure")) switch (phase) {
        .configure => {
            // cbuild runs `configure_gen` (default: autoreconf) before configure.
            if (gen.len > 0) {
                for (gen, 0..) |w, i| {
                    if (i > 0) try out.append(arena, ' ');
                    try out.appendSlice(arena, try shellWord(arena, w));
                }
                try out.append(arena, '\n');
            }
            try macroLine(arena, out, "%configure", cfg);
        },
        .build => try macroLine(arena, out, "%make", mk),
        .check => if (!no_check) {
            try out.print(arena, "%make {s}", .{check_target});
            for (mc) |a| try out.print(arena, " {s}", .{try shellWord(arena, a)});
            try out.append(arena, '\n');
        },
        .install => try macroLine(arena, out, "%make_install", mi),
    } else if (eq(u8, style, "configure")) switch (phase) {
        .configure => {
            // cbuild's `configure` style runs the script with exactly configure_args.
            try macroLine(arena, out, "./configure", cfg);
        },
        .build => try macroLine(arena, out, "%make", mk),
        .check => if (!no_check) {
            try out.print(arena, "%make {s}", .{check_target});
            for (mc) |a| try out.print(arena, " {s}", .{try shellWord(arena, a)});
            try out.append(arena, '\n');
        },
        .install => try macroLine(arena, out, "%make_install", mi),
    } else if (eq(u8, style, "makefile")) switch (phase) {
        .configure => {},
        // cbuild's makefile style (build_style/makefile.py): PREFIX=/usr, unless
        // make_use_env, and STRIP=true PREFIX=/usr for the install.
        .build => {
            var args: std.ArrayList([]const u8) = .empty;
            if (!use_env) try args.append(arena, "PREFIX=/usr");
            try args.appendSlice(arena, mk);
            try macroLine(arena, out, "%make", args.items);
        },
        .check => if (!no_check) {
            try out.print(arena, "%make {s}", .{check_target});
            for (mc) |a| try out.print(arena, " {s}", .{try shellWord(arena, a)});
            try out.append(arena, '\n');
        },
        .install => {
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(arena, &.{ "STRIP=true", "PREFIX=/usr" });
            try args.appendSlice(arena, mi);
            try macroLine(arena, out, "%make_install", args.items);
        },
    } else if (eq(u8, style, "meson")) switch (phase) {
        .configure => try macroLine(arena, out, "%meson", cfg),
        .build => try out.appendSlice(arena, "%meson_build\n"),
        .check => {},
        .install => try out.appendSlice(arena, "%meson_install\n"),
    } else if (eq(u8, style, "cmake")) switch (phase) {
        .configure => try macroLine(arena, out, "%cmake", cfg),
        .build => try out.appendSlice(arena, "%cmake_build\n"),
        .check => {},
        .install => try out.appendSlice(arena, "%cmake_install\n"),
    };
}

// ---- files and the command -------------------------------------------------------------

const Dir = std.Io.Dir;
const recipe = @import("recipe.zig");

pub const Result = struct {
    name: []const u8,
    out_dir: []const u8,
    notes: []const Note,
    /// Null if the draft passes the recipe check, else why not.
    invalid: ?[]const u8,
};

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Reads `path` (a `template.py`, or the package directory holding one) and
/// writes `<out_root>/<name>/package.toml`, copying `patches/` and `files/`.
pub fn importPath(arena: Allocator, io: std.Io, path: []const u8, out_root: []const u8) !Result {
    var tpl = path;
    if (!std.mem.endsWith(u8, path, ".py")) tpl = try std.fs.path.join(arena, &.{ path, "template.py" });
    const src = try Dir.cwd().readFileAlloc(io, tpl, arena, .limited(4 << 20));
    const dir = std.fs.path.dirname(tpl) orelse ".";

    // patches/ (sorted) and files/ next to the template.
    var patches: std.ArrayList([]const u8) = .empty;
    const patches_dir = try std.fs.path.join(arena, &.{ dir, "patches" });
    if (Dir.cwd().openDir(io, patches_dir, .{ .iterate = true })) |d_const| {
        var d = d_const;
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            if (e.kind == .file and (std.mem.endsWith(u8, e.name, ".patch") or std.mem.endsWith(u8, e.name, ".diff")))
                try patches.append(arena, try arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, patches.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    } else |_| {}
    const files_dir = try std.fs.path.join(arena, &.{ dir, "files" });
    const has_files = if (Dir.cwd().access(io, files_dir, .{})) |_| true else |_| false;

    const conv = try convert(arena, src, .{ .origin = tpl, .patches = patches.items, .has_files = has_files });
    const out_dir = try std.fs.path.join(arena, &.{ out_root, conv.name });
    try Dir.cwd().createDirPath(io, out_dir);
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ out_dir, "package.toml" }), .data = conv.toml });
    for ([_]struct { from: []const u8, name: []const u8, copy: bool }{
        .{ .from = patches_dir, .name = "patches", .copy = patches.items.len > 0 },
        .{ .from = files_dir, .name = "files", .copy = has_files },
    }) |c| {
        if (!c.copy) continue;
        // "from/." copies the contents, so converting the same template twice (a
        // cports subpackage symlink points back at it) can't nest files/files.
        const dest = try std.fs.path.join(arena, &.{ out_dir, c.name });
        try Dir.cwd().createDirPath(io, dest);
        const res = try std.process.run(arena, io, .{ .argv = &.{ "cp", "-r", try std.fmt.allocPrint(arena, "{s}/.", .{c.from}), dest } });
        switch (res.term) {
            .exited => |code| if (code != 0) return error.CopyFailed,
            else => return error.CopyFailed,
        }
    }

    var diag: recipe.Diagnostic = .{};
    var invalid: ?[]const u8 = null;
    _ = recipe.parse(arena, conv.toml, &diag) catch |err| switch (err) {
        error.InvalidRecipe => invalid = diag.message,
        error.OutOfMemory => return err,
    };
    return .{ .name = conv.name, .out_dir = out_dir, .notes = conv.notes, .invalid = invalid };
}

pub fn printResult(r: Result) void {
    var todo: usize = 0;
    for (r.notes) |n| if (n.kind == .todo) {
        todo += 1;
    };
    say("{s} -> {s}/package.toml\n", .{ r.name, r.out_dir });
    for (r.notes) |n| {
        const tag = switch (n.kind) {
            .todo => "TODO   ",
            .dropped => "dropped",
            .check => "check  ",
        };
        if (n.line > 0) say("  {s} line {d}: {s}\n", .{ tag, n.line, n.text }) else say("  {s} {s}\n", .{ tag, n.text });
    }
    if (r.invalid) |why| {
        say("  => not yet a valid recipe: {s}\n", .{why});
    } else say("  => passes the recipe check{s}\n", .{if (todo > 0) ", but has TODOs to finish" else ""});
}

// ---- tests --------------------------------------------------------------------------------

fn evalExpr(arena: Allocator, env: *const Env, text: []const u8) !Value {
    var p: Parser = .{ .arena = arena, .s = text, .env = env };
    return p.parseExpr();
}

test "the reader evaluates strings, f-strings, lists, dicts and concatenation" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var env: Env = .empty;
    try env.put(a, "pkgver", .{ .str = "1.5" });
    try env.put(a, "url", .{ .str = "https://x.org" });

    try std.testing.expectEqualStrings("a'b\"c\n", (try evalExpr(a, &env, "\"a'b\\\"c\\n\"")).str);
    try std.testing.expectEqualStrings("https://x.org/d/p-1.5.tar.xz", (try evalExpr(a, &env, "f\"{url}/d/p-{pkgver}.tar.xz\"")).str);
    try std.testing.expectEqualStrings("ab", (try evalExpr(a, &env, "\"a\" \"b\"")).str);
    try std.testing.expectEqualStrings("ab", (try evalExpr(a, &env, "\"a\" + 'b'")).str);
    try std.testing.expectEqualStrings("{x}", (try evalExpr(a, &env, "f\"{{x}}\"")).str);
    try std.testing.expectEqualStrings("-j$jobs", (try evalExpr(a, &env, "f\"-j{self.make_jobs}\"")).str);
    try std.testing.expectEqual(@as(i64, 0o755), (try evalExpr(a, &env, "0o755")).int);
    try std.testing.expectEqual(true, (try evalExpr(a, &env, "True")).boolean);

    const list = (try evalExpr(a, &env, "[\"a\", # a comment\n    \"b\",\n    # another\n]")).list;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("b", list[1].str);
    const sum = (try evalExpr(a, &env, "[\"a\"] + [\"b\"]")).list;
    try std.testing.expectEqual(@as(usize, 2), sum.len);

    const d = (try evalExpr(a, &env, "{\"CXXFLAGS\": [\"-fno-rtti\"], \"X\": \"1\"}")).dict;
    try std.testing.expectEqualStrings("CXXFLAGS", d[0].key);
    try std.testing.expectEqualStrings("-fno-rtti", d[0].value.list[0].str);
}

test "what the reader cannot evaluate stays visible as unknown, never guessed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var env: Env = .empty;
    try env.put(a, "pkgver", .{ .str = "1.5" });

    try std.testing.expect((try evalExpr(a, &env, "some_call(1, 2)")) == .unknown);
    try std.testing.expect((try evalExpr(a, &env, "self.profile.arch")) == .unknown);
    try std.testing.expect((try evalExpr(a, &env, "\"x\" % pkgver")) == .unknown);
    try std.testing.expect((try evalExpr(a, &env, "[x for x in y]")) == .unknown);
    try std.testing.expect((try evalExpr(a, &env, "undefined_name")) == .unknown);
    // An f-string with a part we cannot evaluate is unknown, with the part shown.
    const v = try evalExpr(a, &env, "f\"a-{nothing}-{pkgver}\"");
    try std.testing.expect(v == .unknown);
    // A list with one odd item keeps the others.
    const l = (try evalExpr(a, &env, "[\"a\", f(1), \"c\"]")).list;
    try std.testing.expectEqual(@as(usize, 3), l.len);
    try std.testing.expect(l[1] == .unknown);
    try std.testing.expectEqualStrings("c", l[2].str);
}

test "statements: brackets, triple quotes, continuations and indented bodies stay together" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const stmts = try splitStatements(a,
        \\pkgname = "x"
        \\opts = [
        \\    "a",  # note
        \\    "b",
        \\]
        \\doc = """
        \\not = a statement
        \\"""
        \\long = "a" \
        \\    "b"
        \\
        \\
        \\def build(self):
        \\    self.do("make")
        \\
        \\    if True:
        \\        pass
        \\@subpackage("x-devel")
        \\def _(self):
        \\    return 1
        \\
    );
    try std.testing.expectEqual(@as(usize, 7), stmts.len);
    try std.testing.expectEqual(@as(usize, 2), stmts[1].line);
    try std.testing.expect(std.mem.indexOf(u8, stmts[2].text, "not = a statement") != null);
    try std.testing.expect(std.mem.startsWith(u8, stmts[4].text, "def build"));
    try std.testing.expect(std.mem.indexOf(u8, stmts[4].text, "pass") != null);
    try std.testing.expect(stmts[5].text[0] == '@');
}

test "shellWord quotes what a shell would split, keeps $vars expandable" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expectEqualStrings("--prefix=/usr", try shellWord(a, "--prefix=/usr"));
    try std.testing.expectEqualStrings("-j$jobs", try shellWord(a, "-j$jobs"));
    try std.testing.expectEqualStrings("\"a b\"", try shellWord(a, "a b"));
    try std.testing.expectEqualStrings("\"*.c\"", try shellWord(a, "*.c"));
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", try shellWord(a, "say \"hi\""));
    try std.testing.expectEqualStrings("''", try shellWord(a, ""));
    try std.testing.expectEqualStrings("\"cost \\$5\"", try shellWord(a, "cost $5"));
}

const sample_gnu =
    \\pkgname = "foo"
    \\pkgver = "2.0"
    \\pkgrel = 3
    \\build_style = "gnu_configure"
    \\configure_args = ["--enable-x", "--with-y=/usr/lib"]
    \\make_install_args = ["V=1"]
    \\hostmakedepends = ["pkgconf"]
    \\makedepends = ["zlib-ng-compat-devel"]
    \\depends = ["bash"]
    \\pkgdesc = "A foo"
    \\license = "MIT"
    \\url = "https://foo.org"
    \\source = f"{url}/foo-{pkgver}.tar.gz"
    \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    \\options = ["!check", "!scanshlibs", "bootstrap"]
    \\hardening = ["vis"]
    \\
    \\
    \\def post_install(self):
    \\    self.install_license("COPYING")
    \\    # a comment kept
    \\    self.install_file("foo.conf", "etc", mode=0o600)
    \\    self.install_bin("tools/foo")
    \\    self.do("sh", "-c", "echo hi > out")
    \\    self.mystery(1)
    \\
;

test "conversion maps variables, build style and trivial calls; the rest is a TODO" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const c = try convert(a, sample_gnu, .{ .origin = "main/foo/template.py" });
    try std.testing.expectEqualStrings("foo", c.name);
    const t = c.toml;
    try std.testing.expect(std.mem.indexOf(u8, t, "Imported from Chimera Linux cports: main/foo/template.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "release = 4\n") != null); // cbuild counts from 0
    try std.testing.expect(std.mem.indexOf(u8, t, "url = \"https://foo.org/foo-2.0.tar.gz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "hostdeps = [\"pkgconf\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "builddeps = [\"zlib-ng-compat-devel\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "rundeps = [\"bash\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "options = [\"!check\", \"bootstrap\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "%configure \\\n    --enable-x \\\n    --with-y=/usr/lib\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "%make_install \\\n    V=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "install -Dm644 COPYING \"$pkgdir/usr/share/licenses/foo/COPYING\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "# a comment kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "install -Dm600 foo.conf \"$pkgdir/etc/foo.conf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "install -Dm755 tools/foo \"$pkgdir/usr/bin/foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "sh -c \"echo hi > out\"") != null);
    // Not understood: kept as a visible comment, and noted.
    try std.testing.expect(std.mem.indexOf(u8, t, "# TODO(cbuild): self.mystery(1)") != null);
    // !check means no check step.
    try std.testing.expect(std.mem.indexOf(u8, t, "\ncheck = ") == null);

    var todo: usize = 0;
    var dropped_hardening = false;
    var dropped_option = false;
    for (c.notes) |n| {
        if (n.kind == .todo) todo += 1;
        if (n.kind == .dropped and std.mem.indexOf(u8, n.text, "hardening") != null) dropped_hardening = true;
        if (n.kind == .dropped and std.mem.indexOf(u8, n.text, "scanshlibs") != null) dropped_option = true;
    }
    try std.testing.expectEqual(@as(usize, 1), todo);
    try std.testing.expect(dropped_hardening and dropped_option);

    // And the draft is a valid recipe.
    var diag: recipe.Diagnostic = .{};
    const r = try recipe.parse(a, t, &diag);
    try std.testing.expectEqualStrings("foo", r.name);
    try std.testing.expectEqual(@as(u32, 4), r.release);
}

test "a draft with a missing checksum is reported invalid, not silently accepted" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const c = try convert(a,
        \\pkgname = "bar"
        \\pkgver = "1"
        \\pkgrel = 0
        \\pkgdesc = "x"
        \\license = "MIT"
        \\source = f"https://x.org/{nothing_known}.tar.gz"
        \\
    , .{ .origin = "bar" });
    var todo = false;
    for (c.notes) |n| if (n.kind == .todo and std.mem.indexOf(u8, n.text, "source") != null) {
        todo = true;
    };
    try std.testing.expect(todo);
    var diag: recipe.Diagnostic = .{};
    try std.testing.expectError(error.InvalidRecipe, recipe.parse(a, c.toml, &diag));
}

test "meson style, tool_flags, a replacing do_build and cbuild url renames" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const c = try convert(a,
        \\pkgname = "m"
        \\pkgver = "1"
        \\pkgrel = 0
        \\build_style = "meson"
        \\configure_args = ["-Dx=true"]
        \\tool_flags = {"CFLAGS": ["-O1", "-g0"]}
        \\pkgdesc = "m"
        \\license = "MIT"
        \\source = "https://x.org/m.tgz>m-1.tgz"
        \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\
        \\def do_build(self):
        \\    self.do("ninja", "-C", "build")
        \\
    , .{ .origin = "m" });
    const t = c.toml;
    try std.testing.expect(std.mem.indexOf(u8, t, "url = \"https://x.org/m.tgz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "export CFLAGS=\"${CFLAGS} -O1 -g0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "%meson \\\n    -Dx=true") != null);
    // do_build replaces the style's build step.
    try std.testing.expect(std.mem.indexOf(u8, t, "ninja -C build") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "%meson_build") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "%meson_install") != null);
}

test "an unknown build style leaves a placeholder install and says so" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const c = try convert(a,
        \\pkgname = "p"
        \\pkgver = "1"
        \\pkgrel = 0
        \\build_style = "python_pep517"
        \\pkgdesc = "p"
        \\license = "MIT"
        \\source = "https://x.org/p.tgz"
        \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\
    , .{ .origin = "p" });
    try std.testing.expect(std.mem.indexOf(u8, c.toml, "TODO(cbuild): no install step") != null);
    var styled = false;
    for (c.notes) |n| if (std.mem.indexOf(u8, n.text, "python_pep517") != null) {
        styled = true;
    };
    try std.testing.expect(styled);
}

test "path joins, str.replace and install_link" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var env: Env = .empty;
    try env.put(a, "pkgver", .{ .str = "2.7.1" });
    try std.testing.expectEqualStrings("$pkgfiles/x.pc", (try evalExpr(a, &env, "self.files_path / \"x.pc\"")).str);
    try std.testing.expectEqualStrings("$pkgdir/usr/bin/tool", (try evalExpr(a, &env, "self.destdir / \"usr/bin\" / \"tool\"")).str);
    try std.testing.expectEqualStrings("R_2_7_1", (try evalExpr(a, &env, "f\"R_{pkgver.replace('.', '_')}\"")).str);
    // Other string methods are still unknown.
    try std.testing.expect((try evalExpr(a, &env, "pkgver.upper()")) == .unknown);

    const c = try convert(a,
        \\pkgname = "l"
        \\pkgver = "1"
        \\pkgrel = 0
        \\pkgdesc = "l"
        \\license = "MIT"
        \\source = "https://x.org/l.tgz"
        \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\
        \\def install(self):
        \\    self.install_link("usr/bin/cc", "clang")
        \\    self.install_file(self.files_path / "l.pc", "usr/lib/pkgconfig")
        \\
    , .{ .origin = "l" });
    try std.testing.expect(std.mem.indexOf(u8, c.toml, "mkdir -p \"$pkgdir/usr/bin\"\nln -sf clang \"$pkgdir/usr/bin/cc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.toml, "install -Dm644 $pkgfiles/l.pc \"$pkgdir/usr/lib/pkgconfig/l.pc\"") != null);
}

test "cbuild mirror variables in source URLs are expanded, unknown ones are flagged" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expectEqualStrings("https://download.savannah.nongnu.org/releases/acl/acl-2.4.0.tar.gz", (try expandSites(a, "$(NONGNU_SITE)/acl/acl-2.4.0.tar.gz")).?);
    try std.testing.expectEqualStrings("https://ftp.gnu.org/gnu/make/make-4.4.tar.gz", (try expandSites(a, "$(GNU_SITE)/make/make-4.4.tar.gz")).?);
    try std.testing.expectEqualStrings("https://download.kde.org/unstable/x", (try expandSites(a, "$(KDE_UNSTABLE_SITE)/x")).?);
    try std.testing.expect((try expandSites(a, "$(NOPE_SITE)/x")) == null);
    try std.testing.expect((try expandSites(a, "$(GNU_SITE")) == null);
}

test "uninstall removes directories, configure does not repeat --prefix, makefile check runs the target" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const c = try convert(a,
        \\pkgname = "q"
        \\pkgver = "1"
        \\pkgrel = 0
        \\build_style = "configure"
        \\configure_args = ["--prefix=/usr", "--shared"]
        \\pkgdesc = "q"
        \\license = "MIT"
        \\source = "https://x.org/q.tgz"
        \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\
        \\def post_install(self):
        \\    self.uninstall("usr/share/doc")
        \\
    , .{ .origin = "q" });
    try std.testing.expect(std.mem.indexOf(u8, c.toml, "rm -rf \"$pkgdir/usr/share/doc\"") != null);
    // cbuild's configure style adds nothing of its own to configure_args.
    try std.testing.expect(std.mem.indexOf(u8, c.toml, "./configure \\\n    --prefix=/usr \\\n    --shared\n") != null);

    const m = try convert(a,
        \\pkgname = "mk"
        \\pkgver = "1"
        \\pkgrel = 0
        \\build_style = "makefile"
        \\make_check_args = ["-j1"]
        \\make_check_target = "test"
        \\pkgdesc = "mk"
        \\license = "MIT"
        \\source = "https://x.org/mk.tgz"
        \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\
    , .{ .origin = "mk" });
    try std.testing.expect(std.mem.indexOf(u8, m.toml, "%make test -j1") != null);
}

test "makefile style passes PREFIX like cbuild does, and not with make_use_env" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const head =
        \\pkgname = "mk"
        \\pkgver = "1"
        \\pkgrel = 0
        \\build_style = "makefile"
        \\pkgdesc = "mk"
        \\license = "MIT"
        \\source = "https://x.org/mk.tgz"
        \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\
    ;
    const plain = try convert(a, head, .{ .origin = "mk" });
    try std.testing.expect(std.mem.indexOf(u8, plain.toml, "%make \\\n    PREFIX=/usr\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.toml, "%make_install \\\n    STRIP=true \\\n    PREFIX=/usr\n") != null);
    const env = try convert(a, head ++ "make_use_env = True\n", .{ .origin = "mk" });
    try std.testing.expect(std.mem.indexOf(u8, env.toml, "PREFIX=/usr\n") != null); // install still has it
    try std.testing.expect(std.mem.indexOf(u8, env.toml, "build = '''\n%make\n'''") != null);
}

test "gnu_configure runs autoreconf unless configure_gen is empty or replaced" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const head =
        \\pkgname = "g"
        \\pkgver = "1"
        \\pkgrel = 0
        \\build_style = "gnu_configure"
        \\pkgdesc = "g"
        \\license = "MIT"
        \\source = "https://x.org/g.tgz"
        \\sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\
    ;
    const dflt = try convert(a, head, .{ .origin = "g" });
    try std.testing.expect(std.mem.indexOf(u8, dflt.toml, "setup = '''\nautoreconf -if -W none\n%configure\n") != null);
    const none = try convert(a, head ++ "configure_gen = []\n", .{ .origin = "g" });
    try std.testing.expect(std.mem.indexOf(u8, none.toml, "setup = '''\n%configure\n") != null);
    const custom = try convert(a, head ++ "configure_gen = [\"./bootstrap\"]\n", .{ .origin = "g" });
    try std.testing.expect(std.mem.indexOf(u8, custom.toml, "setup = '''\n./bootstrap\n%configure\n") != null);
}
