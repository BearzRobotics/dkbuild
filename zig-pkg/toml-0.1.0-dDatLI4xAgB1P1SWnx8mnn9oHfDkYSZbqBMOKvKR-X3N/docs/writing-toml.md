# Writing TOML

A quick guide to the syntax this library reads and writes. The authoritative
text is the official specification; read it when anything here is unclear:

- **Specification, 1.1.0:** <https://toml.io/en/v1.1.0>
- **Specification, 1.0.0:** <https://toml.io/en/v1.0.0>
- **Formal grammar (ABNF), 1.1.0:** <https://github.com/toml-lang/toml/blob/1.1.0/toml.abnf>
- **Changelog (1.0 → 1.1):** <https://github.com/toml-lang/toml/blob/main/CHANGELOG.md>

This page is our own summary, not a copy of the specification. Every example
below is parsed by `zig build test` (see `src/guide_tests.zig`), so the code
blocks are known to be valid.

## The shape of a file

A TOML file is a set of `key = value` pairs, grouped under `[table]` headers.
Keys are case-sensitive. A `#` starts a comment. Whitespace around `=` and
between tokens is free; each pair sits on its own line.

```toml
# A comment
title = "DKDE"            # a trailing comment
enabled = true

[panel]                   # a table named "panel"
position = "bottom"
height = 32

[panel.clock]             # a table nested inside it
format = "%H:%M"
```

## Keys

Bare keys use `A-Za-z0-9_-`. Anything else needs quotes. Dots build paths.

```toml
bare_key = 1
"quoted key with spaces" = 2
'literal key' = 3
site.name = "x"           # same as a table "site" holding name = "x"
```

A key may be defined only once, and a table may be defined only once.

## Strings

```toml
basic = "escapes work: \t tab, \n newline, \" quote, \\ backslash, \u00e9 é"
literal = 'C:\no\escapes\here'
multi = """
Newlines are kept. A backslash at a line end \
trims the line break and the indentation after it."""
multi_literal = '''
Raw text,
no escapes at all.'''
```

Escapes in basic strings: `\b \t \n \f \r \" \\`, `\uHHHH`, `\UHHHHHHHH`, and,
**new in 1.1**, `\xHH` (code points up to 255) and `\e` (escape, U+001B).

## Numbers, booleans

```toml
int = 1_000_000
hex = 0xDEAD_BEEF
oct = 0o755
bin = 0b1101
float = 6.626e-34
inf_and_nan = [inf, -inf, nan]
yes = true
no = false
```

Leading zeros (`007`) are not allowed on decimal numbers, and underscores
must sit between digits. Integers are 64-bit signed.

## Dates and times

```toml
offset = 1979-05-27T07:32:00Z
offset_tz = 1979-05-27 00:32:00-07:00
local_datetime = 1979-05-27T07:32:00.999
local_date = 1979-05-27
local_time = 07:32:00
```

**New in 1.1:** the seconds may be left out, and are then zero:
`07:32`, `1979-05-27 07:32Z`. A fraction needs seconds (`07:32.5` is invalid).

## Arrays

```toml
ports = [80, 443]
mixed = [1, "two", 3.0]           # mixed types are fine
nested = [[1, 2], ["a"]]
spread = [
    "one",
    "two",                        # trailing comma and comments are fine
]
```

## Tables, inline tables, arrays of tables

```toml
[server]
host = "localhost"

[server.limits]
connections = 10

point = { x = 1, y = 2 }          # an inline table: one value, closed to later edits

[[users]]                         # an array of tables: each [[users]] adds one
name = "ada"

[[users]]
name = "grace"
```

**New in 1.1:** inline tables may span lines, contain comments, and end with
a comma:

```toml
colors = {
    fg = "white",   # foreground
    bg = "black",
}
```

Under 1.0 that form is an error: inline tables must be on one line with no
trailing comma. (Use a normal `[table]` for anything large.)

## Choosing a version in this library

```zig
// default: TOML 1.1
var doc = try toml.Document.parse(gpa, text, .{}, &diag);

// accept only TOML 1.0, e.g. for files other programs must also read
var doc10 = try toml.Document.parse(gpa, text, .{ .version = .v1_0 }, &diag);
```

TOML 1.1 only *adds* syntax: every valid 1.0 document is valid 1.1 and means
the same thing. The writer's output is valid under both versions.

## Common mistakes

- Defining the same key or table twice (including via a dotted key, then a header).
- A bare value that is not a number, boolean or date: `name = ada` must be `name = "ada"`.
- Adding keys to an inline table after the fact (`point.z = 3`) or reopening it with `[point]`.
- Mixing `[[x]]` and `[x]` for the same name.
- Expecting comments to survive a save: this library's writer does not keep them.
