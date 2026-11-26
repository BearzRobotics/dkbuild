# toml-zig

TOML 1.1.0 (and 1.0.0) parser and writer for Zig 0.17, with no dependencies. It reads from any `std.Io.Reader` and writes to any `std.Io.Writer`, and never needs the whole input in memory. See `ai/SPEC.md` for requirements and known deviations (comments are preserved when writing, except inside arrays and inline tables).

```zig
// build.zig.zon: .toml = .{ .path = "../toml-zig" }
// build.zig:     exe.root_module.addImport("toml", b.dependency("toml", .{}).module("toml"));
var diag: toml.Diagnostic = .{};
var doc = try toml.Document.parse(gpa, text, .{}, &diag);
defer doc.deinit();

// Incrementally, from any std.Io.Reader (file, pipe, socket, ...):
var doc2 = try toml.Document.parseReader(gpa, &reader.interface, .{}, &diag);

// TOML 1.1 is the default; ask for 1.0 only to be strict:
var doc3 = try toml.Document.parse(gpa, text, .{ .version = .v1_0 }, &diag);
```

- Comments: `# ...` lines above a key or header, a trailing `# ...` on its line, blank lines between them and a closing footer are kept through parse → edit → write (`Table.key_comments`, `Table.header`, `Table.footer`). Set them with `doc.setComments(&.{"panel","position"}, .{ .before = &.{"# where it sits"}, .after = "# top|bottom" })`.
- `docs/api.md` — a tutorial for reading, editing and writing TOML in code.
- `docs/manpages/` — `toml-zig(3)` (library reference), `toml-syntax(5)` (the syntax, with links to the specification) and `toml-parse(1)`. Render with `pandoc -s -t man FILE.md -o FILE`.
- `docs/decisions/` — design decisions (e.g. why the parser is streaming).
- `zig build bench` — parse/write timings (ReleaseFast).
- `zig build cli` — builds `zig-out/bin/toml-parse` (`gen <bytes>`, `slice|reader <file>`) for whole-process comparisons of two builds with [poop](https://github.com/andrewrk/poop): `poop 'old/toml-parse slice f.toml' 'new/toml-parse slice f.toml'`.

`zig build test` runs the tests. `zig build conformance -Dsuite=PATH/toml-test/tests` runs the official [toml-test](https://github.com/toml-lang/toml-test) decoder cases from a local checkout.
