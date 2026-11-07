# 0002: Importing Chimera cbuild templates

Status: implemented (`src/cbuild.zig`, `dkbuild import-cbuild`), tested on fixtures and on
the real cports templates zstd, dinit, lvm2 and curl.

## Problem

FenrirOS targets the same platform as Chimera Linux (musl, LLVM, dinit, apk),
and Chimera's `cports` tree already has a recipe for most of what the base
system needs. Writing each one again by hand is slow and repeats Chimera's
lessons. But a cbuild `template.py` is Python, not data, and dkbuild must
never run it: it would execute arbitrary code from a third party and depend on
cbuild's whole API.

## Proposal

`dkbuild import-cbuild [--out DIR] <template.py | package dir>...` reads a
template as *text* and writes a **draft** `package.toml` (default
`imported/<name>/`), plus a report. It never executes Python.

1. **A small reader for the Python subset templates use.** Module-level
   `name = expression` statements are evaluated: strings (including `f"..."`
   that refer to earlier variables such as `pkgver` and `url`), numbers,
   booleans, lists, dicts, and `+` between strings or lists. Anything else
   (calls, comprehensions, conditionals) becomes an *unknown* value that is
   reported, never guessed.
2. **Declarative variables map onto recipe fields** (SPEC 5.9): `pkgname`,
   `pkgver`, `pkgrel` (+1: cbuild counts from 0), `pkgdesc`, `license`, `url`,
   `source` + `sha256` (paired by position), `hostmakedepends`, `makedepends`,
   `checkdepends`, `depends`, `options` and `archs` (only the ones we know).
   `patches/` and `files/` next to the template are copied.
3. **`build_style` maps onto macros:** `gnu_configure` -> `%configure`,
   `%make`, `%make_install`; `configure`; `meson`; `cmake`; `makefile`. Its
   `configure_args`, `make_build_args`, `make_install_args` become arguments.
   Other styles are reported and leave a placeholder.
4. **Functions are translated only when trivial.** In `build`, `install`,
   `post_install` and similar, calls to `self.do(...)` whose arguments are
   plain strings become shell lines (`$jobs`, `$pkgdir` for `make_jobs`,
   `destdir`), as do `install_license`, `install_file`, `install_bin`,
   `install_link` and `uninstall`. **Every other statement is kept as a
   `# TODO(cbuild): <the Python line>` comment** inside the step, so nothing is
   dropped silently.
5. **The draft is validated** with the recipe reader and the report says
   whether it passes `dkbuild check`. A draft with TODOs is not expected to
   build; it is expected to save the typing and show what is left.
6. **Attribution.** cports is BSD-2-Clause. Each draft starts with a comment
   naming the source template, its license and "Chimera Linux contributors".

Dependency names are copied as Chimera spells them (`zlib-ng-compat-devel`,
`openssl3-devel`); the report lists them, because FenrirOS's names may differ.

## Not goals

Subpackage classes beyond the defaults (`-devel`, `-static`, `-doc` already
exist), Chimera's `hardening`, `compression`, `renames` and `provides`,
`tool_flags` beyond a plain `environment` export, and cross-build logic. They
are reported so a person can decide.

## Alternatives considered

- **Run the template under Python with a stub `self`.** Executes untrusted
  code and needs a faithful copy of cbuild's API. Rejected.
- **A full Python parser.** Large, and templates use a tiny part of the
  language. The subset reader plus "unknown stays visible" is enough.
- **Convert fully or not at all.** Rejected: the declarative top of a
  template is most of the typing, and a partial draft with honest TODOs is
  more useful than nothing.

## Consequences

A draft needs review: dependency names, `options`, anything marked TODO, and
the build style's flags against our `%` macros. The importer is tested on
fixtures and on real cports templates (zstd, dinit, lvm2, curl). It will not
become more complete than the subset it understands.
