#!/bin/sh
# Packages that depend on an in-tree package build it first and install it from
# repo/, dynamically and statically. dkdemo exists only in this tree, so every
# step below can only pass if our own package was used.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
T=tests/trees/chain
newtree "$T"
mkdemo "$T/src"
demo_recipe "$T" 1
user_recipe "$T" usedemo dkdemo-devel
user_recipe "$T" usedemo-static dkdemo-static static
CH=$PWD/rootfs/chimera

OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg usedemo usedemo-static 2>&1) || { echo "$OUT" | tail -15; echo "FAIL: chain build"; exit 1; }
echo "$OUT" | grep -q '^==> dkdemo-1-r1$' || { echo "FAIL: dkdemo was not built first"; exit 1; }
echo "$OUT" | grep -q '^==> usedemo-1-r1$' || { echo "FAIL: usedemo was not built"; exit 1; }
echo "$OUT" | grep -q '^==> usedemo-static-1-r1$' || { echo "FAIL: usedemo-static was not built"; exit 1; }

dump() { bwrap --bind "$CH" / --proc /proc --dev /dev --unshare-all --tmpfs /tmp --ro-bind "$PWD/$T/repo/x86_64" /tmp/repo apk adbdump "/tmp/repo/$1" 2>&1; }

# dkdemo provides its soname; -devel provides nothing it shouldn't.
dump dkdemo-1-r1.apk | grep -q 'so:libdkdemo.so.1=0' || { echo "FAIL: dkdemo does not provide so:libdkdemo.so.1"; exit 1; }
# The dynamic program needs it and libc; the static one needs neither.
INFO=$(dump usedemo-1-r1.apk)
echo "$INFO" | grep -q 'so:libdkdemo.so.1' || { echo "FAIL: usedemo does not depend on so:libdkdemo.so.1"; exit 1; }
echo "$INFO" | grep -q 'so:libc.so' || { echo "FAIL: usedemo does not depend on so:libc.so"; exit 1; }
echo "$INFO" | grep -q 'cmd:usedemo' || { echo "FAIL: usedemo does not provide cmd:usedemo"; exit 1; }
dump usedemo-static-1-r1.apk | grep -q 'so:' && { echo "FAIL: the static program depends on a shared library"; exit 1; }

# Installing usedemo must pull in dkdemo (only our repo has it), and it must run.
R=$(mktemp -d); trap 'rm -rf "$R"' EXIT
mkdir -p "$R/etc/apk/keys"; cp keys/*.pub "$CH"/etc/apk/keys/*.pub "$R/etc/apk/keys/"
bwrap --bind "$CH" / --bind "$R" /mnt --proc /proc --dev /dev --unshare-user --unshare-pid --tmpfs /tmp \
    --ro-bind "$PWD/$T/repo/x86_64" /tmp/repo --ro-bind /etc/resolv.conf /etc/resolv.conf \
    apk --usermode --root /mnt --initdb --keys-dir /mnt/etc/apk/keys --repository /tmp/repo/Packages.adb \
    --repository https://repo.chimera-linux.org/current/main --no-interactive add usedemo >"$R.log" 2>&1 \
    || { cat "$R.log"; echo "FAIL: install of usedemo"; exit 1; }
[ -e "$R/usr/lib/libdkdemo.so.1" ] || { echo "FAIL: libdkdemo was not pulled in"; exit 1; }
bwrap --bind "$R" / --proc /proc --dev /dev --unshare-all --tmpfs /tmp /usr/bin/usedemo \
    || { echo "FAIL: usedemo does not run against the installed libdkdemo"; exit 1; }
echo "ok: dkdemo built first; dynamic and static users built against it; scan results right; installs and runs"
