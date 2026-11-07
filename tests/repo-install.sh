#!/bin/sh
# A package built into repo/ installs with our key trusted, and is refused without it.
# Needs zstd in repo/ (built here if it is not), and the DKRescue root for apk.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh
ls repo/x86_64/zstd-static-*.apk >/dev/null 2>&1 || {
    ./zig-out/bin/dkbuild pkg zstd >/dev/null 2>&1 || { echo "FAIL: building zstd into repo/"; exit 1; }
}
mkdir -p work
T=$(mktemp -d "$PWD/work/ri.XXXXXX")
trap 'rm -rf "$T"' EXIT
try() { # $1 = root dir, PKG = package to add
    sbrun --bind "$1" /mnt --robind "$PWD/repo/x86_64" /tmp/repo -- /usr/bin/apk --root /mnt --initdb \
        --keys-dir /mnt/etc/apk/keys --repository /tmp/repo/Packages.adb --no-network --no-interactive add "$PKG" >/dev/null 2>&1
}
mkdir -p "$T/trusted/etc/apk/keys" "$T/untrusted/etc/apk/keys"
cp keys/*.pub "$T/trusted/etc/apk/keys/"
PKG=zstd-static
try "$T/trusted" || { echo "FAIL: install with our key trusted"; exit 1; }
[ -x "$T/trusted/usr/bin/zstd" ] || { echo "FAIL: -static did not pull in the main package"; exit 1; }
[ -f "$T/trusted/usr/include/zstd.h" ] || { echo "FAIL: -static did not pull in -devel"; exit 1; }
[ -f "$T/trusted/usr/lib/libzstd.a" ] || { echo "FAIL: libzstd.a missing"; exit 1; }
[ ! -e "$T/trusted/usr/share/man" ] || { echo "FAIL: -doc files installed without -doc"; exit 1; }
try "$T/untrusted" && { echo "FAIL: installed without trusting the key"; exit 1; }
echo "ok: -static pulls -devel and the main package, leaves -doc out; refused without the key"
