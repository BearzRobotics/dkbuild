# Helpers for the test scripts (source this; it expects to run from the project root).

# sbrun [--bind SRC DST | --robind SRC DST]... -- CMD...: runs CMD (an absolute path) in
# the DKRescue root, in dkbuild's own sandbox (no bwrap, no Chimera). The root is
# read-only underneath; what CMD writes is thrown away.
sbrun() {
    [ -d rootfs/dkrescue ] || { echo "rootfs/dkrescue is missing: run 'dkbuild bootstrap-root <dkrescue.iso>'"; return 99; }
    mkdir -p work
    _sb=$(mktemp -d "$PWD/work/sb.XXXXXX") || return 99   # empty, the paths below would be in /
    mkdir "$_sb/u" "$_sb/w" "$_sb/m"
    ./zig-out/bin/dkbuild sandbox-child --lower "$PWD/rootfs/dkrescue" --upper "$_sb/u" --work "$_sb/w" \
        --merged "$_sb/m" --env PATH=/usr/bin:/bin --env HOME=/root "$@"
    _rc=$?
    chmod 700 "$_sb/w/work" 2>/dev/null   # the overlay makes it mode 000
    rm -rf "$_sb"
    return $_rc
}

# mkdemo DIR: builds DIR/dkdemo-1.tar.gz, a tiny C library Chimera doesn't ship,
# and sets DEMO_URL (a file:// URL) and DEMO_SHA. Reproducible: same bytes every run.
mkdemo() {
    _d=$(mktemp -d)
    mkdir "$_d/dkdemo-1"
    printf 'int dkdemo(void);\n' > "$_d/dkdemo-1/dkdemo.h"
    printf '#include "dkdemo.h"\nint dkdemo(void) { return 42; }\n' > "$_d/dkdemo-1/dkdemo.c"
    mkdir -p "$1"
    tar -C "$_d" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - dkdemo-1 | gzip -n > "$1/dkdemo-1.tar.gz"
    DEMO_SHA=$(sha256sum "$1/dkdemo-1.tar.gz" | cut -d' ' -f1)
    DEMO_URL="file://$(cd "$1" && pwd)/dkdemo-1.tar.gz"
    rm -rf "$_d"
}

# demo_recipe TREE RELEASE: writes the dkdemo library recipe into TREE.
demo_recipe() {
    mkdir -p "$1/packages/d/dkdemo"
    cat > "$1/packages/d/dkdemo/package.toml" <<EOF
name    = "dkdemo"
version = "1"
release = $2
summary = "Test library"
license = "MIT"
options = ["!check"]

source = [
    { url = "$DEMO_URL", sha256 = "$DEMO_SHA" },
]

build = '''
\$CC \$CFLAGS -fPIC -shared -Wl,-soname,libdkdemo.so.1 dkdemo.c -o libdkdemo.so.1.0
\$CC \$CFLAGS -c dkdemo.c -o dkdemo_s.o
llvm-ar rcs libdkdemo.a dkdemo_s.o
'''
install = '''
mkdir -p \$pkgdir/usr/lib \$pkgdir/usr/include
cp libdkdemo.so.1.0 libdkdemo.a \$pkgdir/usr/lib/
ln -s libdkdemo.so.1.0 \$pkgdir/usr/lib/libdkdemo.so.1
ln -s libdkdemo.so.1 \$pkgdir/usr/lib/libdkdemo.so
cp dkdemo.h \$pkgdir/usr/include/
'''
EOF
}

# user_recipe TREE NAME DEP [static]: a program that links dkdemo (statically with "static").
user_recipe() {
    mkdir -p "$1/packages/$(printf %.1s "$2")/$2"
    if [ "${4:-}" = static ]; then opts='["static", "!check"]'; link="-static"; else opts='["!check"]'; link=""; fi
    cat > "$1/packages/$(printf %.1s "$2")/$2/package.toml" <<EOF
name      = "$2"
version   = "1"
release   = 1
summary   = "Test program linking dkdemo"
license   = "MIT"
builddeps = ["$3"]
options   = $opts

source = [
    { url = "$DEMO_URL", sha256 = "$DEMO_SHA" },
]

build = '''
printf '#include "dkdemo.h"\nint main(void){return dkdemo()==42?0:1;}\n' > t.c
\$CC \$CFLAGS $link t.c -ldkdemo -o t
'''
install = '''
mkdir -p \$pkgdir/usr/bin
cp t \$pkgdir/usr/bin/$2
'''
EOF
}

# realtree TREE NAME...: a tree holding the project's own recipes NAME..., so that a test builds the current
# recipes with the current dkbuild, signed with the tree's own key, and leaves the project's repo/ alone. Sources
# come from the project's cache/ where it has them (downloaded there otherwise, once).
realtree() {
    _t=$1; shift
    newtree "$_t"
    mkdir -p cache/sources "$_t/cache"
    ln -s ../../../../cache/sources "$_t/cache/sources"
    for _n in "$@"; do
        _l=$(printf %.1s "$_n")
        mkdir -p "$_t/packages/$_l"
        cp -r "packages/$_l/$_n" "$_t/packages/$_l/$_n"
    done
}

# basetree: tests/trees/base with musl and linux-headers built from the current recipes (kept between the tests
# of one run: a second call finds them up to date). Sets BASE.
basetree() {
    BASE=tests/trees/base
    if [ ! -e "$BASE/signing.rsa" ] || ! cmp -s packages/m/musl/package.toml "$BASE/packages/m/musl/package.toml"; then
        realtree "$BASE" musl linux-headers
    fi
    TEST_KEY="$PWD/$BASE/signing.rsa"
    _out=$(./zig-out/bin/dkbuild --tree "$BASE" pkg --key "$TEST_KEY" musl 2>&1) \
        || { echo "$_out" | tail -15; echo "FAIL: building musl in $BASE"; return 1; }
}

# testkey TREE: a signing key pair of this run's own, for TREE only: its private half in TREE/signing.rsa, its
# public half the one key in TREE/keys. Sets TEST_KEY. Test packages (some with install scripts, which run as
# root) are never signed with the distribution's key, which installed systems trust.
testkey() {
    rm -rf "$1/keys" "$1/signing.rsa"
    mkdir -p "$1/keys"
    ( umask 077 && openssl genrsa -out "$1/signing.rsa" 2048 ) >/dev/null 2>&1 \
        && openssl rsa -in "$1/signing.rsa" -pubout -out "$1/keys/dkbuild-test.rsa.pub" >/dev/null 2>&1 \
        || { echo "FAIL: cannot make a test signing key (openssl)"; exit 1; }
    TEST_KEY="$PWD/$1/signing.rsa"
}

# newtree TREE: an empty tree with its own keys, sharing the rootfs and profiles.
newtree() {
    rm -rf "$1/packages" "$1/repo" "$1/logs" "$1/work" "$1/cache" "$1/profiles"
    mkdir -p "$1/packages"
    cp -r profiles "$1/profiles"
    ln -sfn ../../../rootfs "$1/rootfs"
    testkey "$1"
}
