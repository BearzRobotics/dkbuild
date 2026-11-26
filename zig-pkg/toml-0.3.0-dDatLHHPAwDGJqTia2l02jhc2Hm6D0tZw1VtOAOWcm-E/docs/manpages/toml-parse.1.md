# NAME

toml-parse - generate and parse TOML files, for comparing builds of toml-zig

# SYNOPSIS

**toml-parse** **gen** *BYTES*

**toml-parse** **slice** *FILE* [*REPEAT*]

**toml-parse** **reader** *FILE* [*REPEAT*]

# DESCRIPTION

A small benchmarking aid, not a general TOML tool. It exists so that two

builds of the library can be compared as whole processes with

[poop](https://github.com/andrewrk/poop), which reports wall time, cycles,

instructions, cache and branch misses and peak memory. Build it with

`zig build cli`; the binary is `zig-out/bin/toml-parse` (always ReleaseFast).

# COMMANDS

**gen** *BYTES*
: Write a generated TOML document of about *BYTES* bytes to standard output.

**slice** *FILE* [*REPEAT*]
: Read the whole file into memory and parse it with `Document.parse`,
  *REPEAT* times (default 1).

**reader** *FILE* [*REPEAT*]
: Stream the file through a 4 KiB `std.Io.Reader` with `Document.parseReader`,
  *REPEAT* times.

The input size limit is raised to 1 GiB for both parse commands.

# EXIT STATUS

0
: Success.

1
: The file did not parse. A line `FILE: line:column: message: ErrorName` is
  written to standard error.

Other failures (bad usage, unreadable file) end the program with a Zig error

trace and a nonzero status.

# EXAMPLES

```
toml-parse gen 8388608 > big.toml
toml-parse slice big.toml 20
poop 'old/toml-parse slice big.toml' 'new/toml-parse slice big.toml'
```

# SEE ALSO

**toml-zig**(3), **toml-syntax**(5)

