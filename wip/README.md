# Work in progress

Recipes being ported that must not build yet (dkbuild only reads packages/).

- chromium: base for native Brave. Chimera lets two post_patch steps use the network (crubit via tools/rust/build_crubit.py, and `cargo build` of tools/crates/gnrt); those crates have to be vendored at fetch time first. Then brave-core on top.
- openjdk21: moved back to packages/ and ported (2026-11-09).
- electron: Electron 43.8.3 (Chromium 150) for Code - OSS, from a dkbuild snapshot (`snapshot:electron ...`, src/snapshot-electron.sh; 2026-11-09). Patches are Alpine's (for Chromium 148) and need refreshing; the snapshot's sha256 goes in once the first one is made.
- code-oss: VS Code 1.145.2 on the system Electron, npm packages from the npm store, Open VSX gallery; `!repo-iso`. Needs electron, and dkbuild's `!repo-iso` option.

Requested software that is not a recipe yet, and what each needs (2026-11-10):

- metasploit: Ruby plus ~300 gems through Bundler. Needs a `gemdeps` store (like
  npmdeps: the Gemfile.lock's gems fetched and checked at fetch time).
- frida: its build downloads a prebuilt toolchain and SDK (glibc) from
  build.frida.re; on musl both have to be built from source first
  (releng/deps.py), as a snapshot.
- anki: its build (a Rust "ninja" runner) downloads Node, Python wheels and
  crates as it goes; needs a snapshot that pre-runs those, or the npm, crate and
  Python stores wired into its build.
- geogebra: the GitHub repository is a mirror of a large Gradle/GWT web build;
  the desktop app is an Electron shell (waits on electron).
- euro-office: an OnlyOffice fork (~30 repositories; core builds V8 and Qt
  pieces with downloads). A snapshot of its build-tools checkout first.
- brave: chromium (here in wip) plus brave-core on top; with electron's snapshot
  tooling, a `snapshot:brave` for brave-browser's gclient checkout.
- pdfium: a gclient checkout like Chromium's (snapshot:electron's approach).
- mattercontrol: no longer builds for Linux (net6.0-windows, WinForms). Options:
  Wine, or the old 1.7.x on Mono (no Mono in the tree).
