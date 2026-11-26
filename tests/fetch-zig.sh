#!/bin/sh
# `dkbuild fetch` for Zig: the shared store holds a package under its hash, for every project that depends on it.
# A package a source ships in zig-pkg/ gets there only if it really has that hash. Offline: the dependency is a
# local file. Skipped without zig on the host.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
command -v zig >/dev/null || { echo "skipped: needs zig on the host"; exit 0; }
T=tests/trees/fetch-zig
newtree "$T"
rm -rf "$T/src"; mkdir -p "$T/src"
A=$PWD/$T
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT

# the dependency, and its hash as zig computes it
mkdir -p "$W/dep-1/src"
echo 'pub const answer = 42; // genuine' > "$W/dep-1/src/root.zig"
cat > "$W/dep-1/build.zig" <<'EOZ'
pub fn build(b: *@import("std").Build) void { _ = b; }
EOZ
printf '.{ .name = .dkdep, .version = "1.0.0", .fingerprint = 0x1e9a2b3c4d5e6f70, .paths = .{ "build.zig", "build.zig.zon", "src" } }\n' > "$W/dep-1/build.zig.zon"
FP=$(cd "$W/dep-1" && zig build --help 2>&1 | grep -o 'use this value: 0x[0-9a-f]*' | grep -o '0x[0-9a-f]*')
[ -n "$FP" ] && sed -i "s/0x1e9a2b3c4d5e6f70/$FP/" "$W/dep-1/build.zig.zon"
tar -C "$W" -czf "$A/src/dep-1.tar.gz" dep-1
HASH=$(ZIG_GLOBAL_CACHE_DIR="$W/gc" zig fetch "$W/dep-1" | tail -n 1)
case $HASH in dkdep-1.0.0-*) ;; *) echo "FAIL: cannot compute the test package's hash: $HASH"; exit 1 ;; esac

# project NAME: depends on it
project() {
    mkdir -p "$W/$1"
    cp "$W/dep-1/build.zig" "$W/$1/build.zig"
    printf '.{ .name = .%s, .version = "1.0.0", .fingerprint = 0x1e9a2b3c4d5e6f70, .paths = .{""},\n  .dependencies = .{ .dkdep = .{ .url = "file://%s/src/dep-1.tar.gz", .hash = "%s" } } }\n' "$1" "$A" "$HASH" > "$W/$1/build.zig.zon"
    _fp=$(cd "$W/$1" && ZIG_GLOBAL_CACHE_DIR="$W/gc" zig build --help 2>&1 | grep -o 'use this value: 0x[0-9a-f]*' | grep -o '0x[0-9a-f]*' | head -n 1)
    [ -z "$_fp" ] || sed -i "s/0x1e9a2b3c4d5e6f70/$_fp/" "$W/$1/build.zig.zon"
    rm -rf "$W/$1/.zig-cache" "$W/$1/zig-pkg"
}
pack() {
    tar -C "$W" -czf "$A/src/$1.tar.gz" "$1"
    mkdir -p "$T/packages/$(printf %.1s "$1")/$1"
    cat > "$T/packages/$(printf %.1s "$1")/$1/package.toml" <<EOR
name    = "$1"
version = "1"
release = 1
summary = "Test recipe"
license = "MIT"
options = ["zigdeps", "!check"]
source = [ { url = "file://$A/src/$1.tar.gz", sha256 = "$(sha256sum "$A/src/$1.tar.gz" | cut -d' ' -f1)" } ]
build = 'true'
install = 'true'
EOR
}
fetched() { ./zig-out/bin/dkbuild --tree "$T" fetch "$1" 2>&1; }

# 1. A source ships an altered copy of the dependency under the genuine one's hash.
project hostile
mkdir -p "$W/hostile/zig-pkg"
cp -r "$W/dep-1" "$W/hostile/zig-pkg/$HASH"
echo 'pub const answer = 666; // altered' > "$W/hostile/zig-pkg/$HASH/src/root.zig"
pack hostile
OUT=$(fetched hostile) || { echo "$OUT" | tail -8; echo "FAIL: fetching the source with the altered package failed"; exit 1; }
grep -q genuine "$T/cache/zigpkg/$HASH/src/root.zig" 2>/dev/null || { echo "FAIL: an altered package a source shipped went into the shared store under the genuine hash"; exit 1; }

# 2. A source ships a correct copy: it is accepted (the dependency's URL is gone, so only that copy can serve),
#    and a file it adds outside the package's hash does not come along.
rm -rf "$T/cache/zigpkg" "$T/cache/zig-global"
project vendored
mkdir -p "$W/vendored/zig-pkg"
cp -r "$W/dep-1" "$W/vendored/zig-pkg/$HASH"
echo smuggled > "$W/vendored/zig-pkg/$HASH/EXTRA"
pack vendored
mv "$A/src/dep-1.tar.gz" "$A/src/dep-1.tar.gz.gone"
OUT=$(fetched vendored) || { echo "$OUT" | tail -8; echo "FAIL: a correct package the source ships was not accepted"; exit 1; }
grep -q genuine "$T/cache/zigpkg/$HASH/src/root.zig" || { echo "FAIL: the shipped package is not in the store"; exit 1; }
[ ! -e "$T/cache/zigpkg/$HASH/EXTRA" ] || { echo "FAIL: a file outside the package's hash went into the store"; exit 1; }
echo "ok: a shipped zig package is stored only if it has its hash, with just the files the hash covers"
