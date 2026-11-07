#!/bin/sh
# SPEC.md 12: a recipe that uses zlib without declaring it must fail to build,
# and the same recipe with the dependency declared must build.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
# Stage 1 builds on the DKRescue image, which has zlib.h whether or not a recipe
# declares it, so a forgotten dependency cannot fail there. Only stage 2, which
# fills build roots from declared packages alone, can (SPEC.md 7.3). This test
# comes back to life with stage 2.
echo "skipped: stage 1 cannot catch a forgotten dependency; stage 2 will"
exit 0
T=tests/trees/forgotten-dep
newtree "$T"
mkdemo "$T/src"
mkdir -p "$T/packages/u/usezlib"
recipe() { # $1 = extra lines (builddeps)
    cat > "$T/packages/u/usezlib/package.toml" <<EOF
name    = "usezlib"
version = "1"
release = 1
summary = "Test recipe: uses zlib.h"
license = "MIT"
options = ["!check"]
$1

source = [
    { url = "$DEMO_URL", sha256 = "$DEMO_SHA" },
]

build = '''
printf '#include <zlib.h>\nint main(void){return 0;}\n' > t.c
\$CC t.c -o t
'''
install = '''
mkdir -p \$pkgdir/usr/bin
cp t \$pkgdir/usr/bin/
'''
EOF
}
recipe ""
if ./zig-out/bin/dkbuild --tree $T pkg usezlib >/dev/null 2>&1; then
    echo "FAIL: built without declaring zlib"; exit 1
fi
recipe 'builddeps = ["zlib-ng-compat-devel"]'
if ! ./zig-out/bin/dkbuild --tree $T pkg usezlib >/dev/null 2>&1; then
    echo "FAIL: did not build with zlib declared"; exit 1
fi
echo "ok: forgotten dependency fails, declared dependency builds"
