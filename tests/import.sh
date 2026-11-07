#!/bin/sh
# dkbuild import-cbuild on a template directory: the draft is written, patches/
# and files/ are copied, the TODOs are reported, and the draft passes `check`.
set -u
cd "$(dirname "$0")/.."
mkdir -p work
W=$(mktemp -d "$PWD/work/import.XXXXXX"); trap 'rm -rf "$W"' EXIT
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
echo "ok: a template directory becomes a draft recipe with its patches and files, TODOs reported, and passes check"
