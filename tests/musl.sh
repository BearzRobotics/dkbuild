#!/bin/sh
# The musl and linux-headers packages in repo/ work: install only those into an
# empty sysroot, link a program against it with the Chimera toolchain, and run it
# through our own loader (dynamic) and on its own (static).
set -u
cd "$(dirname "$0")/.."
CH=$PWD/rootfs/chimera
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
SR=$W/sr; TC=$W/tc
mkdir -p "$SR/etc/apk/keys" "$TC/etc/apk/keys"
cp keys/*.pub "$SR/etc/apk/keys/"
cp "$CH"/etc/apk/keys/* "$TC/etc/apk/keys/"
printf 'https://repo.chimera-linux.org/current/main\n' > "$TC/etc/apk/repositories"

bwrap --bind "$CH" / --bind "$SR" /mnt --proc /proc --dev /dev --unshare-user --unshare-pid --tmpfs /tmp \
    --ro-bind "$PWD/repo/x86_64" /tmp/repo \
    apk --usermode --root /mnt --initdb --keys-dir /mnt/etc/apk/keys --repository /tmp/repo/Packages.adb \
    --no-network --no-interactive add musl musl-devel musl-static linux-headers >/dev/null 2>&1 \
    || { echo "FAIL: installing musl and linux-headers from repo/"; exit 1; }
bwrap --bind "$CH" / --bind "$TC" /mnt --proc /proc --dev /dev --unshare-user --unshare-pid \
    --ro-bind /etc/resolv.conf /etc/resolv.conf --tmpfs /tmp \
    apk --usermode --root /mnt --initdb --no-interactive add base-bootstrap clang >/dev/null 2>&1 \
    || { echo "FAIL: preparing a toolchain root"; exit 1; }
cat > "$SR/hello.c" <<'C'
#include <stdio.h>
#include <sys/utsname.h>
#include <linux/kd.h>
int main(void) { struct utsname u; uname(&u); printf("ok %s %d\n", u.sysname, KDSETMODE); return 0; }
C
# Link by hand so nothing but our crt files, our libc and the compiler's builtins is used.
OUT=$(bwrap --bind "$TC" / --bind "$SR" /sr --proc /proc --dev /dev --unshare-all --tmpfs /tmp --uid 0 --gid 0 \
    --clearenv --setenv PATH /usr/bin sh -ec '
  T=--target=x86_64-chimera-linux-musl
  RT=$(clang $T -print-libgcc-file-name)
  clang $T --sysroot=/sr -c /sr/hello.c -o /tmp/hello.o
  ld.lld -dynamic-linker /usr/lib/ld-musl-x86_64.so.1 /sr/usr/lib/crt1.o /sr/usr/lib/crti.o /tmp/hello.o -L/sr/usr/lib -lc $RT /sr/usr/lib/crtn.o -o /sr/hello-dyn
  ld.lld -static /sr/usr/lib/crt1.o /sr/usr/lib/crti.o /tmp/hello.o -L/sr/usr/lib -lc $RT /sr/usr/lib/crtn.o -o /sr/hello-static
  /sr/usr/lib/ld-musl-x86_64.so.1 --library-path /sr/usr/lib /sr/hello-dyn
  /sr/hello-static' 2>&1) || { echo "$OUT"; echo "FAIL: building or running against our musl"; exit 1; }
[ "$(echo "$OUT" | grep -c '^ok Linux 19258$')" = 2 ] || { echo "$OUT"; echo "FAIL: unexpected output"; exit 1; }
echo "ok: a program links against our musl and linux-headers and runs, dynamically (our loader) and statically"
