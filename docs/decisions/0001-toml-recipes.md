# 0001: Recipes and profiles are TOML

Status: proposed. Not yet approved or implemented.

## Problem

Recipes (`packages/<name>/package.yml`) and target profiles
(`profiles/<arch>.yml`) are a strict YAML subset read by our own
`src/yaml.zig` (376 lines). Keeping a YAML parser alive only for our own
config is a cost, and the DKDE family already has a maintained,
`std.Io`-based TOML library (`toml-zig`, TOML 1.1.0). Settling on one
configuration format across FenrirOS also means one thing to learn. The
earlier note in `dknotes` said the same: swap to TOML.

YAML stays in the picture only as an *input* format: Solus `package.yml`
files are read by the separate `yaml-zig` library when importing recipes. It
is not the format dkbuild stores or builds from.

## Proposal

1. `package.yml` becomes `package.toml`; `profiles/<arch>.yml` becomes
   `profiles/<arch>.toml`. Same fields, same meaning, same strictness (an
   unknown key or a wrong type is an error, never ignored).
2. Parsing uses `toml-zig` (path dependency now, pinned by hash once the
   repository is published). `src/yaml.zig` is deleted once the migration is
   verified.
3. Mapping, using `zstd` as the example:

```toml
name     = "zstd"
version  = "1.5.7"          # always a string: "2.03.35" is not a number
release  = 1                # integer >= 1
summary  = "Fast lossless compression"
license  = "BSD-3-Clause OR GPL-2.0-only"
homepage = "https://facebook.github.io/zstd/"
options  = ["static", "!check"]
builddeps = ["libaio", "util-linux"]

source = [
    { url = "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz", sha256 = "eb33…" },
    # { git = "https://github.com/BearzRobotics/dkde.git", tag = "v0.0.3" },
]

build = '''
%make
'''
check = '''
%make check
'''
install = '''
%make_install PREFIX=/usr
'''

# Tables go last: in TOML, every key after a [table] header belongs to it.
[subpackages.tools]
summary = "Command line tools"
paths   = ["/usr/bin"]
```

   - **Shell steps** are multi-line *literal* strings (`'''`): no escape
     processing, so `\` line continuations, `$pkgdir` and `%macros` are
     written exactly as the shell sees them. A step cannot contain `'''`;
     such a step writes `"""` with escapes or moves the text into a file.
   - **Sources** are an array of inline tables, `{ url, sha256 }` or
     `{ git, tag | commit }`, replacing the `URL : sha256` pairs. This keeps
     the file flat; with `[[source]]` headers every later top-level key would
     have to come first.
   - **Field names and meanings** are exactly those of SPEC.md 5.2. `jobs:N`
     stays a string option. Subpackages become `[subpackages.<name>]` tables.
   - **Profiles** are plain string keys (`arch`, `triple`, `cpu`,
     `zig_target`, `zig_cpu`, `kernel_arch`).
   - `package.lock`, when implemented, is TOML as well.
4. dkbuild reads recipes with `toml-zig`'s default version (1.1). Nothing
   requires 1.1, but only dkbuild reads these files.

## Migration

1. Add the dependency; port `recipe.zig` and `profile.zig` to read a
   `toml.Table`, keeping the validation (required keys, unknown-key errors,
   types) and the `Recipe`/`Profile` structs unchanged, so `build`, `split`,
   `scan` and the rest do not change.
2. Convert every `package.yml` and `profiles/*.yml` in the repository (the
   5 recipes and 3 profiles at the top, plus those in `tests/trees/`) with a one-off conversion that uses the old `yaml.zig` reader, and
   check that old and new produce *identical* `Recipe` values before deleting
   the YAML path.
3. Rename file lookups (`tree.zig`, `inputs.zig`, `build.zig`, `main.zig`:
   `check name|file.toml`), update the test scripts and SPEC.md (4, 5.1,
   5.2, 5.3, 5.8, 14), delete `yaml.zig`.

## Alternatives considered

- **Keep YAML.** Works today, but is a second format and a parser to own.
- **`[[source]]` array of tables.** More idiomatic TOML, but forces the
  ordering rule onto every recipe (scalars first, then tables).
- **Single-quoted `'...'` or escaped `"..."` shell steps.** Rejected: the
  escapes make shell unreadable.

## Consequences and risks

- **Error positions.** TOML syntax errors keep line and column. `toml-zig`
  does not record where each key sits, so semantic errors ("unknown key
  `buildeps`", "`release` must be an integer") name the key and the file
  but not the line, where YAML gave one. If that proves too annoying, the
  fix belongs in `toml-zig` (an optional position per key), not here.
- **Recipes in two formats** until the migration lands; the conversion is
  checked, not trusted.
- **Importing other recipe formats.** SPEC.md lists "building recipes from
  other distributions' formats" as a non-goal. The plan to convert Chimera
  cbuild templates and Solus `package.yml` contradicts it; the non-goal
  should be reworded to "building from other formats directly: they are
  converted to TOML first" in the same change.
- No effect on built packages, the sandbox or apk output.

## Fallback

`yaml.zig` stays until the checked conversion passes; if TOML proves worse in
practice the branch is dropped.
