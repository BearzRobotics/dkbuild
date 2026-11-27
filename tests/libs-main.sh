#!/bin/sh
# -libs depends on the main package when that holds files the libraries could need (SPEC 5.7): not when it holds
# only programs, nor with !libs-main; and a rebuild whose only difference is that dependency is published.
set -u
cd "$(dirname "$0")/.." || exit 1
. tests/lib.sh
T=tests/trees/libs-main
newtree "$T"
mkdemo "$T/src"

# recipe OPTIONS EXTRA: dkdemo with a program beside its library, and EXTRA at the end of its install
recipe() {
    demo_recipe "$T" "$RELEASE"
    r="$T/packages/d/dkdemo/package.toml"
    sed -i "s|^options = .*|options = [$1]|" "$r"
    # the last line of the file closes the install step
    sed -i '$d' "$r"
    printf 'mkdir -p $pkgdir/usr/bin\nprintf "#!/bin/sh\\n" > $pkgdir/usr/bin/dkdemo-tool\nchmod 755 $pkgdir/usr/bin/dkdemo-tool\n%s\n%s\n' "$2" "'''" >> "$r"
}
build() {
    OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg --key "$TEST_KEY" dkdemo 2>&1) || { echo "$OUT" | tail -15; echo "FAIL: build"; exit 1; }
}
# depends FILE: what the package FILE in the tree's repository depends on, one a line
depends() {
    sbrun --robind "$PWD/$T/repo/x86_64" /tmp/repo -- /usr/bin/apk adbdump "/tmp/repo/$1" \
        | awk '/^  depends:/ { d = 1; next } d && /^    - / { sub(/^    - /, ""); print; next } { d = 0 }'
}
has() { depends "$1" | grep -Eq "^$2\$"; }
DATA='mkdir -p $pkgdir/usr/share/dkdemo; echo x > $pkgdir/usr/share/dkdemo/data'

RELEASE=1
recipe '"!check"' ':'
build
[ -e "$T/repo/x86_64/dkdemo-libs-1-r1.apk" ] || { echo "FAIL: no -libs package"; exit 1; }
if has dkdemo-libs-1-r1.apk 'dkdemo(=.*)?'; then echo "FAIL: -libs depends on a main package that has only a program"; exit 1; fi

RELEASE=2
recipe '"!check", "!libs-main"' "$DATA"
build
if has dkdemo-libs-1-r2.apk 'dkdemo(=.*)?'; then echo "FAIL: !libs-main did not stop the dependency"; exit 1; fi
RECORD="$T/repo/x86_64/dkdemo.dkhash"
without=$(sed -n 's/^output: //p' "$RECORD")

RELEASE=3
recipe '"!check"' "$DATA"
build
has dkdemo-libs-1-r3.apk 'dkdemo=1-r3' || { depends dkdemo-libs-1-r3.apk; echo "FAIL: -libs does not depend on the main package with the data"; exit 1; }
case $OUT in *'dkdemo-libs depends on dkdemo (for /usr/share/dkdemo/data'*) ;; *) echo "$OUT"; echo "FAIL: the build does not say why"; exit 1;; esac
# stale: the record says it was built against something else, so it is rebuilt and what comes out is compared
stale() { sed -i 's/^deps: .*/deps: 0000000000000000000000000000000000000000000000000000000000000000/' "$RECORD"; }
stale
build
case $OUT in *'rebuilt dkdemo-1-r3: identical'*) ;; *) echo "$OUT" | tail -8; echo "FAIL: an unchanged rebuild was not kept"; exit 1;; esac
# as if a dkbuild without this rule had built it (the same files, as in r2, and no dependency): the rebuild must be
# published, not taken for the same package
stale
sed -i "s/^output: .*/output: $without/" "$RECORD"
build
case $OUT in *'came out different: published as release 4'*) ;; *) echo "$OUT" | tail -8; echo "FAIL: a rebuild that only adds the dependency was not published"; exit 1;; esac
has dkdemo-libs-1-r4.apk 'dkdemo=1-r4' || { echo "FAIL: r4 lacks the dependency"; exit 1; }
echo "ok: -libs depends on its main package only when that has files for it; !libs-main stops it"
