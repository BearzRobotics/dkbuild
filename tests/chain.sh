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

OUT=$(./zig-out/bin/dkbuild --tree "$T" pkg usedemo usedemo-static 2>&1) || { echo "$OUT" | tail -15; echo "FAIL: chain build"; exit 1; }
echo "$OUT" | grep -q '^==> dkdemo-1-r1$' || { echo "FAIL: dkdemo was not built first"; exit 1; }
echo "$OUT" | grep -q '^==> usedemo-1-r1$' || { echo "FAIL: usedemo was not built"; exit 1; }
echo "$OUT" | grep -q '^==> usedemo-static-1-r1$' || { echo "FAIL: usedemo-static was not built"; exit 1; }

dump() { sbrun --robind "$PWD/$T/repo/x86_64" /tmp/repo -- /usr/bin/apk adbdump "/tmp/repo/$1" 2>&1; }

# dkdemo provides its soname; -devel provides nothing it shouldn't.
dump dkdemo-1-r1.apk | grep -q 'so:libdkdemo.so.1=0' || { echo "FAIL: dkdemo does not provide so:libdkdemo.so.1"; exit 1; }
# The dynamic program needs it and libc; the static one needs neither.
INFO=$(dump usedemo-1-r1.apk)
echo "$INFO" | grep -q 'so:libdkdemo.so.1' || { echo "FAIL: usedemo does not depend on so:libdkdemo.so.1"; exit 1; }
echo "$INFO" | grep -q 'so:libc.so' || { echo "FAIL: usedemo does not depend on so:libc.so"; exit 1; }
echo "$INFO" | grep -q 'cmd:usedemo' || { echo "FAIL: usedemo does not provide cmd:usedemo"; exit 1; }
dump usedemo-static-1-r1.apk | grep -q 'so:' && { echo "FAIL: the static program depends on a shared library"; exit 1; }

# Installing usedemo must pull in dkdemo (only our repo has it), and it must run.
# This happens in a root made of the DKRescue image (described to apk as
# dkrescue-base, so the dependency on libc.so can be met) plus our repository.
OUT=$(sbrun --robind "$PWD/$T/repo/x86_64" /dkrepo --robind "$PWD/keys" /dkkeys \
    --robind "$PWD/rootfs/dkrescue-base" /dkbase -- /usr/bin/sh -c '
mkdir -p /etc/apk/keys && cp /dkkeys/*.pub /etc/apk/keys/
apk --root / --initdb --allow-untrusted --no-network --no-interactive add /dkbase/dkrescue-base-1-r0.apk >/dev/null 2>&1 \
    || { echo "FAIL: the base image could not be described to apk"; exit 1; }
apk --root / --no-network --no-interactive --repository /dkrepo/Packages.adb add usedemo 2>&1 \
    || { echo "FAIL: install of usedemo"; exit 1; }
[ -e /usr/lib/libdkdemo.so.1 ] || { echo "FAIL: libdkdemo was not pulled in"; exit 1; }
/usr/bin/usedemo || { echo "FAIL: usedemo does not run against the installed libdkdemo"; exit 1; }
' 2>&1) || { echo "$OUT"; exit 1; }
echo "ok: dkdemo built first; dynamic and static users built against it; scan results right; installs and runs"
