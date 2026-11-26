# NAME

toml-zig - TOML 1.1.0 / 1.0.0 parser, editor and writer for Zig

# SYNOPSIS

```zig
const toml = @import("toml");

var diag: toml.Diagnostic = .{};
var doc = try toml.Document.parse(gpa, text, .{}, &diag);
defer doc.deinit();

const pos = doc.root.lookup("panel.position");
try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("top") });
const out = try doc.toOwnedString(gpa); // caller frees
```

Build setup (`build.zig.zon`, then `build.zig`):

```zig
.dependencies = .{ .toml = .{ .path = "../toml-zig" } },

exe.root_module.addImport("toml", b.dependency("toml", .{}).module("toml"));
```

# DESCRIPTION

toml-zig reads TOML into an in-memory tree, lets a program inspect and change

the tree, and writes it back as TOML. It targets Zig 0.17 and depends only on

the standard library. It performs no file-system or operating-system calls

itself: input comes from a byte slice or any `std.Io.Reader`, output goes to

any `std.Io.Writer`, so the caller decides where bytes live.

A **Document** owns a single arena allocator. Every string, table and array

reachable from `Document.root` is allocated there, and `Document.deinit` frees

all of it at once. Nothing inside a document is freed individually.

A tutorial with worked examples is in `docs/api.md`. The syntax itself is

described in **toml-syntax**(5).

# CONVENTIONS

`gpa` is a `std.mem.Allocator` used for scratch memory and for the arena's

backing storage. A value described as *borrowed* lives in the document's arena

and is invalid after `deinit`. Function names are given as `Type.function`.

"Path" means either a dotted string (`"a.b.c"`, for `lookup`) or a slice of

key segments (`&.{ "a", "b", "c" }`, for `set` and `setComments`).

# TYPES

**Document**
: Owns the arena and the root table. Fields: `arena`, `root: *Table`.

**Value**
: A tagged union: `string: []const u8`, `integer: i64`, `float: f64`,
  `boolean: bool`, `datetime: Datetime`, `array: *Array`, `table: *Table`.
  `Value.typeName` returns the tag name.

**Table**
: An insertion-ordered map from key to `Value` (`entries`), plus `kind`,
  `header` comments, `key_comments`, and `footer` (root only).

**Array**
: `items: std.ArrayList(Value)` and `is_table_array`, true for an array made
  of `[[header]]` sections.

**TableKind**
: How a table came to exist: `implicit`, `explicit`, `dotted`, `inline_table`.
  The parser uses it to decide which later definitions are legal.

**Datetime**, **Date**, **Time**
: `Datetime` has optional `date: ?Date`, `time: ?Time` and
  `offset_minutes: ?i16` (minutes east of UTC; 0 is `Z`). Which fields are set
  selects among offset date-time, local date-time, local date and local time.
  `Date` is `year: u16, month: u8, day: u8`; `Time` is `hour, minute, second:
  u8` and `nanosecond: u32`. `Datetime` has a `format` method, so
  `std.fmt` prints it with `{f}`.

**Comments**
: `before: []const []const u8` (lines above an item, each `#...` or empty)
  and `after: ?[]const u8` (a trailing `#...` comment).

**Options**
: `version: Version = .v1_1`, `max_depth: u32 = 64` (nesting of arrays plus
  inline tables), `max_key_depth: u32 = 128` (key segments from the root to a
  value, counting headers and dotted keys), `max_bytes: usize = 16 MiB`.

**Version**
: `.v1_0` or `.v1_1`.

**Diagnostic**
: `line: usize`, `column: usize` (both 1-based) and `message: []const u8`
  (a static string). Prints as `line:column: message` with `{f}`.

# FUNCTIONS

## Document

`Document.init(gpa) !Document`
: An empty document, for building one with `set`.

`Document.parse(gpa, source, options, diag) ParseError!Document`
: Parse UTF-8 `source`. The slice is not retained. `diag` may be `null`.

`Document.parseReader(gpa, reader, options, diag) ParseReaderError!Document`
: Parse incrementally from a `*std.Io.Reader`. The input is never held whole.
  Fails with `LimitExceeded` after `options.max_bytes` bytes and with
  `ReadFailed` if the reader fails.

`Document.deinit()`
: Free everything. The document must not be used afterwards.

`Document.allocator() Allocator`
: The arena allocator. Use it for any storage placed in the tree.

`Document.dupe(s) ![]const u8`
: Copy `s` into the arena, for use as a string value or key.

`Document.set(path, value) !void`
: Set `a.b.c = value`, creating missing intermediate tables. Fails with
  `NotATable` if a segment already holds a non-table. The value must already
  be arena-owned.

`Document.setComments(path, comments) !void`
: Attach comments to the item at `path` (its `key = value` line, or its
  `[header]` line for a table written as a section). Strings are copied. Fails
  with `NotFound`, `InvalidComment`, or `CommentsNotSupported` for an item
  inside an inline table.

`Document.write(gpa, writer) WriteError!void`
: Write TOML to a `*std.Io.Writer`.

`Document.toOwnedString(gpa) WriteError![]u8`
: Return the TOML text; the caller frees it with `gpa`.

## Table

`get(key) ?Value`, `getPtr(key) ?*Value`
: Raw access. `getPtr` allows replacing a value in place.

`getString`, `getInt`, `getBool`, `getTable`, `getArray`
: Typed getters. Each returns `null` both when the key is absent and when the
  value has a different type.

`getFloat(key) ?f64`
: As above, but an integer value is converted, so `size = 12` satisfies a
  float key.

`lookup(path) ?Value`
: Follow a dotted string through nested tables. Segments split on `.`, so a
  key that itself contains a dot must be fetched with `get`. Does not descend
  into arrays.

`count() usize`
: Number of entries.

`put(arena, key, value) !void`
: Set one key, replacing an existing value and keeping its position. Key and
  value storage must outlive the table (use `Document.allocator()`).

`remove(key) bool`
: Delete a key and its comments; the order of the others is kept. Returns
  whether the key existed.

`commentsOf(key) ?Comments`, `setComments(arena, key, comments) !void`
: Read or replace the comments on a key's line. The comment strings must be
  arena-owned; the key is not retained, and may be one that is added later.

Iterate entries with `table.entries.iterator()`; the order is the order in the

file (or the order of insertion).

# ERRORS

`ParseError` is `Syntax`, `InvalidUtf8`, `LimitExceeded` or `OutOfMemory`.

`ParseReaderError` adds `ReadFailed`. `WriteError` is `std.Io.Writer.Error`

plus `OutOfMemory` and `NestingTooDeep` (a tree more than 1024 tables and
arrays deep, or one that contains itself) and `InvalidValue` (a string, key or
comment that is not UTF-8, a malformed comment, or a `Datetime` that is not one
of the four forms with every field in range, or an `is_table_array` array
holding a non-table). On either of these two, nothing
is written.

`Syntax`
: Malformed TOML, or a construct TOML forbids: duplicate key, redefined table,
  edit of an inline table, mixing `[x]` and `[[x]]`, bad escape, out-of-range
  integer, and so on. Under `.v1_0`, also any 1.1-only syntax.

`InvalidUtf8`
: Input is not UTF-8.

`LimitExceeded`
: `max_bytes`, `max_depth` or `max_key_depth` exceeded.

Only the first error is reported. If a `Diagnostic` was given it is cleared

when parsing starts, and on any failure receives the position and a short

message (for `OutOfMemory` and `ReadFailed`, where parsing had got to). On any error no memory is leaked.

# OWNERSHIP AND LIFETIME

- Strings, tables and arrays returned by getters are borrowed from the
  document and become invalid at `deinit`.
- Anything stored with `set` or `put` must be allocated from
  `doc.allocator()`, or live at least as long as the document, as a string
  literal does. Use `doc.dupe` for strings: a slice of caller memory dangles
  once its owner frees or reuses it.
- Replacing or removing a value does not free its old storage; it is reclaimed
  with the whole arena. A long-lived document edited in a loop therefore
  grows. Re-parse or rebuild such a document periodically.
- A document is not safe for concurrent mutation.

# OUTPUT

The writer is deterministic. Keys appear in insertion order, except that

scalar and dotted keys are written before sub-tables. Dotted keys stay dotted. Strings are written with the

quoting needed to be valid, and a tree with no TOML form is refused (see
ERRORS). Output is valid under both TOML 1.0 and 1.1 and

parses back to the same keys and values.

Comments are preserved through parse, edit and write: lines above a key or

header (including blank lines that separate groups of settings), a trailing

comment on a line, and comments after the last item. They move with their

item and are dropped with a removed key. They stay with a key whose value is
changed with `set` or `put`, also between a scalar and a table. (Replacing a
table by assigning through `getPtr` drops the old table's header comments.)

# EXAMPLES

Read with defaults:

```zig
const height = doc.root.getTable("panel").?.getInt("height") orelse 24;
```

Stream from a file:

```zig
var file = try std.Io.Dir.cwd().openFile(io, "config.toml", .{});
defer file.close(io);
var buf: [4096]u8 = undefined;
var reader = file.reader(io, &buf);
var doc = try toml.Document.parseReader(gpa, &reader.interface, .{}, &diag);
defer doc.deinit();
```

Report a failure:

```zig
var doc = toml.Document.parse(gpa, text, .{}, &diag) catch |e| {
    std.log.err("config: {f}: {t}", .{ diag, e });
    return e;
};
```

Edit and save, keeping comments:

```zig
try doc.set(&.{ "panel", "height" }, .{ .integer = 40 });
try doc.write(gpa, &out_writer.interface);
```

More in `docs/api.md`; `src/api_examples.zig` holds tested copies of its

examples.

# LIMITATIONS

- Comments **inside arrays and inline tables** are dropped on write. Other
  formatting (spacing, quote style, multi-line arrays) is normalized, and runs
  of blank lines collapse to one.
- Datetime fractions beyond nanoseconds are truncated.
- `Table.lookup` cannot reach keys containing a dot.
- The decoder cases of the official `toml-test` suite pass for 1.0.0 and 1.1.0
  (`zig build conformance`). Its encoder mode, which checks written output with
  an independent parser, has not been run.

- Memory from replaced values is not reclaimed until `deinit`.

# RESOURCE USAGE

Memory is the parsed tree plus one reused scratch buffer; the input is not held

in memory when `parseReader` is used. Defaults bound input to 16 MiB, array and

inline table nesting to 64 and key nesting to 128 levels, so that untrusted

input cannot exhaust the stack.

These limits do **not** bound memory tightly. Very small constructs each make a

table, so hostile input can use about 90 times its own size: 16 MiB of long

dotted keys took about 1.4 GB (x86_64, ReleaseFast, `smp_allocator`; 1.0 to

1.3 GB for repeated `[[a]]` or `{}`). For untrusted input, lower `max_bytes`,

or pass `parse` an allocator that enforces a budget; the parse then fails with

`OutOfMemory`. Measured

throughput is in `docs/decisions/0001-streaming-parser.md` (roughly 40 MB/s

parse, 220 MB/s write on the recorded machine; `zig build bench` reproduces

them).

# COMPATIBILITY

Requires Zig 0.17. Specifications: TOML 1.1.0 (default) and 1.0.0, selected by

`Options.version`. Every valid 1.0 document is valid 1.1 and parses identically.

# SEE ALSO

**toml-syntax**(5), **toml-parse**(1), `docs/api.md`, `docs/decisions/`,

<https://toml.io/en/v1.1.0>

# AVAILABILITY

Source: the repository containing this file. Report defects with a minimal

TOML input and the printed `line:column: message`.

# VERSION

This manual describes toml-zig 0.3.0.

