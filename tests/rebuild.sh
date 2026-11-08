#!/bin/sh
# SPEC.md 7.2: unchanged packages are skipped; a recipe change under the same
# release is an error; a new release rebuilds the package, and what builds on it
# only when the package came out different (early cutoff).
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
T=tests/trees/rebuild
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
user_recipe "$T" usedemo dkdemo-devel
run() { ./zig-out/bin/dkbuild --tree "$T" pkg usedemo 2>&1; }
fail() { echo "$OUT" | tail -8; echo "FAIL: $1"; exit 1; }

OUT=$(run) || fail "first build"
echo "$OUT" | grep -q '^==> usedemo-1-r1$' || fail "usedemo not built the first time"

OUT=$(run) || fail "second run"
echo "$OUT" | grep -q 'dkdemo-1-r1: up to date' || fail "dkdemo was not skipped"
echo "$OUT" | grep -q 'usedemo-1-r1: up to date' || fail "usedemo was not skipped"
echo "$OUT" | grep -q 'preparing build root' && fail "something was rebuilt although nothing changed"

# A recipe change without a new release is an error, and builds nothing.
echo "# edited" >> "$T/packages/d/dkdemo/package.toml"
OUT=$(run) && fail "an edited recipe with the same release was accepted"
echo "$OUT" | grep -q 'release is still r1' || fail "no message about the unchanged release"
echo "$OUT" | grep -q 'preparing build root' && fail "built despite the error"

# A new release rebuilds it. It comes out identical (only a comment changed),
# so the package that builds against it is not rebuilt (early cutoff).
sed -i 's/^release = 1$/release = 2/' "$T/packages/d/dkdemo/package.toml"
OUT=$(run) || fail "build after the release bump"
echo "$OUT" | grep -q '^==> dkdemo-1-r2$' || fail "dkdemo r2 was not built"
echo "$OUT" | grep -q 'usedemo-1-r1: up to date' || fail "usedemo was rebuilt although dkdemo came out identical"

# dkdemo gains a file a package building against it can see (its interface
# changes), so usedemo is rebuilt; usedemo's own program comes out the same,
# so its package is kept, at r1, and nothing is bumped.
sed -i -e 's/^release = 2$/release = 3/' -e 's/llvm-ar rcs libdkdemo.a dkdemo_s.o/llvm-ar rcs libdkdemo.a dkdemo_s.o; echo extra > README.dkdemo/' \
    -e 's|^cp dkdemo.h \$pkgdir/usr/include/$|cp dkdemo.h \$pkgdir/usr/include/; mkdir -p \$pkgdir/usr/share/dkdemo; cp README.dkdemo \$pkgdir/usr/share/dkdemo/|' \
    "$T/packages/d/dkdemo/package.toml"
OUT=$(run) || fail "build after a change to what dkdemo produces"
echo "$OUT" | grep -q '^==> dkdemo-1-r3$' || fail "dkdemo r3 was not built"
echo "$OUT" | grep -q 'usedemo-1-r1: packages it builds against changed; rebuilding' || fail "usedemo was not rebuilt after its dependency's interface changed"
echo "$OUT" | grep -q 'rebuilt usedemo-1-r1: identical' || fail "usedemo's identical rebuild was not kept"
grep -Eq '^release +=  *1$' "$T/packages/u/usedemo/package.toml" || fail "usedemo's recipe was bumped although it came out the same"
OUT=$(run) || fail "run after the identical rebuild"
echo "$OUT" | grep -q 'usedemo-1-r1: up to date' || fail "usedemo was not up to date after its identical rebuild"

# dkdemo's soname changes: usedemo's program now names another library, so it
# comes out different and is published as the next release, bumped in its recipe.
sed -i -e 's/^release = 3$/release = 4/' -e 's/libdkdemo\.so\.1/libdkdemo.so.2/g' "$T/packages/d/dkdemo/package.toml"
OUT=$(run) || fail "build after dkdemo's soname changed"
echo "$OUT" | grep -q 'usedemo-1-r1 came out different: published as release 2' || fail "usedemo's different rebuild was not published as release 2"
grep -Eq '^release +=  *2$' "$T/packages/u/usedemo/package.toml" || fail "usedemo's recipe was not bumped to release 2"
OUT=$(run) || fail "run after the bump"
echo "$OUT" | grep -q 'usedemo-1-r2: up to date' || fail "usedemo r2 was not up to date on the next run"

# --force rebuilds an up-to-date package.
OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg --force usedemo 2>&1) || fail "--force build"
echo "$OUT" | grep -q 'preparing build root' || fail "--force did not rebuild"
echo "ok: skipped when unchanged; error for a changed recipe at the same release; an identical rebuild stops the cascade; a dependent that comes out the same is kept, one that comes out different is published with its release bumped; --force rebuilds"
