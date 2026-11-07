#!/bin/sh
# The musl and linux-headers packages in repo/ work: install only those into an
# empty sysroot, link a program against it with the DKRescue toolchain, and run
# it through our own loader (dynamic) and on its own (static). Needs both built
# into repo/ (built here if they are not).
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
ls repo/x86_64/musl-static-*.apk repo/x86_64/linux-headers-*.apk >/dev/null 2>&1 || {
    ./zig-out/bin/dkbuild pkg musl >/dev/null 2>&1 || { echo "FAIL: building musl into repo/"; exit 1; }
}
mkdir -p work
W=$(mktemp -d "$PWD/work/musl.XXXXXX"); trap 'rm -rf "$W"' EXIT
SR=$W/sr
mkdir -p "$SR/etc/apk/keys"
cp keys/*.pub "$SR/etc/apk/keys/"

# 1. Install our musl and linux-headers into an empty root, from repo/ alone.
sbrun --bind "$SR" /mnt --robind "$PWD/repo/x86_64" /tmp/repo -- /usr/bin/apk --root /mnt --initdb \
    --keys-dir /mnt/etc/apk/keys --repository /tmp/repo/Packages.adb --no-network --no-interactive \
    add musl musl-devel musl-static linux-headers >/dev/null 2>&1 \
    || { echo "FAIL: installing musl and linux-headers from repo/"; exit 1; }

cat > "$SR/hello.c" <<'C'
#include <stdio.h>
#include <sys/utsname.h>
#include <linux/kd.h>
int main(void) { struct utsname u; uname(&u); printf("ok %s %d\n", u.sysname, KDSETMODE); return 0; }
C

# 2. Link by hand so nothing but our crt files, our libc and the compiler's
#    builtins is used, then run both programs.
OUT=$(sbrun --bind "$SR" /sr -- /usr/bin/sh -ec '
  T=--target=x86_64-fenriros-linux-musl
  RT=$(clang $T -print-libgcc-file-name)
  clang $T --sysroot=/sr -c /sr/hello.c -o /tmp/hello.o
  ld.lld -dynamic-linker /usr/lib/ld-musl-x86_64.so.1 /sr/usr/lib/crt1.o /sr/usr/lib/crti.o /tmp/hello.o -L/sr/usr/lib -lc $RT /sr/usr/lib/crtn.o -o /sr/hello-dyn
  ld.lld -static /sr/usr/lib/crt1.o /sr/usr/lib/crti.o /tmp/hello.o -L/sr/usr/lib -lc $RT /sr/usr/lib/crtn.o -o /sr/hello-static
  /sr/usr/lib/ld-musl-x86_64.so.1 --library-path /sr/usr/lib /sr/hello-dyn
  /sr/hello-static' 2>&1) || { echo "$OUT"; echo "FAIL: building or running against our musl"; exit 1; }
[ "$(echo "$OUT" | grep -c '^ok Linux 19258$')" = 2 ] || { echo "$OUT"; echo "FAIL: unexpected output"; exit 1; }
echo "ok: a program links against our musl and linux-headers and runs, dynamically (our loader) and statically"
