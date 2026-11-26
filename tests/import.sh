#!/bin/sh
# dkbuild import-cbuild on a template directory: the draft is written, patches/
# and files/ are copied, the TODOs are reported, and the draft passes `check`.
set -u
cd "$(dirname "$0")/.."
mkdir -p work
W=$(mktemp -d "$PWD/work/import.XXXXXX") || exit 1; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/in/hello/patches" "$W/in/hello/files"
cat > "$W/in/hello/template.py" <<'PY'
pkgname = "hello"
pkgver = "2.12"
pkgrel = 0
build_style = "gnu_configure"
configure_args = ["--disable-nls"]
pkgdesc = "The GNU hello program"
license = "GPL-3.0-or-later"
url = "https://www.gnu.org/software/hello"
source = f"https://ftp.gnu.org/gnu/hello/hello-{pkgver}.tar.gz"
sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
hardening = ["vis"]


def post_install(self):
    self.install_license("COPYING")
    with self.pushd("po"):
        self.do("true")
PY
printf -- '--- a/x\n+++ b/x\n' > "$W/in/hello/patches/0001-fix.patch"
printf 'service\n' > "$W/in/hello/files/hello.service"

OUT=$(./zig-out/bin/dkbuild import-cbuild --out "$W/out" "$W/in/hello" 2>&1) || { echo "$OUT"; echo "FAIL: import-cbuild failed"; exit 1; }
[ -f "$W/out/hello/package.toml" ] || { echo "FAIL: no package.toml"; exit 1; }
[ -f "$W/out/hello/patches/0001-fix.patch" ] || { echo "FAIL: patches were not copied"; exit 1; }
[ -f "$W/out/hello/files/hello.service" ] || { echo "FAIL: files/ was not copied"; exit 1; }
grep -q 'patches = \["0001-fix.patch"\]' "$W/out/hello/package.toml" || { echo "FAIL: the patch is not listed"; exit 1; }
grep -q 'url = "https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz"' "$W/out/hello/package.toml" || { echo "FAIL: the f-string source was not resolved"; exit 1; }
grep -q 'TODO(cbuild): with self.pushd' "$W/out/hello/package.toml" || { echo "FAIL: the untranslated block is not marked"; exit 1; }
echo "$OUT" | grep -q 'TODO' || { echo "FAIL: the report does not list the TODO"; exit 1; }
echo "$OUT" | grep -q 'hardening' || { echo "FAIL: the dropped variable is not reported"; exit 1; }
./zig-out/bin/dkbuild check "$W/out/hello/package.toml" >/dev/null 2>&1 || { echo "FAIL: the draft does not pass check"; exit 1; }

# links in files/ and patches/: their contents are taken, from inside the template's tree only, and the output
# holds no link that a later write could follow out of it (CB-07, CB-13)
mkdir -p "$W/cp/main/one/files" "$W/cp/main/one/patches" "$W/cp/main/two/files" "$W/cp/main/shared"
for p in one two; do
    printf 'pkgname = "ln"\npkgver = "1"\npkgrel = 0\npkgdesc = "x"\nlicense = "MIT"\nsource = "https://x.org/a.tgz"\nsha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"\n' > "$W/cp/main/$p/template.py"
done
echo ORIG > "$W/cp/main/shared/data"
printf -- '--- a/x\n+++ b/x\n' > "$W/cp/main/shared/fix.patch"
echo SECRET > "$W/secret"
ln -s ../../shared/data "$W/cp/main/one/files/x"
ln -s ../../shared/fix.patch "$W/cp/main/one/patches/fix.patch"
ln -s "$W/secret" "$W/cp/main/one/files/outside"
ln -s /nonexistent "$W/cp/main/one/patches/gone.patch"
echo NEW > "$W/cp/main/two/files/x"
OUT=$(./zig-out/bin/dkbuild import-cbuild --out "$W/ln" "$W/cp/main/one" 2>&1) || { echo "$OUT"; echo "FAIL: import with links failed"; exit 1; }
[ -f "$W/ln/ln/patches/fix.patch" ] && [ ! -L "$W/ln/ln/patches/fix.patch" ] || { echo "FAIL: the linked patch was left out"; exit 1; }
grep -q 'patches = \["fix.patch"\]' "$W/ln/ln/package.toml" || { echo "FAIL: the linked patch is not listed"; exit 1; }
[ ! -L "$W/ln/ln/files/x" ] && [ "$(cat "$W/ln/ln/files/x")" = ORIG ] || { echo "FAIL: the linked file's contents were not taken"; exit 1; }
[ ! -e "$W/ln/ln/files/outside" ] || { echo "FAIL: a file from outside the template tree was copied in"; exit 1; }
grep -q 'TODO(cbuild): files/outside' "$W/ln/ln/package.toml" || { echo "FAIL: the link that was left out is not marked"; exit 1; }
grep -q 'TODO(cbuild): patches/gone.patch' "$W/ln/ln/package.toml" || { echo "FAIL: the dangling patch is not marked"; exit 1; }
# a draft that holds a link already (from an older import): --force replaces the link, not what it points at
ln -sfn "$W/cp/main/shared/data" "$W/ln/ln/files/x"
./zig-out/bin/dkbuild import-cbuild --force --out "$W/ln" "$W/cp/main/two" >/dev/null 2>&1 || { echo "FAIL: --force import failed"; exit 1; }
[ "$(cat "$W/cp/main/shared/data")" = ORIG ] || { echo "FAIL: the import wrote through a link, outside the output"; exit 1; }
[ "$(cat "$W/ln/ln/files/x")" = NEW ] || { echo "FAIL: --force did not replace the file"; exit 1; }

# arguments that are not understood stop everything before anything is converted (CB-20)
for bad in "--out=$W/eq --typo" "--out" "--help"; do
    rm -rf "$W/tree" && mkdir -p "$W/tree"
    # shellcheck disable=SC2086 # the words are the arguments
    if ./zig-out/bin/dkbuild --tree "$W/tree" import-cbuild "$W/cp/main/two" $bad >/dev/null 2>&1; then echo "FAIL: import-cbuild accepted '$bad'"; exit 1; fi
    [ ! -e "$W/tree/imported" ] || { echo "FAIL: '$bad' converted into the default directory"; exit 1; }
done
./zig-out/bin/dkbuild import-cbuild --out="$W/eq" -- "$W/cp/main/two" >/dev/null 2>&1 && [ -f "$W/eq/ln/package.toml" ] || { echo "FAIL: --out=DIR and -- are not taken"; exit 1; }
echo "ok: a template directory becomes a draft recipe with its patches and files, TODOs reported, and passes check"
