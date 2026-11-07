# 0001: Parse from a std.Io.Reader instead of a byte slice

Status: implemented on branch `streaming-io`; design approved by the maintainer. Merge pending.

## Problem

`AGENTS.md` §13 requires libraries to use the `std.Io` interface for
portability. Today only the edges do: `parseReader` reads the whole input with
`allocRemaining` and hands a `[]const u8` to a parser that indexes it freely.
So the parser never exercises `Reader`, needs the whole text in memory next to
the parsed tree, and cannot parse from a source that is not fully readable up
front (pipe, socket, decompressor).

## Baseline (master, `zig build bench`, ReleaseFast, WSL2)

| Input | parse (slice) | parseReader (fixed) | write |
|---|---|---|---|
| 4 KB | 0.086 ms (52 MB/s) | 0.087 ms | 0.012 ms (370 MB/s) |
| 256 KB | 6.5 ms (40 MB/s) | 6.7 ms | 1.1 ms (247 MB/s) |
| 8 MB | 211 ms (40 MB/s) | 216 ms | 39 ms (222 MB/s) |

Acceptance: stay within 2x of these parse times. Config-sized files must stay
well under a millisecond.

## Where the parser depends on random access (`src/parser.zig`)

- Whole-input `utf8ValidateSlice` before parsing, and `firstInvalidUtf8`.
- `failAt` recomputes line/column by rescanning `src[0..pos]` (error path only).
- Unbounded lookahead: `quoteRun`, the multiline `\` line-ending trim, and
  `scalar` scanning to the end of a token.
- Slicing `src[start..pos]` for keys, literal strings, numbers and datetimes.
- Bounded lookahead: BOM (3 bytes), `\r\n` (2), date-with-space (4).

## Proposal

1. A private `Source` wrapping `*std.Io.Reader` with `peekByte`, `peekN(n)`
   (n <= `max_lookahead`, a small documented constant), `advance`, and counters
   for byte offset, line and column. UTF-8 is validated incrementally as bytes
   are consumed; a sequence split across a refill is handled by `peekN`.
2. `Parser` is rewritten on `Source`. Anything unbounded (quote runs, tokens,
   strings) is accumulated byte by byte into one reused scratch `ArrayList(u8)`
   and then `arena.dupe`d. The grammar code (tables, dotted keys, array
   tables, number and datetime conversion) is kept as is; `number`,
   `parseDatetime` and `escape` already work on slices.
3. `Document.parse(slice)` becomes a wrapper over `Reader.fixed(slice)`;
   `parseReader` streams. `max_bytes` is enforced by counting consumed bytes.
   Public API, error sets and the `Diagnostic` shape do not change.
4. Reader buffer: the caller's `Reader` needs a buffer of at least
   `max_lookahead` bytes. If it has none, `parseReader` wraps it in a small
   stack buffer; this is the one place that choice is made.

## Tests (already on the branch, `src/io_tests.zig`)

Same result for chunk sizes 1..4096; `ReadFailed` at every possible offset
with no leaks; `max_bytes` on a 1-byte reader; writer output identical through
an 8-byte-buffer writer; `WriteFailed` at every possible output length. The
full existing suite must additionally pass with all input fed one byte at a
time.

## Result (same machine, same bench)

| Input | parse before | parse after | parseReader after | write |
|---|---|---|---|---|
| 4 KB | 0.086 ms | 0.063 ms | 0.063 ms | 0.013 ms |
| 256 KB | 6.5 ms | 5.0 ms | 5.0 ms | 1.0 ms |
| 8 MB | 211 ms | 156 ms | 157 ms | 32 ms |

Parsing is about 25% faster, not slower. Likely causes (not profiled): strings
were previously assembled in arena-backed lists that left their growth garbage
in the arena, and the input was scanned twice (UTF-8 validation, then parse).
The reused scratch buffer and single pass avoid both. `parseReader` no longer
copies the input first, so it now equals `parse`.

Implementation notes: lookahead is at most 4 bytes (`max_lookahead`); a
`Reader` with a smaller buffer is wrapped with `Reader.Limited` and an 8-byte
stack buffer. Invalid UTF-8 is now reported at the offending byte when it is
consumed, so a syntax error earlier in the file is reported before a UTF-8
error later in it (previously UTF-8 was checked first). The whole conformance
suite is also run through a one-byte reader and must give the same value or
the same error and line/column.

Whole-process comparison with `poop` (8 MB file, old slice parser vs new, via
`zig build cli`; Linux perf counters on WSL2):

| | wall | peak RSS | CPU cycles | instructions | branch misses |
|---|---|---|---|---|---|
| old, slice | 222 ms | 149 MB | 548 M | 764 M | 373 K |
| new, slice | 176 ms (-21%) | 128 MB (-15%) | 411 M (-25%) | 1.09 G (+42%) | 551 K (+48%) |
| new, 4 KiB file Reader | 174 ms (-22%) | 120 MB (-20%) | 409 M (-25%) | 1.09 G (+42%) | 660 K (+77%) |

As predicted, the streaming parser executes more instructions (per-byte Reader
access, UTF-8 and line tracking) and misses more branches, yet finishes sooner
because it needs fewer cycles and far less memory: strings no longer leave
garbage in the arena, and the input is not scanned twice. Streaming from a
4 KiB-buffered file also avoids holding the file in memory.

Not measured: a worst-case unbuffered one-byte reader (correctness is tested,
speed is not).

## Alternatives considered

- **Tests only, keep the slice parser.** Cheap, exercises the error paths, but
  the parser still never uses `Reader` incrementally. Done as step zero.
- **Dual implementation** (slice fast path plus stream path). Doubles the
  grammar code and the bug surface; rejected.

## Consequences and risks

- Expected parse slowdown from per-byte `Reader` access, the scratch copy and
  incremental UTF-8 and line counting. Measured against the table above.
  Allocation likely dominates, so the relative cost may be small.
- Roughly 800 lines of parser change; the diff is large but mechanical.
- The `std.Io` Reader API is young; this tracks Zig 0.17.1 (`minimum_zig_version`).
- TOML 1.1.0 (SPEC.md) touches the same parser; do it after this lands so the
  two changes do not interleave.

## Fallback

If the cost or complexity is not justified, leave the branch unmerged;
`master` keeps the slice parser plus the new Io tests.
