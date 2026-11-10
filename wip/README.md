# Work in progress

Recipes being ported that must not build yet (dkbuild only reads packages/).

- chromium: base for native Brave. Chimera lets two post_patch steps use the network (crubit via tools/rust/build_crubit.py, and `cargo build` of tools/crates/gnrt); those crates have to be vendored at fetch time first. Then brave-core on top.
- openjdk21: moved back to packages/ and ported (2026-11-09).
