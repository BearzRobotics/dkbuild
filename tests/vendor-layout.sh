#!/bin/sh
# Vendored dependencies are laid into the unpacked source without trusting it: a source archive full of links, or
# with hostile names, changes nothing outside the build. Uses pydeps with a store that is already filled, so
# nothing is downloaded. Also: the sources copied to build/sources/ follow no link an earlier archive planted.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/vendor
newtree "$T"
rm -rf "$T/src" "$T/victim" "$T/victim-file" "$T/marker"   # what an earlier run left
mkdir -p "$T/src" "$T/cache/python"
ABS=$PWD/$T
printf 'a pretend wheel\n' > "$T/cache/python/dkwheel-1-py3-none-any.whl"
WSHA=$(sha256sum "$T/cache/python/dkwheel-1-py3-none-any.whl" | cut -d' ' -f1)

# mkrecipe NAME SOURCES... : a recipe with the pydeps lock; $BUILD is its build step.
mkrecipe() {
    _n=$1; shift
    _d=$T/packages/$(printf %.1s "$_n")/$_n
    mkdir -p "$_d/files"
    echo "dkwheel 1 $WSHA https://example.invalid/dkwheel-1-py3-none-any.whl" > "$_d/files/python.lock"
    {
        printf 'name    = "%s"\nversion = "1"\nrelease = 1\nsummary = "Test recipe"\nlicense = "MIT"\n' "$_n"
        printf 'options = ["pydeps", "!check"]\n\nsource = [\n'
        for _s in "$@"; do
            printf '    { url = "file://%s/src/%s", sha256 = "%s" },\n' "$ABS" "$_s" "$(sha256sum "$T/src/$_s" | cut -d' ' -f1)"
        done
        printf "]\n\nbuild = '''\n%s\n'''\ninstall = '''\nmkdir -p \$pkgdir/usr/share/%s\necho ok > \$pkgdir/usr/share/%s/ok\n'''\n" "$BUILD" "$_n" "$_n"
    } > "$_d/package.toml"
}
pack() { tar -C "$W" -czf "$T/src/$1" "$2"; }   # pack ARCHIVE TOPDIR
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
dk() { ./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" "$1" 2>&1; }

# 1. An honest source: the build sees the link, and reads the store through it.
mkdir -p "$W/good-1"; echo x > "$W/good-1/x"
pack good-1.tar.gz good-1
BUILD='test -L .dkpython/dkwheel-1-py3-none-any.whl
grep -q "pretend wheel" .dkpython/dkwheel-1-py3-none-any.whl'
mkrecipe good good-1.tar.gz
OUT=$(dk good) || { echo "$OUT" | tail -15; echo "FAIL: vendored files were not laid out for an honest source"; exit 1; }

# 2. .dkpython is a link to a directory outside the build.
mkdir -p "$ABS/victim" "$W/linked-1"
ln -s "$ABS/victim" "$W/linked-1/.dkpython"
pack linked-1.tar.gz linked-1
BUILD='true'
mkrecipe linked linked-1.tar.gz
OUT=$(dk linked)
[ -z "$(ls -A "$ABS/victim")" ] || { echo "FAIL: laying out dependencies wrote outside the build: $(ls "$ABS/victim")"; exit 1; }

# 3. The top directory's name is shell code.
MARK=$ABS/marker
EVIL="p'||touch \${DKMARK};:'"
mkdir -p "$W/$EVIL"; echo x > "$W/$EVIL/x"
pack evil-1.tar.gz "$EVIL"
mkrecipe evil evil-1.tar.gz
OUT=$(DKMARK="$MARK" dk evil)
[ ! -e "$MARK" ] || { echo "FAIL: a directory name from a source archive ran as a command on the host"; exit 1; }

# 4. A first archive leaves build/sources/data.txt as a link out; the second source is a plain file of that name.
echo original > "$ABS/victim-file"
mkdir -p "$W/plant/sources"
ln -s "$ABS/victim-file" "$W/plant/sources/data.txt"
tar -C "$W/plant" -czf "$T/src/plant-1.tar.gz" sources
echo from-the-recipe > "$T/src/data.txt"
BUILD='grep -q from-the-recipe /build/sources/data.txt'
mkrecipe planted plant-1.tar.gz data.txt
OUT=$(dk planted)
RC=$?
[ "$(cat "$ABS/victim-file")" = original ] || { echo "FAIL: copying a source followed a link and overwrote a file outside the build"; exit 1; }
[ $RC = 0 ] || { echo "$OUT" | tail -15; echo "FAIL: the planted link should have been replaced by the source"; exit 1; }
echo "ok: dependencies are laid out for the build, and hostile source archives reach nothing outside it"
