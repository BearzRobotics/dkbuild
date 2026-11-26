#!/bin/sh
# `dkbuild bootstrap-root` replaces a build machine only with one that works: a bad image, or a --dest that is not a
# build root, leaves what is there alone. Uses small made-up images; the real build machine is not touched.
set -u
cd "$(dirname "$0")/.." || exit 1
DK=$PWD/zig-out/bin/dkbuild
mkdir -p work
W=$(mktemp -d "$PWD/work/boot.XXXXXX") || exit 1
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT
fail=0
bad() { echo "FAIL: $1"; fail=1; }
mkdir -p "$W/old/usr/bin" "$W/home/precious" "$W/junk/usr/bin"
echo working > "$W/old/usr/bin/marker"
echo keep > "$W/home/precious/file"
echo not-an-image > "$W/wrong.log"
echo x > "$W/junk/usr/bin/x"; tar -C "$W/junk" -cf "$W/incomplete.tar" .
# 1. not an image at all
"$DK" bootstrap-root --force --dest "$W/old" "$W/wrong.log" >/dev/null 2>&1 && bad "a wrong file was taken for a build machine"
[ -f "$W/old/usr/bin/marker" ] || bad "a wrong file cost the working build machine"
# 2. unpacks, but lacks what a build needs
"$DK" bootstrap-root --force --dest "$W/old" "$W/incomplete.tar" >/dev/null 2>&1 && bad "an incomplete image was accepted"
[ -f "$W/old/usr/bin/marker" ] || bad "an incomplete image replaced the working build machine"
[ ! -e "$W/old.new" ] || bad "the failed unpack was left behind"
# 3. --force on a directory that is no build root
"$DK" bootstrap-root --force --dest "$W/home" "$W/incomplete.tar" >/dev/null 2>&1
[ -f "$W/home/precious/file" ] || bad "--force removed a directory that is not a build root"
[ $fail = 0 ] && echo "ok: bootstrap-root replaces a build machine only with a working one"
exit $fail
