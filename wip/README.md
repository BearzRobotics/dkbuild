# Work in progress

Recipes being ported that must not build yet (dkbuild only reads packages/).

- chromium: base for native Brave. Chimera lets two post_patch steps use the network (crubit via tools/rust/build_crubit.py, and `cargo build` of tools/crates/gnrt); those crates have to be vendored at fetch time first. Then brave-core on top.
- openjdk21: for Ghidra (with its Gradle dependencies vendored). Seeded by openjdk21-bootstrap (a prebuilt musl JDK, like the Go and Rust seeds). Its configure/install hooks still need porting.
