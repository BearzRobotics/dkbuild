# toml-zig — Specification

**Status:** 0.2.0, implemented and tested against the TOML 1.0.0 specification examples and the TOML 1.1.0 changes; see "Known deviations".

## Purpose

A small, dependency-free TOML 1.1.0 parser and writer for Zig 0.17, written for DKDE's configuration files but usable by any project. Reference: https://toml.io/en/v1.1.0 and https://toml.io/en/v1.0.0 (normative text and ABNF in toml-lang/toml at tags 1.1.0 and 1.0.0). `Options.version` selects `.v1_1` (default) or `.v1_0`.

## Requirements

- **TOML-1 (MUST):** Accept every valid TOML 1.0.0 document: all string forms, integers (decimal/hex/octal/binary, underscores), floats (incl. `inf`/`nan`), booleans, all four datetime forms, arrays (mixed types), tables, inline tables, arrays of tables, dotted keys.
- **TOML-1.1 (MUST):** With `Options.version = .v1_1` (the default) also accept the 1.1.0 additions: newlines, comments and a trailing comma in inline tables; the `\xHH` and `\e` escapes; optional seconds in times. With `.v1_0` reject them. Every document valid under 1.0 must parse identically under 1.1 (tested).
- **TOML-2 (MUST):** Reject invalid documents: duplicate keys, table redefinition, mutation of inline tables or dotted-key tables via headers, extending static arrays with `[[ ]]`, invalid escapes/scalar values, forbidden control characters, bad number/date forms, invalid UTF-8.
- **TOML-3 (MUST):** Treat input as untrusted: bounded recursion (`Options.max_depth`, default 64), bounded input (`Options.max_bytes`, default 16 MiB), no undefined behavior on malformed bytes, no assumption of NUL termination.
- **TOML-4 (MUST):** Report the first error with 1-based line and column and a static message (`Diagnostic`).
- **TOML-5 (MUST):** One owner: a `Document` owns an arena; `deinit` frees everything. No leaks on error or allocation failure (tested with `FailingAllocator`).
- **TOML-6 (MUST):** A writer producing valid TOML that parses back to an equal tree, with deterministic order (insertion order, scalars before sub-tables).
- **TOML-7 (MUST):** Editing: values can be set by path; unknown keys in a parsed document survive a parse → edit → write cycle.
- **TOML-9 (MUST):** Use `std.Io` for all input and output: parse incrementally from a `*std.Io.Reader` with bounded lookahead and write to a `*std.Io.Writer`; no file-system or OS calls. Tested with one-byte, failing and tiny-buffer readers and writers. See `docs/decisions/0001-streaming-parser.md`.
- **TOML-10 (MUST):** Comments survive parse → edit → write: comment and blank lines before a key or header, a trailing comment on its line, and comments after the last item. They move with their item, are dropped with a removed key, and can be set through `Document.setComments`.
- **TOML-8 (SHOULD):** No dependencies beyond the Zig standard library. Met.

## API summary

```zig
const toml = @import("toml");
var diag: toml.Diagnostic = .{};
var doc = try toml.Document.parse(gpa, text, .{}, &diag); // diag: line, column, message
defer doc.deinit();
const v = doc.root.getString("key");            // typed getters return null on absence or type mismatch
const w = doc.root.lookup("panel.position");    // dotted path
try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("top") });
const out = try doc.toOwnedString(gpa);         // caller frees
```

Ownership: strings and tables returned by getters borrow from the document and are invalid after `deinit`. Values passed to `set`/`Table.put` must be allocated from `doc.allocator()` (use `doc.dupe`).

## Known deviations and limits

- Comments are kept in a side table (TOML-10). Comments **inside arrays and inline tables** are dropped, and other formatting (spacing, quoting style, multi-line arrays, key order between scalars and sub-tables) is normalized by the writer. Runs of blank lines collapse to one.
- Datetime fractional seconds beyond nanoseconds are truncated.
- `Table.lookup` splits on `.`; keys containing a dot need `get`.
- TOML 1.1 additions (`\e`, `\xHH`, optional seconds, newlines in inline tables) are rejected on purpose.
- Duplicate-key and table-kind rules follow the 1.0.0 text; the official `toml-test` suite is not vendored and has **not** been run. Treat "conformant" as unverified until it is.
- Parsing is single-threaded; documents are not safe for concurrent mutation.

## Testing

`zig build test`: examples from the TOML specification, invalid-input cases, limits, diagnostics, round trips, edit-preservation, and allocation-failure injection.
