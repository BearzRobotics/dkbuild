# Work in progress

Recipes being ported that must not build yet (dkbuild only reads packages/).

- chromium: base for native Brave. Chimera lets two post_patch steps use the network (crubit via tools/rust/build_crubit.py, and `cargo build` of tools/crates/gnrt); those crates have to be vendored at fetch time first. Then brave-core on top.
- openjdk21: moved back to packages/ and ported (2026-11-09).
- electron: Electron 43.8.3 (Chromium 150) for Code - OSS, from a dkbuild snapshot (`snapshot:electron ...`, src/snapshot-electron.sh; 2026-11-09). Patches are Alpine's (for Chromium 148) and need refreshing; the snapshot's sha256 goes in once the first one is made.
- code-oss: VS Code 1.145.2 on the system Electron, npm packages from the npm store, Open VSX gallery; `!repo-iso`. Needs electron, and dkbuild's `!repo-iso` option.
