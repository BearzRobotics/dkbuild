# toml-zig API guide

How to read, change and write TOML by hand with toml-zig. For a terse
reference see `docs/manpages/toml-zig.3.md`; for the file syntax see
`docs/manpages/toml-syntax.5.md`. The examples here have counterparts in
`src/api_examples.zig`, which `zig build test` compiles and runs against
Zig 0.17. They are copies kept by hand, adapted to test their results.

Examples use this file, called `config` below:

```toml
# DKDE panel
title = "DKDE"

[panel]
position = "bottom"   # top|bottom
height = 32
opacity = 0.9
visible = true

[[panel.widget]]
name = "clock"

[[panel.widget]]
name = "tray"
```

## 1. Add the dependency

```zig
// build.zig.zon
.dependencies = .{ .toml = .{ .path = "../toml-zig" } },

// build.zig
exe.root_module.addImport("toml", b.dependency("toml", .{}).module("toml"));
```

Then `const toml = @import("toml");`.

## 2. The mental model

- You parse text into a **`Document`**. It owns one arena; `doc.deinit()` frees
  everything in it at once.
- `doc.root` is a **`*Table`**: an ordered map of `[]const u8` keys to
  **`Value`**s.
- A `Value` is a union: `.string`, `.integer` (i64), `.float` (f64), `.boolean`,
  `.datetime`, `.array` (`*Array`) or `.table` (`*Table`).
- Everything you get back is *borrowed*: it points into the arena and dies with
  `deinit`. Copy it out if you need it longer.

## 3. Parse

```zig
var diag: toml.Diagnostic = .{};
var doc = try toml.Document.parse(gpa, config, .{}, &diag);
defer doc.deinit();
```

`diag` is optional (pass `null`). On failure `parse` returns an error and
fills `diag` with a 1-based line and column and a message:

```zig
var doc = toml.Document.parse(gpa, text, .{}, &diag) catch |e| {
    std.log.err("config: {f}: {t}", .{ diag, e }); // e.g. "2:1: duplicate key: Syntax"
    return e;
};
```

Errors are `Syntax`, `InvalidUtf8`, `LimitExceeded`, `OutOfMemory`. Only the
first problem is reported.

### From a file or stream

`parseReader` takes any `*std.Io.Reader` and never holds the whole input:

```zig
var file = try std.Io.Dir.cwd().openFile(io, "config.toml", .{});
defer file.close(io);
var buf: [4096]u8 = undefined;
var reader = file.reader(io, &buf);
var doc = try toml.Document.parseReader(gpa, &reader.interface, .{}, &diag);
defer doc.deinit();
```

(`io` comes from `std.process.Init` in `main`, or from your own `std.Io`.)

### Options

```zig
.{}                                  // TOML 1.1, 16 MiB max, depth 64
.{ .version = .v1_0 }                // reject 1.1-only syntax
.{ .max_bytes = 1 << 20, .max_depth = 16, .max_key_depth = 16 }   // tighter limits for untrusted input
```

`max_depth` (default 64) limits arrays and inline tables inside one another.
`max_key_depth` (default 128) limits the key segments from the root to a value,
counting `[a.b.c]` headers and dotted keys. `write` returns
`error.NestingTooDeep` for a tree more than 1024 levels deep, which only code
that builds trees itself (or raises these limits) can produce.

Exceeding a limit gives `error.LimitExceeded`.

`max_bytes` limits the input, not memory: many tiny tables can take about 90
times the input size. For untrusted input, keep `max_bytes` small, or give
`parse` an allocator with a budget (it then fails with `error.OutOfMemory`).

## 4. Read values

Typed getters return an optional: `null` if the key is missing **or** has a
different type. That makes defaults one line:

```zig
const title = doc.root.getString("title") orelse "untitled";

const panel = doc.root.getTable("panel") orelse return error.MissingPanel;
const height = panel.getInt("height") orelse 24;
const opacity = panel.getFloat("opacity") orelse 1.0; // an integer is accepted too
const visible = panel.getBool("visible") orelse true;
```

If you must tell "missing" from "wrong type", use `get`, which returns the raw
`?Value`, and switch on it:

```zig
if (doc.root.lookup("panel.position")) |v| {
    switch (v) {
        .string => |s| std.debug.print("position {s}\n", .{s}),
        else => return error.WrongType,
    }
} else return error.Missing;
```

`lookup` takes a dotted path. It splits on `.`, so a key that itself contains
a dot must be reached with `get` one level at a time. It does not step into
arrays.

### Arrays and arrays of tables

An array is `*Array` with its elements in `items.items`. For `[[header]]`
sections `is_table_array` is true and each element is a `.table`:

```zig
const widgets = panel.getArray("widget") orelse return error.Missing;
for (widgets.items.items) |item| {
    const name = item.table.getString("name") orelse continue;
    std.debug.print("widget {s}\n", .{name});
}
```

TOML allows mixed-type arrays, so for plain arrays check each element's tag:

```zig
// `arr` is any `*toml.Array`; `use` stands for your own code.
for (arr.items.items) |item| switch (item) {
    .integer => |n| use(n),
    else => {},
};
```

### Walking a table

`entries` is an ordered hash map; iteration order is file order:

```zig
var it = panel.entries.iterator();
while (it.next()) |e| {
    std.debug.print("{s}: {s}\n", .{ e.key_ptr.*, e.value_ptr.*.typeName() });
}
```

### Dates and times

`.datetime` holds optional `date`, `time` and `offset_minutes`. Which are set
tells you which of the four TOML forms it was:

```zig
const dt = doc.root.get("when").?.datetime;   // when = 1979-05-27T07:32:00-07:00
dt.date.?.year;        // 1979
dt.time.?.hour;        // 7
dt.offset_minutes.?;   // -420
std.debug.print("{f}\n", .{dt});               // prints it back as TOML
```

## 5. Change values

Set by path. Missing intermediate tables are created:

```zig
try doc.set(&.{ "panel", "height" }, .{ .integer = 40 });
try doc.set(&.{ "net", "retries" }, .{ .integer = 3 });   // creates [net]
```

**Memory rule:** anything you store must live in the document's arena. For
integers, floats and booleans that is automatic. For strings, copy with
`dupe`:

```zig
try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("top") });
```

Storing a string literal is safe, because it lives as long as the program. A
slice of memory that you free or reuse later is not.
When in doubt, `dupe`.

`set` fails with `error.NotATable` if a path segment already holds something
that is not a table (setting `title.x` when `title` is a string).

Remove a key (its comments go with it):

```zig
_ = panel.remove("opacity");   // returns whether it existed
```

### Building a document from nothing

```zig
var doc = try toml.Document.init(gpa);
defer doc.deinit();

const a = doc.allocator();
const ports = try a.create(toml.Array);
ports.* = .{};
try ports.items.append(a, .{ .integer = 80 });
try ports.items.append(a, .{ .integer = 443 });

try doc.set(&.{ "server", "host" }, .{ .string = try doc.dupe("localhost") });
try doc.set(&.{ "server", "ports" }, .{ .array = ports });
```

writes

```toml
[server]
host = "localhost"
ports = [80, 443]
```

Memory from replaced or removed values stays in the arena until `deinit`. A
long-lived document edited in a loop grows; rebuild it now and then.

## 6. Comments

Comments in a parsed file are kept: lines above a key or `[header]` (with the
blank lines that separate groups), a trailing comment, and comments after the
last item. They stay with their item through edits and are dropped when you
remove the key. Changing a value keeps its comments.

Comments *inside* an array or an inline table are not kept.

Add or replace comments with `setComments`. Each `before` line is `#...` or
empty; `after` starts with `#`. Strings are copied. A bad line gives
`error.InvalidComment`; an unknown path gives `error.NotFound`; a path into
an inline table gives `error.CommentsNotSupported`.

```zig
try doc.setComments(&.{ "panel", "height" }, .{
    .before = &.{"# pixels"},
    .after = "# was 32",
});
```

Read them back with `Table.commentsOf(key)`. A table written as a `[section]`
keeps its comments on `table.header`; `setComments` on its path sets those.
Comments after the last item are `doc.root.footer`.

## 7. Write

To a string (caller frees):

```zig
const out = try doc.toOwnedString(gpa);
defer gpa.free(out);
```

`write` first checks the whole tree. If something has no TOML form (text that
is not UTF-8, a comment line that does not start with `#`, a date such as
month 13) it returns `error.InvalidValue` and writes nothing.

To any `std.Io.Writer`, such as a file:

```zig
var file = try std.Io.Dir.cwd().createFile(io, "config.toml", .{});
defer file.close(io);
var buf: [4096]u8 = undefined;
var w = file.writer(io, &buf);
try doc.write(gpa, &w.interface);
try w.interface.flush();
```

Output order is key insertion order, with scalar keys before sub-tables. Dotted
keys stay dotted keys.
Spacing, quote style and multi-line arrays are normalized. The result is valid
TOML 1.0 and 1.1 and parses back to the same keys and values. To save safely, write to a
temporary file and rename it over the original; the library does not touch the
file system.

## 8. Quick reference

| Task | Call |
|---|---|
| Parse a slice | `Document.parse(gpa, text, opts, &diag)` |
| Parse a stream | `Document.parseReader(gpa, &reader, opts, &diag)` |
| Empty document | `Document.init(gpa)` |
| Free | `doc.deinit()` |
| Typed read | `t.getString / getInt / getFloat / getBool / getTable / getArray` |
| Raw read | `t.get(key)`, `t.lookup("a.b.c")` |
| Set by path | `doc.set(&.{"a","b"}, value)` |
| Copy a string in | `doc.dupe(s)` |
| Remove | `t.remove(key)` |
| Comments | `doc.setComments(path, c)`, `t.commentsOf(key)` |
| Write | `doc.write(gpa, &writer)`, `doc.toOwnedString(gpa)` |

## 9. Pitfalls

- A getter returning `null` can mean "wrong type" — `height = "32"` is a
  string, so `getInt("height")` is `null`.
- Do not keep a string from the document after `deinit`.
- `lookup("a.b")` will not find a key literally named `"a.b"`.
- Integers are `i64`; a larger literal is a `Syntax` error. So is a float too
  large for `f64` (such as `1e400`). Write `inf` for infinity. A value too
  small to represent rounds to zero.
- `put` on a `Table` does not copy the key or value; use `doc.set`, or
  allocate from `doc.allocator()` yourself.
