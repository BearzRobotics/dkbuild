#!/bin/sh
# A built package installs with its repository's key trusted, and is refused without it. Builds the current zstd
# (and the musl it runs with) in a test tree; needs the DKRescue root.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
R=tests/trees/repo-install
realtree "$R" zstd musl linux-headers
OUT=$(./zig-out/bin/dkbuild --tree "$R" pkg --key "$TEST_KEY" zstd musl 2>&1) || { echo "$OUT" | tail -15; echo "FAIL: building zstd and musl"; exit 1; }
mkdir -p work
T=$(mktemp -d "$PWD/work/ri.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
try() { # $1 = root dir, PKG = package to add
    sbrun --bind "$1" /mnt --robind "$PWD/$R/repo/x86_64" /tmp/repo -- /usr/bin/apk --root /mnt --initdb \
        --keys-dir /mnt/etc/apk/keys --repository /tmp/repo/Packages.adb --no-network --no-interactive add "$PKG" >/dev/null 2>&1
}
mkdir -p "$T/trusted/etc/apk/keys" "$T/untrusted/etc/apk/keys"
cp "$R"/keys/*.pub "$T/trusted/etc/apk/keys/"
PKG=zstd-static
try "$T/trusted" || { echo "FAIL: install with our key trusted"; exit 1; }
# -static needs -devel, which needs the libraries' package (zstd has one: the program stays out)
ls "$T"/trusted/usr/lib/libzstd.so.1* >/dev/null 2>&1 || { echo "FAIL: -static did not pull in the libraries"; exit 1; }
[ ! -e "$T/trusted/usr/bin/zstd" ] || { echo "FAIL: -static pulled in the program"; exit 1; }
[ -f "$T/trusted/usr/include/zstd.h" ] || { echo "FAIL: -static did not pull in -devel"; exit 1; }
[ -f "$T/trusted/usr/lib/libzstd.a" ] || { echo "FAIL: libzstd.a missing"; exit 1; }
[ ! -e "$T/trusted/usr/share/man" ] || { echo "FAIL: -doc files installed without -doc"; exit 1; }
try "$T/untrusted" && { echo "FAIL: installed without trusting the key"; exit 1; }
echo "ok: -static pulls -devel and the libraries, leaves the program and -doc out; refused without the key"
